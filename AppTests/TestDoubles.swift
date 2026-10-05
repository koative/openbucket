import Foundation
import OpenBucketCore
import Testing

@testable import OpenBucket

/// Lists `buckets`, one object page plus a second page; downloads write the key's bytes ("bad.txt" fails).
/// AWS profiles resolve to `testCredentials` expiring `credentialLifetime` after each resolution; versions
/// and details are unsupported. With `keys`, `listAllObjects` serves those (size 1) and writes update them;
/// uploads and copies of keys ending in "bad.txt" fail, deletes of keys ending in "locked.txt" are refused.
actor StubRepository: S3Repository {
  struct Download: Sendable {
    let profileID: UUID
    let bucket: String
    let key: String
    let versionID: String?
  }

  struct Copy: Equatable, Sendable {
    let source: String
    let versionID: String?
    let destination: String
    let headers: ObjectHeaders?
  }

  private let credentialLifetime: TimeInterval?
  private let buckets: [String]
  private(set) var downloads: [Download] = []
  private(set) var resolvedProfiles: [String] = []
  /// `expiration` of the credentials each `listObjects` call used.
  private(set) var listedExpirations: [Date?] = []
  private(set) var keys: [String]?
  /// Keys and Content-Types of uploads and folder markers (nil type), in order.
  private(set) var uploads: [(key: String, contentType: String?)] = []
  private(set) var copies: [Copy] = []
  /// Keys of each deleteObjects request.
  private(set) var deletes: [[String]] = []

  init(credentialLifetime: TimeInterval? = nil, buckets: [String] = [], keys: [String]? = nil) {
    self.credentialLifetime = credentialLifetime
    self.buckets = buckets
    self.keys = keys
  }

  func listBuckets(profile: ConnectionProfile, credentials: S3Credentials) -> [String] { buckets }

  func listObjects(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    prefix: String,
    continuationToken: String?
  ) -> ObjectPage {
    listedExpirations.append(credentials.expiration)
    let key = continuationToken == nil ? "first.txt" : "second.txt"
    return ObjectPage(
      prefixes: [], objects: [ObjectSummary(key: key, size: 1, lastModified: nil, eTag: nil)],
      nextToken: continuationToken == nil ? "next" : nil)
  }

  func listAllObjects(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    prefix: String,
    continuationToken: String?
  ) -> ObjectPage {
    guard let keys else {
      return listObjects(
        profile: profile, credentials: credentials, bucket: bucket, prefix: prefix,
        continuationToken: continuationToken)
    }
    let objects = keys.filter { $0.utf8.starts(with: prefix.utf8) }.sorted()
      .map { ObjectSummary(key: $0, size: 1, lastModified: nil, eTag: nil) }
    return ObjectPage(prefixes: [], objects: objects, nextToken: nil)
  }

  func listObjectVersions(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    prefix: String,
    delimiter: String?,
    keyMarker: String?,
    versionIDMarker: String?
  ) throws -> VersionPage {
    throw S3Failure(category: .unsupportedOperation, message: "Versions aren't stubbed.")
  }

  func objectDetails(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    key: String,
    versionID: String?
  ) throws -> ObjectDetails {
    throw S3Failure(category: .unsupportedOperation, message: "Details aren't stubbed.")
  }

  /// The key's UTF-8 bytes, clamped to `range`.
  func readObjectBytes(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    key: String,
    range: Range<Int64>
  ) -> Data {
    let bytes = Data(key.utf8)
    let count = Int64(bytes.count)
    return bytes.subdata(in: Int(min(range.lowerBound, count))..<Int(min(range.upperBound, count)))
  }

  func presignedURL(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    key: String,
    versionID: String?,
    expiresIn: Duration,
    downloadFileName: String?
  ) -> URL {
    URL(string: "https://stub.invalid")!.appending(path: "\(bucket)/\(key)")
  }

  func resolveAWSProfile(_ name: String) -> S3Credentials {
    resolvedProfiles.append(name)
    return S3Credentials(
      accessKeyID: testCredentials.accessKeyID, secretAccessKey: testCredentials.secretAccessKey,
      expiration: credentialLifetime.map { Date().addingTimeInterval($0) })
  }

  func downloadObject(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    key: String,
    versionID: String?,
    to destination: URL,
    maximumBytes: Int64,
    progress: @escaping @Sendable (_ bytesReceived: Int64) -> Void
  ) throws {
    downloads.append(Download(profileID: profile.id, bucket: bucket, key: key, versionID: versionID))
    if key == "bad.txt" { throw CocoaError(.fileReadUnknown) }
    let data = Data(key.utf8)
    try data.write(to: destination)
    progress(Int64(data.count))
  }

  func bucketVersioning(profile: ConnectionProfile, credentials: S3Credentials, bucket: String)
    -> BucketVersioning
  { .enabled }

  func uploadFile(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String, from source: URL,
    headers: ObjectHeaders, progress: @escaping @Sendable (_ bytesSent: Int64) -> Void
  ) throws {
    uploads.append((key, headers.contentType))
    if key.hasSuffix("bad.txt") { throw S3Failure(category: .service, message: "Upload refused.") }
    store(key)
    progress(1)
  }

  func putEmptyObject(profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String) {
    uploads.append((key, nil))
    store(key)
  }

  func copyObject(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, sourceKey: String,
    sourceVersionID: String?, size: Int64, destinationKey: String, headers: ObjectHeaders?
  ) throws {
    copies.append(
      Copy(source: sourceKey, versionID: sourceVersionID, destination: destinationKey, headers: headers))
    if sourceKey.hasSuffix("bad.txt") { throw S3Failure(category: .service, message: "Copy refused.") }
    store(destinationKey)
  }

  func deleteObjects(profile: ConnectionProfile, credentials: S3Credentials, bucket: String, keys: [String])
    -> [DeleteFailure]
  {
    deletes.append(keys)
    let refused = keys.filter { $0.hasSuffix("locked.txt") }
    self.keys?.removeAll { key in keys.contains(key) && !refused.contains(key) }
    return refused.map { DeleteFailure(key: $0, message: "Access denied.") }
  }

  func putObjectTags(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String,
    tags: [String: String]
  ) {}

  private func store(_ key: String) {
    if keys?.contains(key) == false { keys?.append(key) }
  }
}

