import Foundation
import CoreGraphics
import ImageIO

/// Dominant-color extraction for stub palettes. Mirrors the web's
/// canvas-downsample + bucket approach (stubService extraction): decode,
/// downsample to a tiny bitmap, quantize to 4 bits/channel buckets, take
/// the top buckets by pixel count, emit each bucket's mean color as
/// lowercase "#rrggbb". Colors are display-only; cross-platform pixel
/// equality with web is NOT a goal — the [] -on-failure contract is.
/// Pure CoreGraphics/ImageIO so it runs in SwiftPM tests and SpoolMac.
public enum PosterPalette {

    public static func extract(from data: Data, maxColors: Int = 3) -> [String] {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return []
        }

        // Downsample to at most 24x36 (poster aspect) for stable, cheap counting.
        let targetW = 24, targetH = 36
        guard let ctx = CGContext(
            data: nil, width: targetW, height: targetH,
            bitsPerComponent: 8, bytesPerRow: targetW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        guard let pixels = ctx.data else { return [] }

        // Bucket key: 4 bits per channel. Track count + component sums per bucket.
        var counts: [UInt16: (count: Int, r: Int, g: Int, b: Int)] = [:]
        let buf = pixels.bindMemory(to: UInt8.self, capacity: targetW * targetH * 4)
        for i in 0..<(targetW * targetH) {
            let r = Int(buf[i * 4]), g = Int(buf[i * 4 + 1]), b = Int(buf[i * 4 + 2])
            let a = Int(buf[i * 4 + 3])
            if a < 128 { continue } // skip transparent
            let key = UInt16(((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4))
            var entry = counts[key] ?? (0, 0, 0, 0)
            entry = (entry.count + 1, entry.r + r, entry.g + g, entry.b + b)
            counts[key] = entry
        }
        guard !counts.isEmpty else { return [] }

        // Top buckets by count; deterministic tie-break on bucket key.
        let top = counts.sorted { lhs, rhs in
            lhs.value.count != rhs.value.count
                ? lhs.value.count > rhs.value.count
                : lhs.key < rhs.key
        }.prefix(maxColors)

        return top.map { _, v in
            String(format: "#%02x%02x%02x", v.r / v.count, v.g / v.count, v.b / v.count)
        }
    }
}
