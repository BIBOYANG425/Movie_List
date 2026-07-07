import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Spool

final class PosterPaletteTests: XCTestCase {

    /// PNG-encoded solid or striped test image, built without UIKit.
    private func pngData(stripes: [(CGColor, CGFloat)], size: CGSize = .init(width: 32, height: 48)) throws -> Data {
        let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        var y: CGFloat = 0
        for (color, fraction) in stripes {
            let h = size.height * fraction
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: 0, y: y, width: size.width, height: h))
            y += h
        }
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, 1])!
    }

    func testSolidRedYieldsRedFirst() throws {
        let data = try pngData(stripes: [(rgb(1, 0, 0), 1.0)])
        let colors = PosterPalette.extract(from: data)
        XCTAssertEqual(colors.first, "#ff0000")
        XCTAssertLessThanOrEqual(colors.count, 3)
    }

    func testTwoToneOrdersByDominance() throws {
        // 75% blue, 25% red → blue must rank first
        let data = try pngData(stripes: [(rgb(0, 0, 1), 0.75), (rgb(1, 0, 0), 0.25)])
        let colors = PosterPalette.extract(from: data)
        XCTAssertEqual(colors.first, "#0000ff")
        XCTAssertTrue(colors.contains("#ff0000"), "second stripe should appear: \(colors)")
    }

    func testHexFormatIsLowercaseSixDigit() throws {
        let data = try pngData(stripes: [(rgb(0.5, 0.25, 0.75), 1.0)])
        let colors = PosterPalette.extract(from: data)
        for c in colors {
            XCTAssertTrue(c.range(of: "^#[0-9a-f]{6}$", options: .regularExpression) != nil, c)
        }
    }

    func testGarbageDataReturnsEmpty() {
        XCTAssertEqual(PosterPalette.extract(from: Data([0xDE, 0xAD, 0xBE, 0xEF])), [])
        XCTAssertEqual(PosterPalette.extract(from: Data()), [])
    }
}
