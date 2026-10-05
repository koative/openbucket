import Foundation

public enum AddressingStyle: String, Codable, Sendable {
  case automatic
  case path
  case virtualHost
}

/// Where a profile's credentials come from.
public enum CredentialSource: Codable, Hashable, Sendable {
  /// Access keys in the platform credential store under `credentialReference`.
  case keychain
  /// Named profile in ~/.aws/config|credentials (static keys, role, IAM Identity Center/SSO, login).
  case awsProfile(String)
}

/// Non-secret connection settings. `credentialReference` resolves in the platform credential store.
public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
  public let id: UUID
  public var name: String
  public var endpoint: S3Endpoint
  public var region: String
  public var addressingStyle: AddressingStyle
  public var knownBucket: String?
  public var startingPrefix: String
  public let credentialReference: UUID
  public var credentialSource: CredentialSource
  public var favorites: [S3Location]
  /// Writes (upload, rename, delete…) are refused unless the user turned this on for the connection.
  public var allowsChanges: Bool

  public init(
    id: UUID = UUID(),
    name: String,
    endpoint: S3Endpoint,
    region: String,
    addressingStyle: AddressingStyle,
    knownBucket: String? = nil,
    startingPrefix: String = "",
    credentialReference: UUID = UUID(),
    credentialSource: CredentialSource = .keychain,
    favorites: [S3Location] = [],
    allowsChanges: Bool = false
  ) {
    self.id = id
    self.name = name
    self.endpoint = endpoint
    self.region = region
    self.addressingStyle = addressingStyle
    self.knownBucket = knownBucket
    self.startingPrefix = startingPrefix
    self.credentialReference = credentialReference
    self.credentialSource = credentialSource
    self.favorites = favorites
    self.allowsChanges = allowsChanges
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, endpoint, region, addressingStyle, knownBucket, startingPrefix, credentialReference
    case credentialSource, favorites, allowsChanges
  }

  /// Accepts profiles saved before `credentialSource`, `favorites`, and `allowsChanges` existed.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(UUID.self, forKey: .id),
      name: try container.decode(String.self, forKey: .name),
      endpoint: try container.decode(S3Endpoint.self, forKey: .endpoint),
      region: try container.decode(String.self, forKey: .region),
      addressingStyle: try container.decode(AddressingStyle.self, forKey: .addressingStyle),
      knownBucket: try container.decodeIfPresent(String.self, forKey: .knownBucket),
      startingPrefix: try container.decode(String.self, forKey: .startingPrefix),
      credentialReference: try container.decode(UUID.self, forKey: .credentialReference),
      credentialSource: try container.decodeIfPresent(CredentialSource.self, forKey: .credentialSource)
        ?? .keychain,
      favorites: try container.decodeIfPresent([S3Location].self, forKey: .favorites) ?? [],
      allowsChanges: try container.decodeIfPresent(Bool.self, forKey: .allowsChanges) ?? false
    )
  }

  /// The single source of truth for addressing combinations Soto would silently change; nil when fine.
  /// A nil or empty `bucket` checks only the endpoint rules.
  public func addressingProblem(bucket: String?) -> String? {
    let bucket = bucket ?? ""
    switch addressingStyle {
    case .automatic:
      return nil
    case .path:
      guard endpoint.isAmazon, !bucket.isEmpty, !bucket.contains(".") else { return nil }
      return "Amazon S3 needs virtual-host addressing for this bucket. Choose Automatic or Virtual host."
    case .virtualHost:
      if !["", "/"].contains(endpoint.url.path(percentEncoded: true)) {
        return "Virtual-host addressing can't be used with an endpoint path. Choose Path style."
      }
      guard bucket.contains(".") else { return nil }
      return "Virtual-host addressing can't be used with a bucket name that contains dots. "
        + "Choose Automatic or Path style."
    }
  }
}

/// Ephemeral S3 identity. This type intentionally does not conform to Codable.
public struct S3Credentials: Sendable {
  public let accessKeyID: String
  public let secretAccessKey: String
  public let sessionToken: String?
  /// When temporary credentials stop working; nil for long-lived keys.
  public let expiration: Date?

  public init(
    accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil, expiration: Date? = nil
  ) {
    self.accessKeyID = accessKeyID
    self.secretAccessKey = secretAccessKey
    self.sessionToken = sessionToken
    self.expiration = expiration
  }
}
