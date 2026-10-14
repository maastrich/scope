import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ScopeCore

@Suite struct ScopeLogoTests {
    private static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private static let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    private static let red = CGColor(srgbRed: 0.9, green: 0.1, blue: 0.2, alpha: 1)
    private static let navy = CGColor(srgbRed: 0.1, green: 0.1, blue: 0.4, alpha: 1)

    /// An image drawn by `draw` on a transparent canvas (origin bottom-left, as CoreGraphics has it).
    private func image(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return context.makeImage()!
    }

    private func fill(_ context: CGContext, _ color: CGColor, _ rect: CGRect) {
        context.setFillColor(color)
        context.fill(rect)
    }

    private func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// RGBA of the stored image at `x`, `y` from the top-left.
    private func pixel(_ data: Data, _ x: Int, _ y: Int) -> [UInt8] {
        let stored = ScopeLogo.decode(data)!
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(stored, in: CGRect(x: -x, y: -(stored.height - 1 - y), width: stored.width, height: stored.height))
        return bytes
    }

    @Test func aLargeFileIsStoredAsASmallSquarePNG() throws {
        let source = png(image(2000, 2000) { fill($0, Self.red, CGRect(x: 0, y: 0, width: 2000, height: 2000)) })
        let stored = try ScopeLogo.normalized(source)
        let decoded = try #require(ScopeLogo.decode(stored))
        #expect(decoded.width == ScopeLogo.side && decoded.height == ScopeLogo.side)
        #expect(ScopeLogo.isNormalized(stored) && !ScopeLogo.isNormalized(source))
        #expect(stored.count < 4096)
        #expect(ScopeLogo.style(of: decoded) == .opaque)
        // Importing a stored image again changes nothing about its form.
        #expect(ScopeLogo.isNormalized(try ScopeLogo.normalized(stored)))
    }

    @Test func aSmallImageIsNotBlownUp() throws {
        let stored = try ScopeLogo.normalized(image(32, 32) { fill($0, Self.red, CGRect(x: 0, y: 0, width: 32, height: 32)) })
        #expect(ScopeLogo.decode(stored)?.width == 32)
        #expect(ScopeLogo.isNormalized(stored))
    }

    @Test func aPictureFillsTheSquareFromItsCentre() throws {
        // Left half red, right half navy, nothing flat about the edge: a picture.
        let stored = try ScopeLogo.normalized(image(600, 400) {
            fill($0, Self.red, CGRect(x: 0, y: 0, width: 300, height: 400))
            fill($0, Self.navy, CGRect(x: 300, y: 0, width: 300, height: 400))
        })
        let top = pixel(stored, 10, 0), bottom = pixel(stored, 118, 127)
        #expect(top[3] == 255 && top[0] > 200)
        #expect(bottom[3] == 255 && bottom[2] > 80 && bottom[0] < 60)
    }

    @Test func aWordmarkOnAFlatGroundIsFittedWholeOnThatGround() throws {
        let stored = try ScopeLogo.normalized(image(600, 300) {
            fill($0, Self.white, CGRect(x: 0, y: 0, width: 600, height: 300))
            fill($0, Self.navy, CGRect(x: 20, y: 100, width: 560, height: 100))
        })
        // The band above the wordmark is its own white, not a crop and not a hole.
        #expect(pixel(stored, 64, 4) == [255, 255, 255, 255])
        // Both ends of the wordmark are still there.
        #expect(pixel(stored, 8, 64)[2] > 80 && pixel(stored, 8, 64)[0] < 60)
        #expect(pixel(stored, 120, 64)[2] > 80)
        #expect(ScopeLogo.style(of: try #require(ScopeLogo.decode(stored))) == .opaque)
    }

