//  LookMatch.swift — fit a reference scan's black, white and mid-grey with
//  Layer 2 only.
//
//  A scan's look is not a film profile. The material model (film stock, paper,
//  spectral curves, `engine/resources`) describes what the emulsion and the
//  paper can do; this file never writes it. The fit proposes the Post-Dev
//  controls that already grade a print after the fact — exposure, black point,
//  white point, and optionally the print white balance — and nothing else.
//
//  The arithmetic is the shader's, on purpose, so a number here is the number
//  `layer2Tone` will apply (`Shaders.metal`):
//
//      white balance gains, then exposure, then black / white point.
//      exposure on a non-negative encoded value is a multiply by
//      2^(ev / 2.2), because pow(pow(c, 2.2) * 2^ev, 1/2.2) = c * 2^(ev/2.2).
//      black / white is (c - bp) / max(1 - bp - wp, 0.05), with the sliders
//      stored in percent and the shader holding percent/100.
//
//  Luma is the shader's (0.2126, 0.7152, 0.0722). Those weights sum to 1, so
//  a per-channel exposure and black/white point move luma by exactly the same
//  scalar. The fit is exact for those three controls and is not a model of
//  contrast, brightness, highlights, shadows, curves, colour balance or the
//  vignette — those stay where the frame left them, and the section says so.
//
//  Working space is the canvas's: encoded ProPhoto RGB, ROMM γ1.8. Callers
//  hand samples already in that space. Nothing here converts, and nothing
//  here touches Metal; `LookFrameSampler` is the crop, and `ReferenceScan`
//  is the file.
//
//  Exposure and white point can describe the same through-origin scale (the
//  shader's white point is a denominator). When two fits miss the anchors by
//  the same amount the search keeps the smaller white point, then the smaller
//  black point, then the exposure closer to zero — so a pure brightening
//  comes back as exposure. The contract the tests hold is the anchors, not a
//  unique slider triple along that valley.
//
//  Deferred (v1, not this fit): contrast, curves, colour balance, spatial
//  registration, and a search that scores every pixel rather than three
//  percentiles. `Tools/check-lookmatch.py` is the same fit for a machine
//  without the Apple SDK; if the formulas move, both move.

import Foundation

/// One encoded working-space pixel. Channels are ROMM γ1.8 code values,
/// 0…1, not linear light.
struct LookSample: Equatable, Sendable {
    var r: Float
    var g: Float
    var b: Float

    init(_ r: Float, _ g: Float, _ b: Float) {
        self.r = r; self.g = g; self.b = b
    }

    /// `luma()` in `Shaders.metal`.
    static func luma(_ s: LookSample) -> Float {
        0.2126 * s.r + 0.7152 * s.g + 0.0722 * s.b
    }
}

/// A small working-space luma picture for the compare. Values are the same
/// encoded luma the fit measures, not a display-referred grey.
struct LookLumaImage: Equatable, Sendable {
    var values: [Float]
    var width: Int
    var height: Int
}

/// Black, mid-grey and white as encoded luma percentiles.
struct LookAnchors: Equatable, Sendable {
    var black: Double
    var mid: Double
    var white: Double
}

/// The Layer 2 fields a match wants written. Other fields of `Adjustments`
/// are left alone by `applied(to:)`.
struct LookAlignProposal: Equatable, Sendable {
    var exposure: Double
    var blackPoint: Double
    var whitePoint: Double
    /// Print white balance. Written only when `matchedWhiteBalance` — a fit
    /// that was asked not to touch it must not zero a grade the user set.
    var temperature: Double
    var tint: Double
    var matchedWhiteBalance: Bool
    /// |output − reference| at the three anchors, encoded luma.
    var blackError: Double
    var midError: Double
    var whiteError: Double

    var largestError: Double { max(blackError, midError, whiteError) }

    func applied(to adjustments: Adjustments) -> Adjustments {
        var a = adjustments
        a.enabled = true
        a.exposure = exposure
        a.blackPoint = blackPoint
        a.whitePoint = whitePoint
        if matchedWhiteBalance {
            a.temperature = temperature
            a.tint = tint
        }
        return a
    }
}

