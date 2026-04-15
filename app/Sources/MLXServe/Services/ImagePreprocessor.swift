import Foundation
import AppKit
import ImageIO

enum ImagePreprocessor {

    /// Preprocess an image for the Gemma 4 SigLIP vision encoder.
    /// - Resize to 768x768 (bicubic)
    /// - Convert to float32 CHW [3, 768, 768]
    /// - Rescale by 1/255 (no normalization — mean=[0,0,0], std=[1,1,1])
    /// - Returns raw float32 bytes (3*768*768*4 = 7,077,888 bytes)
    static func preprocess(_ imageData: Data, targetSize: Int = 768) -> Data? {
        // Path 1: CGImageSource — handles EXIF orientation for camera JPEGs
        if let source = CGImageSourceCreateWithData(imageData as CFData, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: targetSize,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
               let result = renderToFloat32CHW(cgImage, targetSize: targetSize) {
                return result
            }
        }

        // Path 2: NSImage fallback — handles formats CGImageSource might reject
        if let image = NSImage(data: imageData) {
            var rect = NSRect(x: 0, y: 0, width: targetSize, height: targetSize)
            if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
               let result = renderToFloat32CHW(cgImage, targetSize: targetSize) {
                return result
            }
        }

        return nil
    }

    static func preprocess(_ image: NSImage, targetSize: Int = 768) -> Data? {
        // Try via JPEG data first (preserves EXIF for CGImageSource path)
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95]),
           let result = preprocess(jpegData, targetSize: targetSize) {
            return result
        }

        // Direct CGImage fallback
        var rect = NSRect(x: 0, y: 0, width: targetSize, height: targetSize)
        if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return renderToFloat32CHW(cgImage, targetSize: targetSize)
        }

        return nil
    }

    /// Render a CGImage into a 768x768 RGBA bitmap and convert to float32 CHW.
    /// Uses explicit big-endian byte order to guarantee [R, G, B, X] memory layout
    /// regardless of platform endianness.
    private static func renderToFloat32CHW(_ cgImage: CGImage, targetSize: Int) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let rowBytes = targetSize * 4
        // Explicit byte order: byteOrder32Big ensures memory is [R, G, B, X] per pixel.
        // Without this, ARM (little-endian) defaults to [X, B, G, R] which scrambles colors.
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: targetSize,
            height: targetSize,
            bitsPerComponent: 8,
            bytesPerRow: rowBytes,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // Flip Y axis: CGContext origin is bottom-left, vision encoder expects top-left
        ctx.translateBy(x: 0, y: CGFloat(targetSize))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))

        guard let data = ctx.data else { return nil }
        let ptr = data.assumingMemoryBound(to: UInt8.self)

        // Memory layout is guaranteed [R, G, B, X] per pixel (byteOrder32Big)
        let channelSize = targetSize * targetSize
        var pixels = [Float](repeating: 0, count: 3 * channelSize)

        for y in 0..<targetSize {
            let rowStart = y * rowBytes
            for x in 0..<targetSize {
                let pixelOffset = rowStart + x * 4
                let idx = y * targetSize + x
                pixels[0 * channelSize + idx] = Float(ptr[pixelOffset])     / 255.0  // R
                pixels[1 * channelSize + idx] = Float(ptr[pixelOffset + 1]) / 255.0  // G
                pixels[2 * channelSize + idx] = Float(ptr[pixelOffset + 2]) / 255.0  // B
            }
        }

        return pixels.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
        }
    }
}
