//  LookMatchTests.swift — the Layer 2 look match, with no window and no Metal.
//
//  What this file runs: the scalar fit (exposure, black, white, print white
//  balance), histogram bins, crop sampling through `Geometry.sourcePoint`,
//  and the style preset as a sidecar transform plus a JSON file in a temp
//  directory.
//
//  What it does not run, and what has to be checked on an Apple silicon Mac
//  before trusting the picture:
//
//    * `ReferenceScan` — ImageIO into ROMM γ1.8. A wrong working space would
//      still produce plausible percentiles.
//    * `LookFrameSampler.read` — the rgba16 print texture. Private storage
//      returns nil; the section then refuses to align.
//    * The Post-Dev section itself, and that Apply lands in the open frame's
//      `.spektra.json` (`layerAdjustments` → `scheduleSave`).
//    * That the scalar matches `layer2Tone` on a real GPU pixel. The formulas
//      are transcribed from the shader; a one-pixel grade is the check.
//
//  `Tools/check-lookmatch.py` repeats the scalar cases where the Apple SDK
//  is not installed. Crop sampling lives only here, because it is
//  `Geometry`.

import XCTest

final class LookMatchTests: XCTestCase {

    // MARK: - fit

    func testIdentityIsNeutralAndDoesNotClearWhiteBalance() {
        let samples = ramp()
        let proposal = try XCTUnwrap(LookMatch.propose(source: samples, reference: samples, matchWhiteBalance: false))
        XCTAssertEqual(proposal.exposure, 0, accuracy: 0.02)
        XCTAssertEqual(proposal.blackPoint, 0, accuracy: 0.2)
        XCTAssertEqual(proposal.whitePoint, 0, accuracy: 0.2)
        XCTAssertFalse(proposal.matchedWhiteBalance)
        var grade = Adjustments()
        grade.temperature = 12
        grade.tint = -4
        grade.contrast = 5
        let out = proposal.applied(to: grade)
        XCTAssertEqual(out.temperature, 12)
        XCTAssertEqual(out.tint, -4)
        XCTAssertEqual(out.contrast, 5)
        XCTAssertEqual(out.exposure, 0, accuracy: 0.02)
        XCTAssertTrue(out.enabled)
    }

    func testExposureRoundTrip() {
        assertRoundTrip(exposure: 1, black: 0, white: 0)
        assertRoundTrip(exposure: -1.5, black: 0, white: 0)
        assertRoundTrip(exposure: 2.5, black: 0, white: 0)
    }

    func testBlackPointRoundTrip() {
        assertRoundTrip(exposure: 0, black: 12, white: 0)
        assertRoundTrip(exposure: 0.5, black: 14, white: 0)
    }

    func testEndsAndCombinedRoundTrip() {
        assertRoundTrip(exposure: 0, black: 10, white: 12)
        assertRoundTrip(exposure: 0.75, black: 8, white: 6)
        assertRoundTrip(exposure: -1, black: 20, white: 18)
        assertRoundTrip(exposure: 0, black: 4, white: 22)
    }

    func testAPureScaleMatchesAnchorsEvenWhenWhitePointTradesWithExposure() {
        // White point alone is a denominator. The search may report part of
        // it as exposure; the anchors are the contract.
        let source = ramp()
        let reference = ramp(exposure: 0, black: 0, white: 15)
        let proposal = try XCTUnwrap(LookMatch.propose(source: source, reference: reference, matchWhiteBalance: false))
        XCTAssertLessThan(proposal.largestError, 0.002)
        XCTAssertEqual(proposal.blackPoint, 0, accuracy: 0.5)
    }

    func testAFlatFrameUsesExposureOnly() {
        let source = (0..<32).map { _ in LookSample(0.2, 0.2, 0.2) }
        let reference = (0..<32).map { _ in LookSample(0.4, 0.4, 0.4) }
        let proposal = try XCTUnwrap(LookMatch.propose(source: source, reference: reference, matchWhiteBalance: false))
        XCTAssertEqual(proposal.exposure, 2.2, accuracy: 0.001)
        XCTAssertEqual(proposal.blackPoint, 0, accuracy: 0.001)
        XCTAssertEqual(proposal.whitePoint, 0, accuracy: 0.001)
    }

    func testTooFewSamplesRefuses() {
        let a = [LookSample(0.2, 0.2, 0.2)]
        XCTAssertNil(LookMatch.propose(source: a, reference: ramp(), matchWhiteBalance: false))
    }