enum LookMatch {
    /// Low / mid / high percentiles. 0.5% and 99.5% stay off the single
    /// clipped bin a scan's border puts at 0 or 1.
    static let blackPercentile = 0.005
    static let midPercentile = 0.50
    static let whitePercentile = 0.995
    /// The exponent `layer2Tone` uses for exposure. Not ROMM's 1.8 — the
    /// shader's pseudo-linear domain is 2.2, and matching the shader is the
    /// point.
    static let exposureCurve = 2.2
    /// Below this many samples a percentile is a handful of pixels.
    static let minimumSamples = 8

    /// Shader bin index: `uint(saturate(v) * 255 + 0.5)`.
    static func binIndex(_ v: Float) -> Int {
        let x = min(Float(1), max(Float(0), v))
        // `uint(saturate(v) * 255 + 0.5)` — truncate, do not round-to-nearest-even.
        let scaled = x * 255 + Float(0.5)
        return min(255, max(0, Int(scaled)))
    }

    /// 4 × 256 bins (R, G, B, luma), normalised the way `Renderer.publishHistogram`
    /// normalises the kernel's counts: the peak is the busiest bin that is not
    /// one of the two ends, because clipped black and white would otherwise
    /// flatten the plot.
    static func histogramBins(_ samples: [LookSample]) -> [Float] {
        var counts = [Float](repeating: 0, count: 1024)
        for s in samples {
            counts[binIndex(s.r)] += 1
            counts[256 + binIndex(s.g)] += 1
            counts[512 + binIndex(s.b)] += 1
            counts[768 + binIndex(LookSample.luma(s))] += 1
        }
        var maxv: Float = 1
        for i in 0..<1024 where i % 256 > 1 && i % 256 < 254 {
            maxv = max(maxv, counts[i])
        }
        for i in 0..<1024 { counts[i] = min(1, counts[i] / maxv) }
        return counts
    }

    static func anchors(of samples: [LookSample]) -> LookAnchors {
        let luma = samples.map { Double(LookSample.luma($0)) }.sorted()
        return LookAnchors(black: percentile(luma, blackPercentile),
                           mid: percentile(luma, midPercentile),
                           white: percentile(luma, whitePercentile))
    }