actor MemoryCredentialStore: CredentialStore {
  private(set) var values: [UUID: S3Credentials] = [:]
  private(set) var loadCount = 0

  func save(_ credentials: S3Credentials, reference: UUID) {
    values[reference] = credentials
  }

  func load(reference: UUID) throws -> S3Credentials {
    loadCount += 1
    guard let credentials = values[reference] else { throw CredentialStoreError.notFound }
    return credentials
  }

  func delete(reference: UUID) {
    values.removeValue(forKey: reference)
  }
}

@MainActor
final class Recorder<Value> {
  var values: [Value] = []
}

/// A fresh directory URL under the temporary directory; not created.
func scratchDirectory() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("openbucket-tests-\(UUID().uuidString)", isDirectory: true)
}

func garageProfile(
  _ name: String = "Garage", bucket: String? = nil, source: CredentialSource = .keychain
) throws -> ConnectionProfile {
  ConnectionProfile(
    name: name, endpoint: try S3Endpoint("http://127.0.0.1:23900"), region: "garage",
    addressingStyle: .path, knownBucket: bucket, credentialSource: source)
}

/// An empty, uniquely named defaults suite, so tests never touch the app's real defaults.
func scratchDefaults() -> UserDefaults {
  UserDefaults(suiteName: "openbucket-tests-\(UUID().uuidString)")!
}

let testCredentials = S3Credentials(accessKeyID: "test", secretAccessKey: "test")

@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
  var attempts = 0
  while !condition() {
    attempts += 1
    try #require(attempts < 400, "Timed out waiting for the model")
    try await Task.sleep(for: .milliseconds(5))
  }
}
