import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The image a scope carries on its tile, as the app stores it: a square PNG of at most `side` pixels, whatever
/// was picked. Normalising on import keeps a 20 MB photo from being decoded at every launch for a 20 pt tile, and
/// lets the tile draw every image the same way — always inside its square, never cropped blind.
public enum ScopeLogo {
    /// Side of the stored square, in pixels: the 20 pt tile at 3x is 60, so this leaves room for a larger tile.
    public static let side = 128
    public static let minimumSourceSide = 16
    public static let maximumSourceSide = 16_384
    public static let maximumSourceBytes = 64 << 20
    /// Past this, an image fitted in a square is a strip a few points high: unreadable on a tile.
    public static let maximumAspectRatio = 3.0

    /// The analysis runs on a copy this large at most; the source is never decoded at full size.
    private static let workingSide = 512

    public enum Failure: Error, Equatable, Sendable {
        case notAnImage
        case tooHeavy(bytes: Int)
        case tooSmall(width: Int, height: Int)
        case tooLarge(width: Int, height: Int)
        case tooElongated
        case empty
        case unwritable

        /// One sentence for the alert shown when an image is refused.
        public var reason: String {
            switch self {
            case .notAnImage:
                "Scope could not read it as an image. PNG, JPEG, HEIC, GIF, TIFF, WebP, ICNS, SVG and PDF work."
            case .tooHeavy(let bytes):
                "It weighs \(bytes >> 20) MB; the limit is \(maximumSourceBytes >> 20) MB."
            case .tooSmall(let width, let height):
                "It is \(width) × \(height) pixels; a tile needs at least \(minimumSourceSide) × \(minimumSourceSide)."
            case .tooLarge(let width, let height):
                "It is \(width) × \(height) pixels; the limit is \(maximumSourceSide) on a side."
            case .tooElongated:
                "One of its sides is more than \(Int(maximumAspectRatio)) times the other, which leaves a thin strip on a square tile. Crop it first."
            case .empty:
                "It is fully transparent: there is nothing to show."
            case .unwritable:
                "Scope could not convert it to PNG."
            }
        }
    }

    /// How the tile draws a stored image.
    public enum Style: Equatable, Sendable {
        /// No transparency: the image is the tile.
        case opaque
        /// One grey tone on transparency (a black or white glyph): drawn like the letter, in the tile's ink on its
        /// tint, so it reads in both appearances.
        case template
        /// Colours on transparency, dark on the whole: drawn on a white plate.
        case onLight
        /// Colours on transparency, light on the whole: drawn on a dark plate.
        case onDark
    }

    // MARK: Import

    /// The stored form of the image file `data`. Reads its size before decoding anything, and decodes a reduced
    /// copy only.
    public static func normalized(_ data: Data) throws(Failure) -> Data {
        guard data.count <= maximumSourceBytes else { throw .tooHeavy(bytes: data.count) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw .notAnImage }
        try checkSize(width: width, height: height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: workingSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw .notAnImage }
        return try compose(image)
    }

    /// The stored form of a decoded image (what the app rasterises from a vector file, or reads off the clipboard).
    public static func normalized(_ image: CGImage) throws(Failure) -> Data {
        try checkSize(width: image.width, height: image.height)
        return try compose(image)
    }

