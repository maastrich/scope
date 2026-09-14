import AppKit
import SwiftUI

/// An image decoded for display, with the facts the headers show (pixel size, byte count).
struct DecodedImage {
    let image: NSImage
    let pixelSize: CGSize
    let bytes: Int

    init?(data: Data) {
        guard let image = NSImage(data: data), image.isValid else { return nil }
        self.image = image
        self.bytes = data.count
        // Bitmap reps know their pixel grid; `size` is in points and lies for @2x assets.
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            pixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        } else {
            pixelSize = image.size
        }
    }

    var dimensions: String { "\(Int(pixelSize.width)) × \(Int(pixelSize.height))" }

    var caption: String {
        "\(dimensions) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }
}

/// Transparency checkerboard behind every image preview, so an alpha edge reads as such.
struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            let dark = Color.primary.opacity(0.07)
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = (row % 2 == 0) ? 0 : cell
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(dark))
                    x += cell * 2
                }
                y += cell
                row += 1
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// One image scaled to fit the available space (never upscaled past its pixel size), centred on a
/// checkerboard.
struct ImageCanvas: View {
    let image: DecodedImage

    var body: some View {
        GeometryReader { proxy in
            let fitted = ImageFit.scaled(image.pixelSize, into: proxy.size.insetBy(ImageFit.padding))
            Image(nsImage: image.image)
                .resizable()
                .interpolation(.high)
                .frame(width: fitted.width, height: fitted.height)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Checkerboard())
    }
}

/// Before and after stacked on one pixel grid (top-left aligned so a resized image still overlaps where the
/// pixels coincide), the new image drawn over the old one at `opacity`.
struct OnionSkinCanvas: View {
    let old: DecodedImage
    let new: DecodedImage
    let opacity: Double

    var body: some View {
        GeometryReader { proxy in
            let grid = CGSize(width: max(old.pixelSize.width, new.pixelSize.width),
                              height: max(old.pixelSize.height, new.pixelSize.height))
            let fitted = ImageFit.scaled(grid, into: proxy.size.insetBy(ImageFit.padding))
            let scale = grid.width > 0 ? fitted.width / grid.width : 1
            ZStack(alignment: .topLeading) {
                Image(nsImage: old.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: old.pixelSize.width * scale, height: old.pixelSize.height * scale)
                Image(nsImage: new.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: new.pixelSize.width * scale, height: new.pixelSize.height * scale)
                    .opacity(opacity)
            }
            .frame(width: fitted.width, height: fitted.height, alignment: .topLeading)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Checkerboard())
    }
}

enum ImageFit {
    static let padding: CGFloat = 12

    /// `size` scaled down to fit `bounds`, keeping its ratio; never scaled up (a 16 px icon stays 16 pt).
    static func scaled(_ size: CGSize, into bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height, 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

private extension CGSize {
    func insetBy(_ inset: CGFloat) -> CGSize {
        CGSize(width: max(0, width - inset * 2), height: max(0, height - inset * 2))
    }
}
