import Foundation

/// Endpoint shapes of common S3 services, so a new connection needs only a region (or an R2 account ID).
public enum ProviderPreset: String, CaseIterable, Identifiable, Sendable {
  case amazon, cloudflareR2, backblazeB2, wasabi, digitalOceanSpaces, hetzner, other

  public var id: Self { self }

  public var title: String {
    switch self {
    case .amazon: "Amazon S3"
    case .cloudflareR2: "Cloudflare R2"
    case .backblazeB2: "Backblaze B2"
    case .wasabi: "Wasabi"
    case .digitalOceanSpaces: "DigitalOcean Spaces"
    case .hetzner: "Hetzner Object Storage"
    case .other: "Other S3-compatible"
    }
  }

  /// The region a new connection starts with; nil leaves the region as entered.
  public var defaultRegion: String? {
    switch self {
    case .amazon, .wasabi: "us-east-1"
    case .cloudflareR2: "auto"
    case .backblazeB2: "us-west-004"
    case .digitalOceanSpaces: "nyc3"
    case .hetzner: "fsn1"
    case .other: nil
    }
  }

  /// Where the region comes from, for services whose regions aren't AWS names.
  public var regionHint: String? {
    switch self {
    case .backblazeB2: "The part after s3. in your bucket’s endpoint, such as us-west-004."
    case .digitalOceanSpaces: "Your Space’s datacenter, such as nyc3 or fra1."
    case .hetzner: "Your bucket’s location: fsn1, nbg1 or hel1."
    case .cloudflareR2: "R2 always signs with auto."
    case .amazon, .wasabi, .other: nil
    }
  }

  /// The endpoint for `region`, or for `accountID` on R2; nil when it can't be built yet or for `other`.
  public func endpoint(region: String, accountID: String = "") -> String? {
    let part = self == .cloudflareR2 ? accountID : region
    guard self != .other, !part.isEmpty, part.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
      return nil
    }
    return switch self {
    case .amazon: "https://s3.\(part).amazonaws.com"
    case .cloudflareR2: "https://\(part).r2.cloudflarestorage.com"
    case .backblazeB2: "https://s3.\(part).backblazeb2.com"
    case .wasabi: "https://s3.\(part).wasabisys.com"
    case .digitalOceanSpaces: "https://\(part).digitaloceanspaces.com"
    case .hetzner: "https://\(part).your-objectstorage.com"
    case .other: nil
    }
  }

  /// The service an endpoint belongs to, `other` when it matches none.
  public init(endpoint: S3Endpoint) {
    let host = endpoint.url.host()?.lowercased() ?? ""
    let suffixes: [(String, Self)] = [
      (".r2.cloudflarestorage.com", .cloudflareR2), (".backblazeb2.com", .backblazeB2),
      (".wasabisys.com", .wasabi),
      (".digitaloceanspaces.com", .digitalOceanSpaces), (".your-objectstorage.com", .hetzner),
    ]
    self = endpoint.isAmazon ? .amazon : suffixes.first { host.hasSuffix($0.0) }?.1 ?? .other
  }

  /// The R2 account ID in an R2 endpoint, empty otherwise.
  public static func accountID(in endpoint: S3Endpoint) -> String {
    guard ProviderPreset(endpoint: endpoint) == .cloudflareR2, let host = endpoint.url.host() else {
      return ""
    }
    return String(host.prefix { $0 != "." })
  }
}

/// A connection's endpoint, region and R2 account ID, following the chosen provider until the user types over them.
public struct ProviderFields: Equatable, Sendable {
  public private(set) var provider: ProviderPreset
  public var endpoint: String
  public var region: String
  public var accountID: String
  /// What was last filled in automatically; a field still holding it keeps following.
  private var filledEndpoint: String?
  private var filledRegion: String?

  /// A saved connection's values, or Amazon S3 in us-east-1 for a new one.
  public init(endpoint saved: S3Endpoint?, region savedRegion: String?) {
    provider = saved.map(ProviderPreset.init(endpoint:)) ?? .amazon
    region = savedRegion ?? ProviderPreset.amazon.defaultRegion ?? ""
    accountID = saved.map(ProviderPreset.accountID(in:)) ?? ""
    let generated = provider.endpoint(region: region, accountID: accountID)
    endpoint = saved?.absoluteString ?? generated ?? "https://"
    // A saved endpoint that still has its provider's shape follows region and account ID edits.
    filledEndpoint = saved == nil || endpoint == generated ? generated : nil
  }

  /// Switches provider: a suggested region becomes the new provider's, and an untouched endpoint follows.
  public mutating func select(_ newProvider: ProviderPreset) {
    provider = newProvider
    if regionIsSuggested, let suggested = newProvider.defaultRegion { region = suggested }
    refreshEndpoint()
  }

  /// Rebuilds an untouched endpoint from the region and account ID.
  public mutating func refreshEndpoint() {
    guard endpointIsUntouched else { return }
    endpoint =
      provider.endpoint(region: Self.trimmed(region), accountID: Self.trimmed(accountID)) ?? "https://"
    filledEndpoint = endpoint
  }

  /// Takes an AWS profile's region unless one was typed, and points an untouched endpoint at Amazon S3.
  public mutating func useAWSProfile(region profileRegion: String?) {
    if let profileRegion, regionIsSuggested || Self.trimmed(region) == filledRegion {
      region = profileRegion
      filledRegion = profileRegion
    }
    if endpointIsUntouched {
      provider = .amazon
      refreshEndpoint()
    }
  }

  private var endpointIsUntouched: Bool {
    let current = Self.trimmed(endpoint)
    return current.isEmpty || current == "https://" || current == filledEndpoint
  }

  /// Empty, or a provider's suggestion rather than something typed.
  private var regionIsSuggested: Bool {
    let current = Self.trimmed(region)
    return current.isEmpty || ProviderPreset.allCases.contains { $0.defaultRegion == current }
  }

  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
