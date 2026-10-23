import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

@main struct PhotoMetadataSmoke {
    static func main() throws {
        let props: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "2026:09:01 14:28:00", kCGImagePropertyExifOffsetTimeOriginal as String: "+08:00"],
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Apple", kCGImagePropertyTIFFModel as String: "iPhone 16 Pro"],
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 31.2, kCGImagePropertyGPSLatitudeRef as String: "S", kCGImagePropertyGPSLongitude as String: 121.5, kCGImagePropertyGPSLongitudeRef as String: "W"]
        ]
        let parsed = PhotoMetadataReader.read(properties: props, includeLocation: true)
        precondition(parsed.location?.latitude == -31.2 && parsed.location?.longitude == -121.5)
        precondition(parsed.capturedAt == ISO8601DateFormatter().date(from: "2026-09-01T06:28:00Z"))
        precondition(parsed.device == "iPhone 16 Pro" && parsed.importMethod == .library)
        precondition(PhotoMetadataReader.read(properties: props, includeLocation: false).location == nil)
        let empty = PhotoMetadataReader.read(properties: [:], includeLocation: true)
        precondition(empty.device == nil && empty.capturedAt == nil && empty.location == nil)
        var invalid = props
        invalid[kCGImagePropertyGPSDictionary as String] = [kCGImagePropertyGPSLatitude as String: 91.0, kCGImagePropertyGPSLatitudeRef as String: "N", kCGImagePropertyGPSLongitude as String: 10.0, kCGImagePropertyGPSLongitudeRef as String: "E"]
        precondition(PhotoMetadataReader.read(properties: invalid, includeLocation: true).location == nil)
        // Real ImageIO roundtrip proves extraction occurs from the original file, before recompression.
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, ctx.makeImage()!, props as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        let fromFile = PhotoMetadataReader.read(data as Data, includeLocation: true)
        precondition(fromFile.device == parsed.device && fromFile.capturedAt == parsed.capturedAt)
        precondition(abs(fromFile.location!.latitude - parsed.location!.latitude) < 0.00001)
        print("Photo metadata: original date/timezone/device, GPS hemispheres, opt-out, missing/invalid metadata, real JPEG passed")
    }
}