    func testTemperatureAndTintRoundTrip() {
        let source = (0..<51).map { i -> LookSample in
            let x = Float(0.2 + 0.6 * Double(i) / 50)
            return LookSample(x, x, x)
        }
        for (temperature, tint) in [(20.0, 0.0), (-40.0, 0.0), (0.0, 25.0), (15.0, -10.0), (80.0, 40.0)] {
            let reference = source.map {
                LookMatch.applyTone($0, temperature: temperature, tint: tint, exposure: 0, blackPoint: 0, whitePoint: 0)
            }
            let proposal = try XCTUnwrap(LookMatch.propose(source: source, reference: reference, matchWhiteBalance: true))
            XCTAssertEqual(proposal.temperature, temperature, accuracy: 0.5, "temp \(temperature)")
            XCTAssertEqual(proposal.tint, tint, accuracy: 0.5, "tint \(tint)")
            XCTAssertEqual(proposal.exposure, 0, accuracy: 0.05)
            XCTAssertTrue(proposal.matchedWhiteBalance)
        }
    }

    func testWhiteBalanceOffLeavesTheGradeUntouched() {
        var grade = Adjustments()
        grade.temperature = 30
        grade.tint = 8
        let source = ramp()
        let reference = source.map {
            LookMatch.applyTone($0, temperature: 40, tint: 0, exposure: 0, blackPoint: 0, whitePoint: 0)
        }
        let proposal = try XCTUnwrap(LookMatch.propose(source: source, reference: reference, matchWhiteBalance: false))
        let out = proposal.applied(to: grade)
        XCTAssertEqual(out.temperature, 30)
        XCTAssertEqual(out.tint, 8)
    }

    func testApplyWritesTheFitAndLeavesCurves() {
        var grade = Adjustments()
        grade.contrast = -3
        grade.curves.rgb.insert(CGPoint(x: 0.4, y: 0.5))
        let source = ramp()
        let reference = ramp(exposure: 0.5, black: 14, white: 0)
        let proposal = try XCTUnwrap(LookMatch.propose(source: source, reference: reference, matchWhiteBalance: false))
        let out = proposal.applied(to: grade)
        XCTAssertEqual(out.exposure, 0.5, accuracy: 0.05)
        XCTAssertEqual(out.blackPoint, 14, accuracy: 0.5)
        XCTAssertEqual(out.contrast, -3)
        XCTAssertEqual(out.curves, grade.curves)
        XCTAssertFalse(LookMatch.unmodeledTone(Adjustments()))
        XCTAssertTrue(LookMatch.unmodeledTone(grade))
        var saturated = Adjustments()
        saturated.saturation = 20
        XCTAssertFalse(LookMatch.unmodeledTone(saturated), "saturation does not move luma")
    }

    func testTheSettingsClipboardStillDoesNotCopyAdjustments() {
        XCTAssertNotNil(ClipboardGroup.notCopied["adjustments"])
    }

    // MARK: - histogram

    func testHistogramUsesTheShaderBin() {
        let red = LookSample(1, 0, 0)
        let bins = LookMatch.histogramBins([red])
        XCTAssertEqual(bins.count, 1024)
        XCTAssertEqual(bins[LookMatch.binIndex(1)], 1, accuracy: 1e-5)
        XCTAssertEqual(bins[256 + LookMatch.binIndex(0)], 1, accuracy: 1e-5)
        XCTAssertEqual(bins[512 + LookMatch.binIndex(0)], 1, accuracy: 1e-5)
        XCTAssertEqual(bins[768 + LookMatch.binIndex(LookSample.luma(red))], 1, accuracy: 1e-5)
        XCTAssertEqual(LookMatch.binIndex(LookSample.luma(red)), 54)
    }

    func testAverageLumaIsTheMean() {
        let black = LookLumaImage(values: [0], width: 1, height: 1)
        let white = LookLumaImage(values: [1], width: 1, height: 1)
        let mean = LookMatch.averageLuma(black, white, width: 1, height: 1)
        XCTAssertEqual(mean.values, [0.5])
    }

    // MARK: - crop (trap 33)

    func testTheFitSamplesTheCropAndNotTheRestOfTheFrame() {
        let grid = halves()
        var geometry = Geometry()
        geometry.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
        assertRed(LookFrameSampler.samples(in: grid, geometry: geometry, maxSamples: 10_000))
        geometry.quarterTurns = 1
        assertRed(LookFrameSampler.samples(in: grid, geometry: geometry, maxSamples: 10_000))
        geometry.quarterTurns = 0
        geometry.flipH = true
        assertRed(LookFrameSampler.samples(in: grid, geometry: geometry, maxSamples: 10_000),
                  "a flip after the crop must not bring the other half back")
    }

    func testTheRightHalfIsTheBlueHalf() {
        var geometry = Geometry()
        geometry.crop = CropRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let samples = LookFrameSampler.samples(in: halves(), geometry: geometry, maxSamples: 10_000)
        XCTAssertFalse(samples.isEmpty)
        for s in samples {
            XCTAssertLessThan(s.r, 0.1)
            XCTAssertGreaterThan(s.b, 0.9)
        }
    }

