import Foundation
import OpenBucketCore
import Testing
import os

@testable import OpenBucketS3

@Test(.enabled(if: ProcessInfo.processInfo.environment["OPENBUCKET_TEST_ENDPOINT"] != nil))
func listsKnownBucketAndNestedPrefix() async throws {
  let environment = ProcessInfo.processInfo.environment
  let endpoint = try #require(environment["OPENBUCKET_TEST_ENDPOINT"])
  let region = try #require(environment["OPENBUCKET_TEST_REGION"])
  let bucket = try #require(environment["OPENBUCKET_TEST_BUCKET"])
  let accessKey = try #require(environment["OPENBUCKET_TEST_ACCESS_KEY"])
  let secretKey = try #require(environment["OPENBUCKET_TEST_SECRET_KEY"])
  let prefix = try #require(environment["OPENBUCKET_TEST_PREFIX"])
  let expectedKey = try #require(environment["OPENBUCKET_TEST_EXPECT_KEY"])
  let profile = ConnectionProfile(
    name: "Integration S3",
    endpoint: try S3Endpoint(endpoint),
    region: region,
    addressingStyle: .path,
    knownBucket: bucket
  )
  let credentials = S3Credentials(accessKeyID: accessKey, secretAccessKey: secretKey)
  let repository = SotoS3Repository()

  let root = try await repository.listObjects(
    profile: profile,
    credentials: credentials,
    bucket: bucket,
    prefix: "",
    continuationToken: nil
  )
  let firstPrefix = String(prefix.split(separator: "/").first ?? "") + "/"
  #expect(root.prefixes.contains(firstPrefix))

  let nested = try await repository.listObjects(
    profile: profile,
    credentials: credentials,
    bucket: bucket,
    prefix: prefix,
    continuationToken: nil
  )
  #expect(nested.objects.contains { $0.key == expectedKey })

  let file = FileManager.default.temporaryDirectory.appendingPathComponent(
    "openbucket-test-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: file) }
  try await repository.downloadObject(
    profile: profile,
    credentials: credentials,
    bucket: bucket,
    key: expectedKey,
    versionID: nil,
    to: file,
    maximumBytes: 8 * 1024 * 1024,
    progress: { _ in }
  )
  let data = try Data(contentsOf: file)
  #expect(!data.isEmpty)
}

/// Writes under a disposable `integration-writes/<uuid>/` prefix and deletes it afterwards. Run with
/// OPENBUCKET_TEST_WRITES=1, the endpoint/region/bucket/key variables above, and `--filter writeRoundTrip`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["OPENBUCKET_TEST_WRITES"] == "1"))
func writeRoundTrip() async throws {
  let environment = ProcessInfo.processInfo.environment
  let bucket = try #require(environment["OPENBUCKET_TEST_BUCKET"])
  let profile = ConnectionProfile(
    name: "Integration S3", endpoint: try S3Endpoint(try #require(environment["OPENBUCKET_TEST_ENDPOINT"])),
    region: try #require(environment["OPENBUCKET_TEST_REGION"]), addressingStyle: .path, knownBucket: bucket,
    allowsChanges: true)
  let credentials = S3Credentials(
    accessKeyID: try #require(environment["OPENBUCKET_TEST_ACCESS_KEY"]),
    secretAccessKey: try #require(environment["OPENBUCKET_TEST_SECRET_KEY"]))
  let repository = SotoS3Repository()
  let prefix = "integration-writes/\(UUID().uuidString)/"
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "openbucket-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  func details(_ key: String) async throws -> ObjectDetails {
    try await repository.objectDetails(
      profile: profile, credentials: credentials, bucket: bucket, key: prefix + key, versionID: nil)
  }
  func upload(_ name: String, _ data: Data, headers: ObjectHeaders) async throws -> Int64 {
    let file = directory.appendingPathComponent(name)
    try data.write(to: file)
    let sent = OSAllocatedUnfairLock(initialState: Int64(0))
    try await repository.uploadFile(
      profile: profile, credentials: credentials, bucket: bucket, key: prefix + name, from: file,
      headers: headers
    ) { bytes in sent.withLock { $0 = bytes } }
    return sent.withLock { $0 }
  }

  func run() async throws {
    let small = Data("hello".utf8)
    let smallHeaders = ObjectHeaders(contentType: "text/plain", metadata: ["owner": "rael"])
    #expect(try await upload("small.txt", small, headers: smallHeaders) == 5)
    #expect(ObjectHeaders(try await details("small.txt")) == smallHeaders)

    // 17 MiB of varying bytes: one full 16 MiB part plus a short one, checked byte for byte.
    let big = Data((0..<(17 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 13) })
    #expect(try await upload("big.bin", big, headers: ObjectHeaders()) == Int64(big.count))
    let downloaded = directory.appendingPathComponent("big.download")
    try await repository.downloadObject(
      profile: profile, credentials: credentials, bucket: bucket, key: prefix + "big.bin", versionID: nil,
      to: downloaded, maximumBytes: .max, progress: { _ in })
    #expect(try Data(contentsOf: downloaded) == big)

    try await repository.putEmptyObject(
      profile: profile, credentials: credentials, bucket: bucket, key: prefix + "folder/")
    let listing = try await repository.listObjects(
      profile: profile, credentials: credentials, bucket: bucket, prefix: prefix, continuationToken: nil)
    #expect(listing.prefixes.contains(prefix + "folder/"))

    try await repository.copyObject(
      profile: profile, credentials: credentials, bucket: bucket, sourceKey: prefix + "small.txt",
      sourceVersionID: nil, size: 5, destinationKey: prefix + "copy of small.txt", headers: nil)
    #expect(ObjectHeaders(try await details("copy of small.txt")) == smallHeaders)

    let replaced = ObjectHeaders(
      contentType: "text/markdown", cacheControl: "no-cache", metadata: ["owner": "bob"])
    try await repository.copyObject(
      profile: profile, credentials: credentials, bucket: bucket, sourceKey: prefix + "copy of small.txt",
      sourceVersionID: nil, size: 5, destinationKey: prefix + "copy of small.txt", headers: replaced)
    // S3Mock keeps the old Content-Type on a REPLACE copy, so only the other headers are compared.
    let afterReplace = try await details("copy of small.txt")
    #expect(afterReplace.metadata == replaced.metadata && afterReplace.cacheControl == replaced.cacheControl)

    // Tagging is optional on S3-compatible services; only check it where it's supported.
    if (try? await repository.putObjectTags(
      profile: profile, credentials: credentials, bucket: bucket, key: prefix + "small.txt",
      tags: ["team": "a&b"]))
      != nil
    {
      #expect(try await details("small.txt").tags == ["team": "a&b"])
    }

    let versioning = try await repository.bucketVersioning(
      profile: profile, credentials: credentials, bucket: bucket)
    let failures = try await repository.deleteObjects(
      profile: profile, credentials: credentials, bucket: bucket, keys: [prefix + "small.txt"])
    #expect(failures.isEmpty)
    await #expect(throws: S3Failure.self) { try await details("small.txt") }

    guard versioning == .enabled else { return }
    let versions = try await repository.listObjectVersions(
      profile: profile, credentials: credentials, bucket: bucket, prefix: prefix + "small.txt",
      delimiter: nil,
      keyMarker: nil, versionIDMarker: nil)
    let original = try #require(versions.versions.first { !$0.isDeleteMarker })
    // Only the accepted copy is checked: S3Mock rewrites the source version in place instead of adding a new
    // current version, so its HEAD still finds the delete marker.
    try await repository.copyObject(
      profile: profile, credentials: credentials, bucket: bucket, sourceKey: original.key,
      sourceVersionID: original.versionID, size: original.size, destinationKey: original.key, headers: nil)
  }

  var failure: (any Error)?
  do { try await run() } catch { failure = error }
  let leftovers = try await repository.listAllObjects(
    profile: profile, credentials: credentials, bucket: bucket, prefix: prefix, continuationToken: nil)
  let undeleted = try await repository.deleteObjects(
    profile: profile, credentials: credentials, bucket: bucket, keys: leftovers.objects.map(\.key))
  #expect(undeleted.isEmpty)
  if let failure { throw failure }
}
