import Foundation

/// A bucket and literal object-key prefix in an `s3://` location. Codable as its `displayString`.
public struct S3Location: Codable, Hashable, Sendable {
  public enum ParseError: Error, Equatable {
    case invalidScheme
    case missingBucket
  }

  public let bucket: String
  public let prefix: String

  public init(bucket: String, prefix: String = "") throws {
    guard !bucket.isEmpty, !bucket.contains("/") else { throw ParseError.missingBucket }
    self.bucket = bucket
    self.prefix = prefix
  }

  public init(_ text: String) throws {
    guard text.hasPrefix("s3://") else { throw ParseError.invalidScheme }
    let remainder = text.dropFirst(5)
    let separator = remainder.firstIndex(of: "/")
    let bucket = separator.map { String(remainder[..<$0]) } ?? String(remainder)
    let prefix = separator.map { String(remainder[remainder.index(after: $0)...]) } ?? ""
    try self.init(bucket: bucket, prefix: prefix)
  }

  /// Parses s3://bucket/path, https://s3.console.aws.amazon.com/s3/buckets/<b>?prefix=<p>
  /// (and /s3/object/<b>?prefix=<key>), virtual-host object URLs
  /// https://<b>.s3[.-<region>].amazonaws.com/<key>, and path-style
  /// https://s3[.-<region>].amazonaws.com/<b>/<key>.
  /// Trims whitespace, percent-decodes path/query (s3:// stays literal; "+" is a space in amazonaws.com
  /// paths, as in the console's Object URL). `prefix` may be an object key (no trailing "/"). Nil when
  /// unrecognised.
  public init?(link: String) {
    let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("s3://") {
      guard let location = try? S3Location(text) else { return nil }
      self = location
      return
    }
    guard let components = URLComponents(string: text),
      ["https", "http"].contains(components.scheme?.lowercased()),
      let host = components.host?.lowercased()
    else { return nil }
    let location: S3Location?
    if host.hasSuffix("console.aws.amazon.com") || host.hasSuffix("console.amazonaws.cn") {
      guard let path = components.percentEncodedPath.removingPercentEncoding else { return nil }
      let parts = path.split(separator: "/")
      guard parts.count == 3, parts[0] == "s3", ["buckets", "object"].contains(parts[1]) else { return nil }
      let prefix = components.queryItems?.first { $0.name == "prefix" }?.value ?? ""
      location = try? S3Location(bucket: String(parts[2]), prefix: prefix)
    } else if host.hasSuffix(".amazonaws.com") || host.hasSuffix(".amazonaws.com.cn") {
      guard
        let path = components.percentEncodedPath.replacingOccurrences(of: "+", with: "%20")
          .removingPercentEncoding
      else { return nil }
      let labels = host.split(separator: ".")
      // The service label is the last s3/s3-* one; a bucket may itself start with "s3-".
      guard let s3 = labels.lastIndex(where: { $0 == "s3" || $0.hasPrefix("s3-") }) else { return nil }
      location =
        s3 == 0
        ? try? S3Location("s3:/" + path)
        : try? S3Location(bucket: labels[..<s3].joined(separator: "."), prefix: String(path.dropFirst()))
    } else {
      return nil
    }
    guard let location else { return nil }
    self = location
  }

  public var displayString: String {
    "s3://\(bucket)/\(prefix)"
  }

  /// The folder that contains `prefix` ("a/b/c.txt" → "a/b/", "a/b/" → "a/", "a" → "");
  /// nil at the bucket root.
  public var parent: S3Location? {
    guard !prefix.isEmpty else { return nil }
    var scalars = prefix.unicodeScalars
    if scalars.last == "/" { scalars.removeLast() }
    let end = scalars.lastIndex(of: "/").map { scalars.index(after: $0) } ?? scalars.startIndex
    return try? S3Location(bucket: bucket, prefix: String(String.UnicodeScalarView(scalars[..<end])))
  }

  public init(from decoder: Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(displayString)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.bucket.utf8.elementsEqual(rhs.bucket.utf8)
      && lhs.prefix.utf8.elementsEqual(rhs.prefix.utf8)
  }

  public func hash(into hasher: inout Hasher) {
    for byte in bucket.utf8 { hasher.combine(byte) }
    hasher.combine(UInt8(0xFF))  // never occurs in UTF-8, so bucket and prefix bytes can't run together
    for byte in prefix.utf8 { hasher.combine(byte) }
  }
}
