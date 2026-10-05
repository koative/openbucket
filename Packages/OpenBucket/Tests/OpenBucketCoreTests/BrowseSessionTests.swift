import Foundation
import Testing

@testable import OpenBucketCore

/// Holds every listing request until the test answers it, so no test depends on scheduling.
private actor ScriptedRepository: S3Repository {
  private var pending: [(bucket: String, token: String?, reply: CheckedContinuation<ObjectPage, Error>)] = []
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private(set) var accessKeys: [String] = []

  func listBuckets(profile: ConnectionProfile, credentials: S3Credentials) async throws -> [String] { [] }

  func listObjects(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    prefix: String,
    continuationToken: String?
  ) async throws -> ObjectPage {
    accessKeys.append(credentials.accessKeyID)
    return try await withCheckedThrowingContinuation {
      pending.append((bucket, continuationToken, $0))
      for waiter in waiters { waiter.resume() }
      waiters = []
    }
  }

  func listAllObjects(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, prefix: String,
    continuationToken: String?
  ) async throws -> ObjectPage { ObjectPage(prefixes: [], objects: [], nextToken: nil) }

  func listObjectVersions(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, prefix: String,
    delimiter: String?, keyMarker: String?, versionIDMarker: String?
  ) async throws -> VersionPage {
    VersionPage(prefixes: [], versions: [], nextKeyMarker: nil, nextVersionIDMarker: nil)
  }

  func objectDetails(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String, versionID: String?
  ) async throws -> ObjectDetails { ObjectDetails() }

  func readObjectBytes(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String, range: Range<Int64>
  ) async throws -> Data { Data() }

  func presignedURL(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String, versionID: String?,
    expiresIn: Duration, downloadFileName: String?
  ) async throws -> URL { URL(string: "https://example.com")! }

  func resolveAWSProfile(_ name: String) async throws -> S3Credentials {
    S3Credentials(accessKeyID: "test", secretAccessKey: "test")
  }

  func downloadObject(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    key: String,
    versionID: String?,
    to destination: URL,
    maximumBytes: Int64,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {}

  private var unsupported: S3Failure { S3Failure(category: .unsupportedOperation, message: "Not scripted") }

  func bucketVersioning(profile: ConnectionProfile, credentials: S3Credentials, bucket: String)
    async throws -> BucketVersioning
  { throw unsupported }

  func uploadFile(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String, from source: URL,
    headers: ObjectHeaders, progress: @escaping @Sendable (Int64) -> Void
  ) async throws { throw unsupported }

  func putEmptyObject(profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String)
    async throws
  { throw unsupported }

  func copyObject(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, sourceKey: String,
    sourceVersionID: String?, size: Int64, destinationKey: String, headers: ObjectHeaders?
  ) async throws { throw unsupported }

  func deleteObjects(profile: ConnectionProfile, credentials: S3Credentials, bucket: String, keys: [String])
    async throws -> [DeleteFailure]
  { throw unsupported }

  func putObjectTags(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String,
    tags: [String: String]
  ) async throws { throw unsupported }

  /// Waits for the next request to `bucket`, answers it with `page`, and returns its continuation token.
  @discardableResult
  func reply(_ page: ObjectPage, bucket: String = "fast") async -> String? {
    while !pending.contains(where: { $0.bucket == bucket }) {
      await withCheckedContinuation { waiters.append($0) }
    }
    let request = pending.remove(at: pending.firstIndex { $0.bucket == bucket }!)
    request.reply.resume(returning: page)
    return request.token
  }
}

private func page(_ keys: [String], prefixes: [String] = [], next: String? = nil) -> ObjectPage {
  ObjectPage(
    prefixes: prefixes,
    objects: keys.map { .init(key: $0, size: 1, lastModified: nil, eTag: nil) },
    nextToken: next
  )
}

@MainActor private func makeSession(_ bucket: String = "fast") throws -> (BrowseSession, ScriptedRepository) {
  let repository = ScriptedRepository()
  let session = BrowseSession(repository: repository)
  try open(bucket, in: session)
  return (session, repository)
}

@MainActor private func open(_ bucket: String, in session: BrowseSession) throws {
  let profile = ConnectionProfile(
    name: "Local", endpoint: try S3Endpoint("http://127.0.0.1:23900"), region: "garage",
    addressingStyle: .path)
  session.navigate(
    profile: profile, credentials: S3Credentials(accessKeyID: "test", secretAccessKey: "test"),
    to: try S3Location(bucket: bucket))
}

@Test @MainActor func navigationDiscardsAStaleResponse() async throws {
  let (session, repository) = try makeSession("slow")
  let stale = session.activeTask
  try open("fast", in: session)

  await repository.reply(page(["one"], next: "second"))
  await session.activeTask?.value
  await repository.reply(page(["stale"], next: "stale-token"), bucket: "slow")
  await stale?.value

  #expect(session.location?.bucket == "fast")
  #expect(session.objects.map(\.key) == ["one"])
  #expect(session.nextToken == "second")
}

@Test @MainActor func navigationKeepsCurrentRowsUntilNextFolderLoads() async throws {
  let (session, repository) = try makeSession()
  await repository.reply(page(["one"]))
  await session.activeTask?.value

  try open("slow", in: session)
  #expect(session.isLoading)
  #expect(session.location?.bucket == "fast")
  #expect(session.objects.map(\.key) == ["one"])

  await repository.reply(page(["two"]), bucket: "slow")
  await session.activeTask?.value
  #expect(session.location?.bucket == "slow")
  #expect(session.objects.map(\.key) == ["two"])
}

@Test @MainActor func loadNextPageAppendsOnceWithoutArguments() async throws {
  let (session, repository) = try makeSession()
  await repository.reply(page(["one"], prefixes: ["folder/"], next: "second"))
  await session.activeTask?.value

  session.loadNextPage()
  let token = await repository.reply(page(["one", "two"], prefixes: ["folder/"]))
  await session.activeTask?.value

  #expect(token == "second")
  #expect(session.objects.map(\.key) == ["one", "two"])
  #expect(session.prefixes == ["folder/"])
  #expect(session.nextToken == nil)
  session.loadNextPage()
  #expect(!session.isLoading)
}

@Test @MainActor func loadNextPageUsesUpdatedCredentials() async throws {
  let (session, repository) = try makeSession()
  await repository.reply(page(["one"], next: "second"))
  await session.activeTask?.value

  session.updateCredentials(S3Credentials(accessKeyID: "fresh", secretAccessKey: "fresh"))
  session.loadNextPage()
  await repository.reply(page(["two"]))
  await session.activeTask?.value

  #expect(await repository.accessKeys == ["test", "fresh"])
  #expect(session.objects.map(\.key) == ["one", "two"])
}

@Test @MainActor func skipsEmptyContinuationPageBeforeShowingEmptyState() async throws {
  let (session, repository) = try makeSession()
  await repository.reply(page([], next: "after-empty"))
  await repository.reply(page(["visible"]))
  await session.activeTask?.value

  #expect(session.objects.map(\.key) == ["visible"])
  #expect(session.nextToken == nil)
  #expect(session.failure == nil)
}

@Test @MainActor func emptyPageCapHandsTheTokenBackInsteadOfFailing() async throws {
  let (session, repository) = try makeSession()
  for index in 1...16 { await repository.reply(page([], next: "t\(index)")) }
  await session.activeTask?.value

  #expect(!session.isLoading)
  #expect(session.failure == nil)
  #expect(session.location?.bucket == "fast")
  #expect(session.nextToken == "t16")

  session.loadNextPage()
  #expect(await repository.reply(page(["late"])) == "t16")
  await session.activeTask?.value
  #expect(session.objects.map(\.key) == ["late"])
}

@Test @MainActor func tokenCycleAcrossPagesStops() async throws {
  let (session, repository) = try makeSession()
  await repository.reply(page(["a"], next: "A"))
  await session.activeTask?.value
  session.loadNextPage()
  await repository.reply(page(["b"], next: "B"))
  await session.activeTask?.value
  session.loadNextPage()
  await repository.reply(page(["c"], next: "A"))
  await session.activeTask?.value

  #expect(session.objects.map(\.key) == ["a", "b", "c"])
  #expect(session.nextToken == nil)
}