    /// Whether `data` is already in the stored form — what tells a v0.14.0 copy (the file as it was picked) apart.
    public static func isNormalized(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source), type as String == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        return width == height && width <= side
    }

    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: Display

    public static func style(of image: CGImage) -> Style {
        guard let bitmap = Bitmap(image, width: image.width, height: image.height), bitmap.hasTransparency else { return .opaque }
        var visible = 0, grey = 0
        var lowest = 255, highest = 0
        var luminance = 0.0, weight = 0.0
        for index in stride(from: 0, to: bitmap.pixels.count, by: 4) {
            let alpha = Int(bitmap.pixels[index + 3])
            // Faint edge pixels carry rounding noise once unpremultiplied; they do not decide the tone.
            guard alpha > 64 else { continue }
            let red = min(255, Int(bitmap.pixels[index]) * 255 / alpha)
            let green = min(255, Int(bitmap.pixels[index + 1]) * 255 / alpha)
            let blue = min(255, Int(bitmap.pixels[index + 2]) * 255 / alpha)
            let light = (red * 299 + green * 587 + blue * 114) / 1000
            visible += 1
            if max(red, green, blue) - min(red, green, blue) <= 24 { grey += 1 }
            lowest = min(lowest, light)
            highest = max(highest, light)
            luminance += Double(light * alpha)
            weight += Double(alpha)
        }
        guard visible > 0 else { return .onLight }
        if grey * 100 >= visible * 99, highest - lowest <= 48 { return .template }
        return luminance / weight > 170 ? .onDark : .onLight
    }

    // MARK: Composition

    private static func checkSize(width: Int, height: Int) throws(Failure) {
        guard min(width, height) >= minimumSourceSide else { throw .tooSmall(width: width, height: height) }
        guard max(width, height) <= maximumSourceSide else { throw .tooLarge(width: width, height: height) }
    }

    private static func compose(_ image: CGImage) throws(Failure) -> Data {
        let scale = min(1, Double(workingSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let working = Bitmap(image, width: width, height: height), let reduced = working.context.makeImage() else {
            throw .notAnImage
        }

        // What is drawn, and on what. A transparent image is trimmed to what it shows, then fitted whole. An opaque
        // one on a flat ground (a wordmark on white) is fitted on that ground; anything else opaque is a picture,
        // and fills the square from its centre.
        var content = CGRect(x: 0, y: 0, width: width, height: height)
        var ground: CGColor?
        var fills = false
        if working.hasTransparency {
            guard let bounds = working.visibleBounds else { throw .empty }
            content = bounds
        } else if let flat = working.flatBorder {
            ground = flat
        } else {
            fills = true
        }
        let long = max(content.width, content.height), short = min(content.width, content.height)
        guard long / short <= maximumAspectRatio else { throw .tooElongated }

        let canvasSide = min(side, Int(long))
        guard let cropped = reduced.cropping(to: content),
              let canvas = Bitmap.context(width: canvasSide, height: canvasSide)
        else { throw .unwritable }
        let square = CGRect(x: 0, y: 0, width: canvasSide, height: canvasSide)
        if let ground {
            canvas.setFillColor(ground)
            canvas.fill(square)
        }
        let ratio = Double(canvasSide) / (fills ? short : long)
        let drawn = CGSize(width: content.width * ratio, height: content.height * ratio)
        canvas.interpolationQuality = .high
        canvas.draw(cropped, in: CGRect(x: (Double(canvasSide) - drawn.width) / 2, y: (Double(canvasSide) - drawn.height) / 2,
                                        width: drawn.width, height: drawn.height))

        let output = NSMutableData()
        guard let result = canvas.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { throw .unwritable }
        CGImageDestinationAddImage(destination, result, nil)
        guard CGImageDestinationFinalize(destination) else { throw .unwritable }
        return output as Data
    }
}

/// An image drawn into sRGB RGBA bytes (premultiplied), top row first.
private struct Bitmap {
    let width: Int
    let height: Int
    let context: CGContext
    let pixels: UnsafeBufferPointer<UInt8>

    static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    init?(_ image: CGImage, width: Int, height: Int) {
        guard let context = Self.context(width: width, height: height), let data = context.data else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.width = width
        self.height = height
        self.context = context
        pixels = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)
    }

    private func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * width + x) * 4 + 3] }

    var hasTransparency: Bool {
        stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 250 }
    }

    /// The rectangle holding every pixel that shows, in `CGImage.cropping` coordinates (top-left origin).
    var visibleBounds: CGRect? {
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where alpha(x, y) > 8 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The colour of the image's edge when the whole edge is that one colour (within what JPEG noise moves).
    var flatBorder: CGColor? {
        var edge: [Int] = []
        for x in 0..<width { edge += [x, (height - 1) * width + x] }
        for y in 0..<height { edge += [y * width, y * width + width - 1] }
        var sum = [0, 0, 0]
        for index in edge { for channel in 0..<3 { sum[channel] += Int(pixels[index * 4 + channel]) } }
        let mean = sum.map { $0 / edge.count }
        for index in edge {
            for channel in 0..<3 where abs(Int(pixels[index * 4 + channel]) - mean[channel]) > 14 { return nil }
        }
        return CGColor(srgbRed: CGFloat(mean[0]) / 255, green: CGFloat(mean[1]) / 255, blue: CGFloat(mean[2]) / 255, alpha: 1)
    }
}