    @Test func aTransparentImageIsTrimmedToWhatItShows() throws {
        // A small black disc lost in a large transparent canvas.
        let stored = try ScopeLogo.normalized(image(400, 400) {
            $0.setFillColor(Self.black)
            $0.fillEllipse(in: CGRect(x: 250, y: 40, width: 100, height: 100))
        })
        // The disc now touches the four sides of a square its own size.
        #expect(ScopeLogo.decode(stored)?.width == 100)
        #expect(pixel(stored, 1, 50)[3] > 200)
        #expect(pixel(stored, 50, 1)[3] > 200)
        #expect(pixel(stored, 0, 0)[3] == 0)
    }

    @Test func theStyleFollowsWhatTheImageIsMadeOf() throws {
        let glyph = image(128, 128) { $0.setFillColor(Self.black); $0.fillEllipse(in: CGRect(x: 8, y: 8, width: 112, height: 112)) }
        #expect(ScopeLogo.style(of: glyph) == .template)
        let whiteGlyph = image(128, 128) { $0.setFillColor(Self.white); $0.fillEllipse(in: CGRect(x: 8, y: 8, width: 112, height: 112)) }
        #expect(ScopeLogo.style(of: whiteGlyph) == .template)
        let colours = image(128, 128) {
            $0.setFillColor(Self.red); $0.fillEllipse(in: CGRect(x: 8, y: 8, width: 80, height: 80))
            fill($0, Self.navy, CGRect(x: 60, y: 60, width: 60, height: 60))
        }
        #expect(ScopeLogo.style(of: colours) == .onLight)
        let pale = image(128, 128) {
            $0.setFillColor(CGColor(srgbRed: 1, green: 0.95, blue: 0.6, alpha: 1)); $0.fillEllipse(in: CGRect(x: 8, y: 8, width: 80, height: 80))
            fill($0, Self.white, CGRect(x: 60, y: 60, width: 60, height: 60))
        }
        #expect(ScopeLogo.style(of: pale) == .onDark)
        // Black and white together are two tones: a template would flatten them into one shape.
        let twoTones = image(128, 128) {
            $0.setFillColor(Self.black); $0.fillEllipse(in: CGRect(x: 8, y: 8, width: 112, height: 112))
            fill($0, Self.white, CGRect(x: 44, y: 44, width: 40, height: 40))
        }
        #expect(ScopeLogo.style(of: twoTones) != .template)
    }

    @Test func whatCannotMakeATileIsRefusedWithItsReason() {
        #expect(throws: ScopeLogo.Failure.notAnImage) { try ScopeLogo.normalized(Data("not an image".utf8)) }
        #expect(throws: ScopeLogo.Failure.tooHeavy(bytes: ScopeLogo.maximumSourceBytes + 1)) {
            try ScopeLogo.normalized(Data(count: ScopeLogo.maximumSourceBytes + 1))
        }
        #expect(throws: ScopeLogo.Failure.tooSmall(width: 1, height: 1)) {
            try ScopeLogo.normalized(png(image(1, 1) { fill($0, Self.black, CGRect(x: 0, y: 0, width: 1, height: 1)) }))
        }
        #expect(throws: ScopeLogo.Failure.tooElongated) {
            try ScopeLogo.normalized(image(1000, 100) { fill($0, Self.red, CGRect(x: 0, y: 0, width: 1000, height: 100)) })
        }
        #expect(throws: ScopeLogo.Failure.empty) { try ScopeLogo.normalized(image(64, 64) { _ in }) }
        // A transparent canvas of a fine shape whose content is a strip is a strip all the same.
        #expect(throws: ScopeLogo.Failure.tooElongated) {
            try ScopeLogo.normalized(image(400, 400) { fill($0, Self.black, CGRect(x: 0, y: 190, width: 400, height: 20)) })
        }
        let failures: [ScopeLogo.Failure] = [.notAnImage, .tooHeavy(bytes: 1 << 30), .tooSmall(width: 1, height: 1),
                                             .tooLarge(width: 20_000, height: 10), .tooElongated, .empty, .unwritable]
        #expect(failures.allSatisfy { !$0.reason.isEmpty })
    }
}
