import Foundation
import ImageIO

/// Extract before image recompression, which intentionally strips the durable JPEG's metadata.
enum PhotoMetadataReader {
    static func read(_ data: Data, includeLocation: Bool) -> PhotoCaptureMetadata {
        guard data.count <= 80 * 1_024 * 1_024, let image = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any] else {
            return PhotoCaptureMetadata(importMethod: .library)
        }
        return read(properties: properties, includeLocation: includeLocation)
    }
    static func read(properties: [String: Any], includeLocation: Bool) -> PhotoCaptureMetadata {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let rawDate = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
        let offset = exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.isLenient = false
        formatter.dateFormat = offset == nil ? "yyyy:MM:dd HH:mm:ss" : "yyyy:MM:dd HH:mm:ssxxx"
        let date = rawDate.flatMap { formatter.date(from: $0 + (offset ?? "")) }
        let model = (tiff[kCGImagePropertyTIFFModel as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let make = (tiff[kCGImagePropertyTIFFMake as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let device: String? = model.flatMap { value in
            guard !value.isEmpty else { return nil }
            if let make, !make.isEmpty, make != "Apple", !value.localizedCaseInsensitiveContains(make) { return String((make + " " + value).prefix(100)) }
            return String(value.prefix(100))
        }
        var result = PhotoCaptureMetadata(capturedAt: date, device: device, importMethod: .library)
        result.timeZoneKnown = date == nil ? nil : offset != nil
        if date != nil, let rawDate, rawDate.count >= 10 {
            result.originalLocalDate = String(rawDate.prefix(10)).replacingOccurrences(of: ":", with: "-")
        }
        if date != nil, let offset, offset.range(of: #"^[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil {
            let parts = offset.dropFirst().split(separator: ":").compactMap { Int($0) }
            if parts.count == 2, parts[0] <= 14, parts[1] < 60 {
                result.capturedTimeZoneIdentifier = TimeZone(secondsFromGMT: (offset.hasPrefix("-") ? -1 : 1) * (parts[0] * 3600 + parts[1] * 60))?.identifier
            }
        }
        guard includeLocation, let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
              let latitude = (gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue,
              let longitude = (gps[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue,
              let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String,
              let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String,
              ["N", "S"].contains(latRef.uppercased()), ["E", "W"].contains(lonRef.uppercased()),
              latitude >= 0, longitude >= 0 else { return result }
        let accuracy = (gps[kCGImagePropertyGPSHPositioningError as String] as? NSNumber)?.doubleValue
        result.location = CaptureLocation(latitude: latRef.uppercased() == "S" ? -latitude : latitude,
            longitude: lonRef.uppercased() == "W" ? -longitude : longitude, accuracy: accuracy.flatMap { $0 >= 0 ? $0 : nil },
            measuredAt: date, source: .photoMetadata)
        return result
    }
}
