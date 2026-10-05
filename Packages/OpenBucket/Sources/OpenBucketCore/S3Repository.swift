import Foundation

public struct ObjectSummary: Hashable, Identifiable, Sendable {
  /// UTF-8 bytes of `key`, so keys that differ only by Unicode normalization stay distinct.
  public let id: [UInt8]
  public let key: String
  public let size: Int64
  public let lastModified: Date?
  public let eTag: String?
  public let storageClass: String?

  public init(key: String, size: Int64, lastModified: Date?, eTag: String?, storageClass: String? = nil) {
    self.id = Array(key.utf8)
    self.key = key
    self.size = size
    self.lastModified = lastModified
    self.eTag = eTag
    self.storageClass = storageClass
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.size == rhs.size && lhs.lastModified == rhs.lastModified
      && lhs.eTag == rhs.eTag && lhs.storageClass == rhs.storageClass
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(size)
    hasher.combine(lastModified)
    hasher.combine(eTag)
    hasher.combine(storageClass)
  }
}

public struct ObjectPage: Sendable {
  public let prefixes: [String]
  public let objects: [ObjectSummary]
  public let nextToken: String?

  public init(prefixes: [String], objects: [ObjectSummary], nextToken: String?) {
    self.prefixes = prefixes
    self.objects = objects
    self.nextToken = nextToken
  }
}

/// HEAD response (plus best-effort tags) for one object.
public struct ObjectDetails: Sendable {
  public let contentType, cacheControl, contentEncoding, contentDisposition, contentLanguage: String?
  public let contentLength: Int64?
  public let eTag: String?
  public let lastModified: Date?
  public let storageClass, serverSideEncryption, kmsKeyID, versionID, restore, replicationStatus: String?
  public let objectLockMode: String?
  public let objectLockRetainUntil: Date?
  public let legalHold: String?
  /// User metadata (x-amz-meta-*), keys lowercased.
  public let metadata: [String: String]
  /// Nil when tagging is denied or unsupported.
  public let tags: [String: String]?

  public init(
    contentType: String? = nil, cacheControl: String? = nil, contentEncoding: String? = nil,
    contentDisposition: String? = nil, contentLanguage: String? = nil, contentLength: Int64? = nil,
    eTag: String? = nil, lastModified: Date? = nil, storageClass: String? = nil,
    serverSideEncryption: String? = nil, kmsKeyID: String? = nil, versionID: String? = nil,
    restore: String? = nil, replicationStatus: String? = nil, objectLockMode: String? = nil,
    objectLockRetainUntil: Date? = nil, legalHold: String? = nil, metadata: [String: String] = [:],
    tags: [String: String]? = nil
  ) {
    self.contentType = contentType
    self.cacheControl = cacheControl
    self.contentEncoding = contentEncoding
    self.contentDisposition = contentDisposition
    self.contentLanguage = contentLanguage
    self.contentLength = contentLength
    self.eTag = eTag
    self.lastModified = lastModified
    self.storageClass = storageClass
    self.serverSideEncryption = serverSideEncryption
    self.kmsKeyID = kmsKeyID
    self.versionID = versionID
    self.restore = restore
    self.replicationStatus = replicationStatus
    self.objectLockMode = objectLockMode
    self.objectLockRetainUntil = objectLockRetainUntil
    self.legalHold = legalHold
    self.metadata = metadata
    self.tags = tags
  }
}

/// One object version or delete marker from ListObjectVersions.
public struct ObjectVersion: Hashable, Identifiable, Sendable {
  public let key: String
  public let versionID: String
  public let isLatest: Bool
  public let isDeleteMarker: Bool
  public let lastModified: Date?
  public let size: Int64
  public let eTag: String?
  public let storageClass: String?

  public init(
    key: String, versionID: String, isLatest: Bool, isDeleteMarker: Bool, lastModified: Date?,
    size: Int64, eTag: String?, storageClass: String?
  ) {
    self.key = key
    self.versionID = versionID
    self.isLatest = isLatest
    self.isDeleteMarker = isDeleteMarker
    self.lastModified = lastModified
    self.size = size
    self.eTag = eTag
    self.storageClass = storageClass
  }

