import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Embedded thumbnail and EXIF summary from the first bytes of an image file.
enum ImageMetadata {
  /// Bytes to range-read; enough for the EXIF block and its embedded thumbnail in typical camera files.
  static let prefixLength: Int64 = 256 * 1024

  struct Info: Equatable, Sendable {
    let pixelWidth: Int?
    let pixelHeight: Int?
    let make: String?
    let model: String?
    let lens: String?
    let dateTaken: Date?
    /// e.g. "1/250 s · ƒ/2.8 · ISO 200 · 35 mm"
    let exposure: String?
    let latitude: Double?
    let longitude: Double?
  }

  /// `data` may be a truncated prefix. Only an embedded thumbnail is returned, never a decode of the image.
  static func read(_ data: Data) -> (thumbnail: CGImage?, info: Info?) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0
    else { return (nil, nil) }
    var thumbnail = CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxThumbnailSize,
      ] as CFDictionary)
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
      return (nil, nil)
    }
    if let decoded = thumbnail, isMainImageDecode(decoded, properties: properties, source: source) {
      thumbnail = nil
    }
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

    var exposure: [String] = []
    if let seconds = exif[kCGImagePropertyExifExposureTime] as? Double, seconds > 0 {
      exposure.append(exposureTime(seconds))
    }
    if let fNumber = exif[kCGImagePropertyExifFNumber] as? Double {
      exposure.append("ƒ/\(fNumber.formatted())")
    }
    if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first {
      exposure.append("ISO \(iso)")
    }
    if let focalLength = exif[kCGImagePropertyExifFocalLength] as? Double {
      exposure.append("\(focalLength.formatted()) mm")
    }

    let info = Info(
      pixelWidth: properties[kCGImagePropertyPixelWidth] as? Int,
      pixelHeight: properties[kCGImagePropertyPixelHeight] as? Int,
      make: tiff[kCGImagePropertyTIFFMake] as? String,
      model: tiff[kCGImagePropertyTIFFModel] as? String,
      lens: exif[kCGImagePropertyExifLensModel] as? String,
      dateTaken: date(
        exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff[kCGImagePropertyTIFFDateTime]
          as? String,
        offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String),
      exposure: exposure.isEmpty ? nil : exposure.joined(separator: " · "),
      latitude: coordinate(
        gps[kCGImagePropertyGPSLatitude], negative: gps[kCGImagePropertyGPSLatitudeRef], "S"),
      longitude: coordinate(
        gps[kCGImagePropertyGPSLongitude], negative: gps[kCGImagePropertyGPSLongitudeRef], "W"))
    return (thumbnail, info)
  }

  /// "1/250 s" for fast shutter speeds and exact fractions like 1/2 or 1/3; "0.8 s" or "2 s" otherwise.
  static func exposureTime(_ seconds: Double) -> String {
    let reciprocal = 1 / seconds
    return seconds < 1 && (seconds <= 0.25 || abs(reciprocal - reciprocal.rounded()) < 0.05)
      ? "1/\(Int(reciprocal.rounded())) s" : "\(seconds.formatted()) s"
  }

  private static let maxThumbnailSize = 520

  /// Without an embedded thumbnail, ImageIO decodes the (possibly truncated) main image of JPEG-like
  /// formats instead of returning nil. Such a decode is exactly the main image scaled to the maximum
  /// size; embedded EXIF/HEIF thumbnails are smaller. RAW previews are always embedded, so keep them.
  private static func isMainImageDecode(
    _ image: CGImage, properties: [CFString: Any], source: CGImageSource
  ) -> Bool {
    if let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }), type.conforms(to: .rawImage)
    {
      return false
    }
    guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
    else { return true }
    let scale = min(1, Double(maxThumbnailSize) / Double(max(width, height)))
    let expected = (Int((Double(width) * scale).rounded()), Int((Double(height) * scale).rounded()))
    func near(_ a: Int, _ b: Int) -> Bool { abs(a - b) <= 1 }
    return (near(image.width, expected.0) && near(image.height, expected.1))
      || (near(image.width, expected.1) && near(image.height, expected.0))
  }

  /// EXIF "yyyy:MM:dd HH:mm:ss" in the camera's offset when recorded, else the Mac's time zone.
  private static func date(_ text: String?, offset: String?) -> Date? {
    guard let text else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = offset == nil ? "yyyy:MM:dd HH:mm:ss" : "yyyy:MM:dd HH:mm:ssxxx"
    return formatter.date(from: text + (offset ?? ""))
  }

  private static func coordinate(_ value: Any?, negative reference: Any?, _ negativeReference: String)
    -> Double?
  {
    guard let value = value as? Double else { return nil }
    return reference as? String == negativeReference ? -value : value
  }
}
