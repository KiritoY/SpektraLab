//  ReferenceScan.swift — a JPEG or TIFF into the working space, for a look
//  match. Not a camera file and not an engine input: the pixels are the
//  scan's own picture, encoded ProPhoto RGB (ROMM γ1.8), which is the space
//  Layer 2 grades in. Downsampled — percentiles and a luma compare do not
//  need the scan's full resolution, and a 16-bit read of the *frame* is the
//  one that has to stay fine.

import CoreGraphics
import Foundation
import ImageIO

enum ReferenceScan {
    static let maxEdge = 512

    struct Image: Sendable {
        var grid: LookFrameSampler.Grid
    }

    enum Failure: Error {
        case unreadable
        case unsupported
        case noWorkingSpace
        case empty
    }

    static func load(_ url: URL) throws -> Image {
        let ext = url.pathExtension.lowercased()
        guard ["jpg", "jpeg", "tif", "tiff"].contains(ext) else { throw Failure.unsupported }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw Failure.unreadable }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else {
            throw Failure.unreadable
        }
        guard let space = ImageDecoder.workingSpace else { throw Failure.noWorkingSpace }
        let w = thumb.width, h = thumb.height
        guard w > 0, h > 0 else { throw Failure.empty }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            // `noneSkipLast` is what the rest of the app asks a context for;
            // a few spaces only accept a premultiplied buffer, and the second
            // call is that, into the same bytes.
            guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                     bytesPerRow: w * 4, space: space,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                    ?? CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                 bytesPerRow: w * 4, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // Bitmap row 0 is the top of the scan. Quartz's origin is the
            // bottom; the flip is so a side-by-side compare is not inverted.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { throw Failure.noWorkingSpace }
        var samples = [LookSample]()
        samples.reserveCapacity(w * h)
        for i in 0..<(w * h) {
            let o = i * 4
            samples.append(LookSample(Float(bytes[o]) / 255, Float(bytes[o + 1]) / 255, Float(bytes[o + 2]) / 255))
        }
        guard let grid = LookFrameSampler.Grid.dense(samples, width: w, height: h) else { throw Failure.empty }
        return Image(grid: grid)
    }
}