    /// Linear percentile on a sorted array. `p * (n − 1)`, so the ends are
    /// the first and last samples.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard let first = sorted.first else { return 0 }
        if sorted.count == 1 { return first }
        let x = p * Double(sorted.count - 1)
        let i = min(sorted.count - 1, max(0, Int(x.rounded(.down))))
        let t = x - Double(i)
        if i >= sorted.count - 1 { return sorted[sorted.count - 1] }
        return sorted[i] * (1 - t) + sorted[i + 1] * t
    }

    /// `Layer2Uniforms.tone`'s white-balance gains, as floats the shader stores.
    static func wbGain(temperature: Double, tint: Double) -> (r: Float, g: Float, b: Float) {
        let t = Float(temperature) / 100
        let g = Float(tint) / 100
        return (1 + 0.18 * t, 1 - 0.12 * g, 1 - 0.18 * t)
    }

    /// Channel-median ratios → temperature and tint.
    ///
    /// The shader applies `rgb *= wbGain` with red and blue moving in opposite
    /// directions for temperature, and green carrying tint. Solving the two
    /// ratios against green is one pair; medians so a clipped border does not
    /// own it. Gains are clamped to the slider (±100), which is the range the
    /// uniform was built for.
    static func whiteBalance(source: [LookSample], reference: [LookSample]) -> (temperature: Double, tint: Double) {
        let sr = median(source.map { Double($0.r) })
        let sg = median(source.map { Double($0.g) })
        let sb = median(source.map { Double($0.b) })
        let rr = median(reference.map { Double($0.r) })
        let rg = median(reference.map { Double($0.g) })
        let rb = median(reference.map { Double($0.b) })
        guard sr > 1e-4, sg > 1e-4, sb > 1e-4, rr > 1e-4, rg > 1e-4, rb > 1e-4 else { return (0, 0) }
        // u/v = (1+0.18 t)/(1−0.18 t) = (refR/refB) * (sourceB/sourceR)
        let rho = (rr / rb) * (sb / sr)
        guard rho > 0 else { return (0, 0) }
        let t = (rho - 1) / (0.18 * (rho + 1))
        let temperature = min(100, max(-100, t * 100))
        let u = 1 + 0.18 * (temperature / 100)
        // (sourceR/sourceG) * u / w = refR/refG, w = 1 − 0.12 g
        let w = (sr / sg) * u / (rr / rg)
        let g = (1 - w) / 0.12
        let tint = min(100, max(-100, g * 100))
        return (temperature, tint)
    }

    /// Encoded multiply for `ev` stops. See the file header.
    static func exposureScale(_ ev: Double) -> Double {
        pow(2.0, ev / exposureCurve)
    }

    /// Luma through exposure and black/white, in shader units (sliders are
    /// percent). Exact for luma because the weights sum to 1 — see the header.
    static func toneLuma(_ x: Double, exposure ev: Double, blackPoint: Double, whitePoint: Double) -> Double {
        let y = max(x, 0) * exposureScale(ev)
        let b = blackPoint / 100
        let w = whitePoint / 100
        let d = max(1 - b - w, 0.05)
        return (y - b) / d
    }

    /// The same three steps on a pixel, for a round trip a test can see.
    static func applyTone(_ sample: LookSample, temperature: Double, tint: Double,
                          exposure: Double, blackPoint: Double, whitePoint: Double) -> LookSample {
        let gain = wbGain(temperature: temperature, tint: tint)
        var c = LookSample(sample.r * gain.r, sample.g * gain.g, sample.b * gain.b)
        let k = Float(exposureScale(exposure))
        if exposure != 0 {
            c = LookSample(max(c.r, 0) * k, max(c.g, 0) * k, max(c.b, 0) * k)
        }
        let b = Float(blackPoint) / 100
        let w = Float(whitePoint) / 100
        let d = max(1 - b - w, 0.05)
        return LookSample((c.r - b) / d, (c.g - b) / d, (c.b - b) / d)
    }

    /// Propose Layer 2 exposure, black, white and (optionally) print white
    /// balance so `source` moves toward `reference`. Nil when either side is
    /// too small to be a percentile. Samples are encoded working-space RGB.
    static func propose(source: [LookSample], reference: [LookSample],
                        matchWhiteBalance: Bool) -> LookAlignProposal? {
        guard source.count >= minimumSamples, reference.count >= minimumSamples else { return nil }
        var temperature = 0.0
        var tint = 0.0
        var graded = source
        if matchWhiteBalance {
            let wb = whiteBalance(source: source, reference: reference)
            temperature = wb.temperature
            tint = wb.tint
            let gain = wbGain(temperature: temperature, tint: tint)
            graded = source.map { LookSample($0.r * gain.r, $0.g * gain.g, $0.b * gain.b) }
        }
        let src = anchors(of: graded)
        let ref = anchors(of: reference)
        let fit = fitTone(source: src, reference: ref)
        let black = toneLuma(src.black, exposure: fit.ev, blackPoint: fit.black, whitePoint: fit.white)
        let mid = toneLuma(src.mid, exposure: fit.ev, blackPoint: fit.black, whitePoint: fit.white)
        let white = toneLuma(src.white, exposure: fit.ev, blackPoint: fit.black, whitePoint: fit.white)
        return LookAlignProposal(exposure: fit.ev, blackPoint: fit.black, whitePoint: fit.white,
                                 temperature: temperature, tint: tint,
                                 matchedWhiteBalance: matchWhiteBalance,
                                 blackError: abs(black - ref.black),
                                 midError: abs(mid - ref.mid),
                                 whiteError: abs(white - ref.white))
    }

    /// True when the frame's other Layer 2 controls move luma in ways this
    /// fit does not model. Saturation is not one of them: it is applied
    /// around luma and leaves luma put.
    static func unmodeledTone(_ a: Adjustments) -> Bool {
        a.contrast != 0 || a.brightness != 0 || a.highlights != 0 || a.shadows != 0
            || !a.curves.isIdentity || !a.colorBalance.isNeutral || !a.vignette.isNeutral
    }

    /// Nearest-neighbour resample, then the mean. The overlay compare.
    static func averageLuma(_ a: LookLumaImage, _ b: LookLumaImage, width: Int, height: Int) -> LookLumaImage {
        let aa = resampled(a, width: width, height: height)
        let bb = resampled(b, width: width, height: height)
        let n = width * height
        guard aa.values.count == n, bb.values.count == n, n > 0 else {
            return LookLumaImage(values: [], width: 0, height: 0)
        }
        var values = [Float](repeating: 0, count: n)
        for i in 0..<n { values[i] = (aa.values[i] + bb.values[i]) * 0.5 }
        return LookLumaImage(values: values, width: width, height: height)
    }

    static func resampled(_ image: LookLumaImage, width: Int, height: Int) -> LookLumaImage {
        guard image.width > 0, image.height > 0, width > 0, height > 0,
              image.values.count == image.width * image.height else {
            return LookLumaImage(values: [], width: 0, height: 0)
        }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let sy = min(image.height - 1, y * image.height / height)
            for x in 0..<width {
                let sx = min(image.width - 1, x * image.width / width)
                out[y * width + x] = image.values[sy * image.width + sx]
            }
        }
        return LookLumaImage(values: out, width: width, height: height)
    }

    // MARK: - the search

    /// Exposure from the mids when the frame has no span, otherwise a coarse
    /// grid refined twice. Among fits whose anchor error ties within 1e-8,
    /// smaller white point, then smaller black point, then exposure closer
    /// to zero. See the file header for why the tie exists.
    private static func fitTone(source: LookAnchors, reference: LookAnchors) -> (ev: Double, black: Double, white: Double) {
        if source.white - source.black < 1e-3 || abs(reference.white - reference.black) < 1e-3 {
            return (exposureMatchingMid(source.mid, reference.mid), 0, 0)
        }
        var evs = [Double]()
        evs.reserveCapacity(25)
        for i in 0..<25 { evs.append(-3 + Double(i) * 0.25) }
        let points = Array(stride(from: 0.0, through: 50.0, by: 2.0))
        var fit = search(evs: evs, blacks: points, whites: points, source: source, reference: reference)
        for pass in [Refine(stepE: 0.05, stepP: 0.5, radius: 4), Refine(stepE: 0.01, stepP: 0.1, radius: 5)] {
            let evs = (0...(pass.radius * 2)).map { i in
                min(3, max(-3, fit.ev + Double(i - pass.radius) * pass.stepE))
            }
            let blacks = (0...(pass.radius * 2)).map { i in
                min(50, max(0, fit.black + Double(i - pass.radius) * pass.stepP))
            }
            let whites = (0...(pass.radius * 2)).map { i in
                min(50, max(0, fit.white + Double(i - pass.radius) * pass.stepP))
            }
            fit = search(evs: evs, blacks: blacks, whites: whites, source: source, reference: reference)
        }
        return fit
    }

    private struct Refine { var stepE, stepP: Double; var radius: Int }

    private static func exposureMatchingMid(_ source: Double, _ reference: Double) -> Double {
        guard source > 1e-4 else { return 0 }
        let ratio = max(reference, 1e-6) / source
        return min(3, max(-3, exposureCurve * log2(ratio)))
    }

    private static func search(evs: [Double], blacks: [Double], whites: [Double],
                              source: LookAnchors, reference: LookAnchors) -> (ev: Double, black: Double, white: Double) {
        var bestSSE = Double.greatestFiniteMagnitude
        var best = (ev: 0.0, black: 0.0, white: 0.0)
        for ev in evs {
            for black in blacks {
                for white in whites {
                    let sse = anchorSSE(ev: ev, black: black, white: white, source: source, reference: reference)
                    if sse + 1e-8 < bestSSE {
                        bestSSE = sse
                        best = (ev, black, white)
                    } else if sse <= bestSSE + 1e-8 {
                        let candidate = (white, black, abs(ev))
                        let current = (best.white, best.black, abs(best.ev))
                        if candidate < current {
                            bestSSE = min(bestSSE, sse)
                            best = (ev, black, white)
                        }
                    }
                }
            }
        }
        return best
    }

    private static func anchorSSE(ev: Double, black: Double, white: Double,
                                 source: LookAnchors, reference: LookAnchors) -> Double {
        let e0 = toneLuma(source.black, exposure: ev, blackPoint: black, whitePoint: white) - reference.black
        let e1 = toneLuma(source.mid, exposure: ev, blackPoint: black, whitePoint: white) - reference.mid
        let e2 = toneLuma(source.white, exposure: ev, blackPoint: black, whitePoint: white) - reference.white
        return e0 * e0 + e1 * e1 + e2 * e2
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let n = s.count
        if n % 2 == 1 { return s[n / 2] }
        return 0.5 * (s[n / 2 - 1] + s[n / 2])
    }
}
