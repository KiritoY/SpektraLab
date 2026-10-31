//  LookFrameSampler.swift — the current frame, through the canvas's crop.
//
//  The histogram on the canvas counts the uncropped print (trap 33, pinned).
//  A look match that did the same would fit the half of the frame the crop
//  threw away. Samples for the fit, and the luma picture beside the
//  reference, are taken on the **output**: each point goes through
//  `Geometry.sourcePoint(forOutput:imageSize:)`, which is the map the canvas
//  samples with. Quarter turns and flips are that function's, not a second
//  copy.
//
//  The pixels are the print **before** Layer 2 (`Renderer.graded`). The
//  proposal replaces exposure, black, white and white balance; sampling the
//  grade that is already on screen and then writing new sliders would fit
//  the wrong picture.

import CoreGraphics
import Foundation
import Metal

enum LookFrameSampler {
    /// A strided read of a frame. `samples` is row-major at `stride` pixels
    /// of the full image; `sample(fullX:fullY:)` quantises to that grid.
    struct Grid: Equatable, Sendable {
        var samples: [LookSample]
        var fullWidth: Int
        var fullHeight: Int
        var stride: Int
        var columns: Int
        var rows: Int

        func sample(fullX: Int, fullY: Int) -> LookSample? {
            guard stride > 0, columns > 0, rows > 0,
                  fullX >= 0, fullY >= 0, fullX < fullWidth, fullY < fullHeight else { return nil }
            let c = min(columns - 1, fullX / stride)
            let r = min(rows - 1, fullY / stride)
            let i = r * columns + c
            guard samples.indices.contains(i) else { return nil }
            return samples[i]
        }

        /// Every pixel, stride 1. Nil when the buffer is not `width × height`.
        static func dense(_ pixels: [LookSample], width: Int, height: Int) -> Grid? {
            guard width > 0, height > 0, pixels.count == width * height else { return nil }
            return Grid(samples: pixels, fullWidth: width, fullHeight: height,
                        stride: 1, columns: width, rows: height)
        }
    }

    /// Output-grid samples inside the crop, the turns and the flips.
    /// `maxSamples` caps the grid; percentiles do not need the full frame.
    static func samples(in grid: Grid, geometry: Geometry, maxSamples: Int) -> [LookSample] {
        let imageSize = CGSize(width: grid.fullWidth, height: grid.fullHeight)
        let out = geometry.outputSize(for: imageSize)
        let ow = max(Int(out.width.rounded()), 1)
        let oh = max(Int(out.height.rounded()), 1)
        let step = max(1, Int((Double(ow * oh) / Double(max(maxSamples, 1))).squareRoot().rounded(.up)))
        var result: [LookSample] = []
        result.reserveCapacity(min(ow * oh, max(maxSamples, 1)))
        var y = 0
        while y < oh {
            var x = 0
            while x < ow {
                let p = CGPoint(x: (Double(x) + 0.5) / Double(ow), y: (Double(y) + 0.5) / Double(oh))
                let s = geometry.sourcePoint(forOutput: p, imageSize: imageSize)
                if let sample = picked(s, from: grid) { result.append(sample) }
                x += step
            }
            y += step
        }
        return result
    }

    /// The cropped picture as encoded luma, long edge at most `maxEdge`.
    /// Identity geometry is the whole frame — what a reference scan uses.
    static func lumaImage(grid: Grid, geometry: Geometry, maxEdge: Int) -> LookLumaImage {
        let imageSize = CGSize(width: grid.fullWidth, height: grid.fullHeight)
        let out = geometry.outputSize(for: imageSize)
        let long = max(out.width, out.height, 1)
        let scale = min(1, Double(max(maxEdge, 1)) / Double(long))
        let w = max(1, Int((out.width * scale).rounded()))
        let h = max(1, Int((out.height * scale).rounded()))
        var values = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let p = CGPoint(x: (Double(x) + 0.5) / Double(w), y: (Double(y) + 0.5) / Double(h))
                let s = geometry.sourcePoint(forOutput: p, imageSize: imageSize)
                if let sample = picked(s, from: grid) {
                    values[y * w + x] = LookSample.luma(sample)
                }
            }
        }
        return LookLumaImage(values: values, width: w, height: h)
    }

    /// Strided read of an `rgba16Unorm` texture in shared or managed storage.
    /// Private textures are skipped: `getBytes` on them is not the contract
    /// `Session.sample` already relies on, and the section says the print
    /// could not be read rather than fitting zeroes.
    static func read(_ texture: MTLTexture, maxSamples: Int = 160_000) -> Grid? {
        guard texture.pixelFormat == .rgba16Unorm,
              texture.storageMode == .shared || texture.storageMode == .managed,
              texture.width > 0, texture.height > 0 else { return nil }
        let width = texture.width
        let height = texture.height
        let stride = max(1, Int((Double(width * height) / Double(max(maxSamples, 1))).squareRoot().rounded(.up)))
        let columns = (width + stride - 1) / stride
        let rows = (height + stride - 1) / stride
        var samples = [LookSample]()
        samples.reserveCapacity(columns * rows)
        var row = [UInt16](repeating: 0, count: width * 4)
        for rowIndex in 0..<rows {
            let y = rowIndex * stride
            row.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                texture.getBytes(base, bytesPerRow: width * MemoryLayout<UInt16>.size * 4,
                                 from: MTLRegionMake2D(0, y, width, 1), mipmapLevel: 0)
            }
            for col in 0..<columns {
                let x = col * stride
                let o = x * 4
                samples.append(LookSample(Float(row[o]) / 65535,
                                          Float(row[o + 1]) / 65535,
                                          Float(row[o + 2]) / 65535))
            }
        }
        guard samples.count == columns * rows else { return nil }
        return Grid(samples: samples, fullWidth: width, fullHeight: height,
                    stride: stride, columns: columns, rows: rows)
    }

    private static func picked(_ source: CGPoint, from grid: Grid) -> LookSample? {
        guard source.x >= 0, source.y >= 0, source.x < 1, source.y < 1 else { return nil }
        let sx = min(grid.fullWidth - 1, max(0, Int(source.x * Double(grid.fullWidth))))
        let sy = min(grid.fullHeight - 1, max(0, Int(source.y * Double(grid.fullHeight))))
        return grid.sample(fullX: sx, fullY: sy)
    }
}
