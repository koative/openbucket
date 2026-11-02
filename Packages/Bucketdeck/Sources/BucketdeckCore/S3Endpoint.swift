import Foundation

/// A service URL whose path remains part of every S3 request.
public struct S3Endpoint: Codable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable {
    case invalidURL
    case unsupportedScheme
    case missingHost
    case userInfoNotAllowed
    case queryOrFragmentNotAllowed
    case encodedPathNotSupported
  }

  public let absoluteString: String

  public var url: URL { URL(string: absoluteString)! }

  /// True for `amazonaws.com` / `amazonaws.com.cn` hosts and their subdomains.
  public var isAmazon: Bool {
    guard let host = url.host()?.lowercased() else { return false }
    return ["amazonaws.com", "amazonaws.com.cn"].contains { host == $0 || host.hasSuffix("." + $0) }
  }

  public init(_ value: String) throws {
    guard let components = URLComponents(string: value), let url = components.url else {
      throw ValidationError.invalidURL
    }
    guard let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme) else {
      throw ValidationError.unsupportedScheme
    }
    guard let host = components.host, !host.isEmpty else {
      throw ValidationError.missingHost
    }
    guard components.user == nil, components.password == nil else {
      throw ValidationError.userInfoNotAllowed
    }
    guard components.query == nil, components.fragment == nil else {
      throw ValidationError.queryOrFragmentNotAllowed
    }
    guard !components.percentEncodedPath.contains("%") else {
      throw ValidationError.encodedPathNotSupported
    }
    absoluteString = url.absoluteString
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(absoluteString)
  }
}