  /// Unique per key+version; ASCII-only, so keys that differ only by Unicode normalization stay distinct.
  public var id: String {
    let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
    return [versionID, key].map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }
      .joined(separator: "/")
  }

  /// This version as a listing row, for reuse in rows and downloads.
  public var summary: ObjectSummary {
    ObjectSummary(key: key, size: size, lastModified: lastModified, eTag: eTag, storageClass: storageClass)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.key.utf8.elementsEqual(rhs.key.utf8) && lhs.versionID == rhs.versionID && lhs.isLatest == rhs.isLatest
      && lhs.isDeleteMarker == rhs.isDeleteMarker && lhs.lastModified == rhs.lastModified
      && lhs.size == rhs.size && lhs.eTag == rhs.eTag && lhs.storageClass == rhs.storageClass
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

public struct VersionPage: Sendable {
  public let prefixes: [String]
  /// Versions and delete markers, in S3 order (key, then newest first).
  public let versions: [ObjectVersion]
  /// Both nil when the listing is complete.
  public let nextKeyMarker: String?
  public let nextVersionIDMarker: String?

  public init(
    prefixes: [String], versions: [ObjectVersion], nextKeyMarker: String?, nextVersionIDMarker: String?
  ) {
    self.prefixes = prefixes
    self.versions = versions
    self.nextKeyMarker = nextKeyMarker
    self.nextVersionIDMarker = nextVersionIDMarker
  }
}

/// Content headers and user metadata written with an object; nil fields are omitted.
public struct ObjectHeaders: Hashable, Sendable {
  public var contentType: String?
  public var cacheControl: String?
  public var contentDisposition: String?
  public var contentEncoding: String?
  public var contentLanguage: String?
  /// x-amz-meta-* names without the prefix, lowercased.
  public var metadata: [String: String]

  public init(
    contentType: String? = nil, cacheControl: String? = nil, contentDisposition: String? = nil,
    contentEncoding: String? = nil, contentLanguage: String? = nil, metadata: [String: String] = [:]
  ) {
    self.contentType = contentType
    self.cacheControl = cacheControl
    self.contentDisposition = contentDisposition
    self.contentEncoding = contentEncoding
    self.contentLanguage = contentLanguage
    self.metadata = metadata
  }

  /// The editable headers of a HEAD response.
  public init(_ details: ObjectDetails) {
    self.init(
      contentType: details.contentType, cacheControl: details.cacheControl,
      contentDisposition: details.contentDisposition, contentEncoding: details.contentEncoding,
      contentLanguage: details.contentLanguage, metadata: details.metadata)
  }
}

public struct DeleteFailure: Hashable, Sendable {
  public let key: String
  public let message: String

  public init(key: String, message: String) {
    self.key = key
    self.message = message
  }
}

public enum BucketVersioning: Sendable, Equatable {
  case enabled, suspended, disabled
}

/// The S3 operations needed by the browser. Writes are only issued for profiles that allow changes;
/// enforcing that is the caller's job.
public protocol S3Repository: Sendable {
  func listBuckets(profile: ConnectionProfile, credentials: S3Credentials) async throws -> [String]

  func listObjects(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    prefix: String,
    continuationToken: String?
  ) async throws -> ObjectPage

  /// Every object under `prefix` (no delimiter, `prefixes` always empty), 1000 per page.
  func listAllObjects(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    prefix: String,
    continuationToken: String?
  ) async throws -> ObjectPage

  /// Versions and delete markers under `prefix`. Unsupported providers throw `.unsupportedOperation`.
  func listObjectVersions(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    prefix: String,
    delimiter: String?,
    keyMarker: String?,
    versionIDMarker: String?
  ) async throws -> VersionPage

  /// HEAD plus best-effort tags (`tags` is nil when tagging fails).
  func objectDetails(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    key: String,
    versionID: String?
  ) async throws -> ObjectDetails

  /// Range GET; returns fewer bytes when the object is shorter. Empty range → empty Data without a request.
  func readObjectBytes(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    key: String,
    range: Range<Int64>
  ) async throws -> Data

  /// GET-only presigned URL, signed locally (no request). A `downloadFileName` signs a
  /// `response-content-disposition` so the link downloads under that name; nil opens inline.
  /// Throws S3Failure when expiresIn is < 1 s or > 7 days.
  func presignedURL(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    key: String,
    versionID: String?,
    expiresIn: Duration,
    downloadFileName: String?
  ) async throws -> URL

  /// Credentials for a named AWS CLI profile (static, assume-role, SSO, login);
  /// `expiration` set when temporary.
  func resolveAWSProfile(_ name: String) async throws -> S3Credentials

  /// Writes the object (or `versionID`) atomically to `destination`. `progress` receives cumulative bytes per
  /// chunk from a background context. Cancellation throws `CancellationError`; local file failures throw
  /// `.localFile`.
  func downloadObject(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    key: String,
    versionID: String?,
    to destination: URL,
    maximumBytes: Int64,
    progress: @escaping @Sendable (_ bytesReceived: Int64) -> Void
  ) async throws

  /// Disabled when the bucket never had versioning turned on.
  func bucketVersioning(profile: ConnectionProfile, credentials: S3Credentials, bucket: String)
    async throws -> BucketVersioning

  /// PUT up to 16 MiB, else multipart (part size ≥ 16 MiB, grown so parts ≤ 10 000; aborted on failure or
  /// cancellation). `progress` gets cumulative bytes sent, from a background context. Reads `source` as it
  /// goes (never loads the whole file). Local read failures throw `.localFile`.
  func uploadFile(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    key: String,
    from source: URL,
    headers: ObjectHeaders,
    progress: @escaping @Sendable (_ bytesSent: Int64) -> Void
  ) async throws

  /// Zero-byte object, used for folder markers ("photos/2026/").
  func putEmptyObject(profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String)
    async throws

  /// Server-side copy inside `bucket`. `headers == nil` keeps the source's metadata (COPY);
  /// non-nil replaces it (REPLACE). Tags are kept either way. `size` is the source's size: above 5 GiB the
  /// copy is multipart. `sourceVersionID` copies that version (restore = copy a version onto its own key).
  func copyObject(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    sourceKey: String,
    sourceVersionID: String?,
    size: Int64,
    destinationKey: String,
    headers: ObjectHeaders?
  ) async throws

  /// DeleteObjects in batches of 1000, current versions only (versioned buckets get delete markers).
  /// Returns per-key failures; throws when a whole request fails.
  func deleteObjects(profile: ConnectionProfile, credentials: S3Credentials, bucket: String, keys: [String])
    async throws -> [DeleteFailure]

  /// Replaces the tag set of the current version; an empty dictionary removes all tags.
  func putObjectTags(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String,
    tags: [String: String]
  ) async throws
}