    func testATurnDoesNotSampleBelowTheCrop() {
        // Top row green, bottom row red. Crop the top, then turn: still green.
        var pixels: [LookSample] = []
        for y in 0..<2 {
            for _ in 0..<4 {
                pixels.append(y == 0 ? LookSample(0, 1, 0) : LookSample(1, 0, 0))
            }
        }
        let grid = try XCTUnwrap(LookFrameSampler.Grid.dense(pixels, width: 4, height: 2))
        var geometry = Geometry()
        geometry.crop = CropRect(x: 0, y: 0, width: 1, height: 0.5)
        geometry.quarterTurns = 1
        let samples = LookFrameSampler.samples(in: grid, geometry: geometry, maxSamples: 10_000)
        XCTAssertFalse(samples.isEmpty)
        for s in samples {
            XCTAssertGreaterThan(s.g, 0.9)
            XCTAssertLessThan(s.r, 0.1)
        }
    }

    func testLumaPictureFollowsTheCrop() {
        var geometry = Geometry()
        geometry.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
        let image = LookFrameSampler.lumaImage(grid: halves(), geometry: geometry, maxEdge: 32)
        XCTAssertFalse(image.values.isEmpty)
        for v in image.values {
            XCTAssertEqual(v, LookSample.luma(LookSample(1, 0, 0)), accuracy: 1e-4)
        }
    }

    // MARK: - styles

    func testAStyleReplacesTheGradeAndNothingElse() {
        var sidecar = Sidecar()
        sidecar.params.filmStock = "kodak_portra_400"
        sidecar.params.exposureCompensationEV = 1.25
        sidecar.geometry.crop = CropRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
        sidecar.adjustments.contrast = 3
        sidecar.masks = [EditMask.make(.linearGradient)]
        var grade = Adjustments()
        grade.exposure = -0.5
        grade.blackPoint = 4
        grade.temperature = -10
        let preset = try XCTUnwrap(StylePreset.make(name: "  Scan  ", adjustments: grade, id: UUID(), created: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(preset.name, "Scan")
        let out = preset.applied(to: sidecar)
        XCTAssertEqual(out.params, sidecar.params)
        XCTAssertEqual(out.geometry, sidecar.geometry)
        XCTAssertEqual(out.masks, sidecar.masks)
        XCTAssertEqual(out.decode, sidecar.decode)
        XCTAssertEqual(out.adjustments, grade)
        XCTAssertNil(StylePreset.make(name: "   ", adjustments: grade))
    }

    func testStylesRoundTripInTheirOwnFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "spektralab-styles-\(UUID().uuidString)")
            .appending(path: "style-presets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var grade = Adjustments()
        grade.exposure = 0.25
        grade.whitePoint = 6
        let preset = try XCTUnwrap(StylePreset.make(name: "Porch", adjustments: grade, id: UUID(), created: Date(timeIntervalSince1970: 10)))
        try StylePresetStore.save([preset], to: url)
        let loaded = StylePresetStore.load(from: url)
        XCTAssertEqual(loaded, [preset])
        XCTAssertEqual(StylePresetStore.load(from: url.deletingLastPathComponent().appending(path: "missing.json")), [])
    }

    // MARK: - fixtures

    private func assertRoundTrip(exposure: Double, black: Double, white: Double,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let source = ramp()
        let reference = ramp(exposure: exposure, black: black, white: white)
        let proposal = LookMatch.propose(source: source, reference: reference, matchWhiteBalance: false)
        XCTAssertNotNil(proposal, file: file, line: line)
        guard let proposal else { return }
        XCTAssertEqual(proposal.exposure, exposure, accuracy: 0.05, file: file, line: line)
        XCTAssertEqual(proposal.blackPoint, black, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(proposal.whitePoint, white, accuracy: 0.5, file: file, line: line)
        XCTAssertLessThan(proposal.largestError, 0.002, file: file, line: line)
    }

    private func ramp(n: Int = 401, exposure: Double = 0, black: Double = 0, white: Double = 0) -> [LookSample] {
        (0..<n).map { i in
            let x = Float(0.02 + 0.96 * Double(i) / Double(n - 1))
            return LookMatch.applyTone(LookSample(x, x, x), temperature: 0, tint: 0,
                                       exposure: exposure, blackPoint: black, whitePoint: white)
        }
    }

    /// 4×2, left half red, right half blue.
    private func halves() -> LookFrameSampler.Grid {
        var pixels: [LookSample] = []
        for _ in 0..<2 {
            for x in 0..<4 {
                pixels.append(x < 2 ? LookSample(1, 0, 0) : LookSample(0, 0, 1))
            }
        }
        return LookFrameSampler.Grid.dense(pixels, width: 4, height: 2)!
    }

    private func assertRed(_ samples: [LookSample], _ message: String = "",
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(samples.isEmpty, message, file: file, line: line)
        for s in samples {
            XCTAssertGreaterThan(s.r, 0.9, message, file: file, line: line)
            XCTAssertLessThan(s.b, 0.1, message, file: file, line: line)
        }
    }
}
