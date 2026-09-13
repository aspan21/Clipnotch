import AppKit
import CryptoKit
import Foundation

enum ImageUtil {
    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    static func pixelSize(of image: NSImage) -> CGSize? {
        guard let rep = image.representations.first else { return nil }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    /// Aspect-fit downscale used for card thumbnails. Keeps disk and memory small.
    static func thumbnail(from image: NSImage, maxEdge: CGFloat = 280) -> Data? {
        guard let source = pixelSize(of: image), source.width > 0, source.height > 0 else { return nil }
        let scale = min(1, maxEdge / max(source.width, source.height))
        let target = CGSize(width: max(1, (source.width * scale).rounded()),
                            height: max(1, (source.height * scale).rounded()))

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        bitmap.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: CGRect(origin: .zero, size: target),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .png, properties: [:])
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
