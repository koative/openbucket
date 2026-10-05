import Foundation
import OpenBucketCore
import Testing

@testable import OpenBucket

@MainActor
private func makeModel(
  in directory: URL,
  repository: StubRepository = StubRepository(),
  credentials: MemoryCredentialStore = MemoryCredentialStore(),
  defaults: UserDefaults = scratchDefaults()
) async -> AppModel {
  let model = AppModel(
    repository: repository,
    profileStore: ProfileStore(fileURL: directory.appendingPathComponent("profiles.json")),
    credentialStore: credentials,
    defaults: defaults
  )
  await model.loadProfiles()
  return model
}

@MainActor
@Test func failedProfileEditRestoresPreviousCredentials() async throws {
  let directory = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let credentials = MemoryCredentialStore()
  let model = await makeModel(in: directory, credentials: credentials)
  let original = try garageProfile()
  try await model.save(original, credentials: S3Credentials(accessKeyID: "original", secretAccessKey: "s"))

  let fileURL = directory.appendingPathComponent("profiles.json")
  try FileManager.default.removeItem(at: fileURL)
  try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
  var edited = original
  edited.name = "Garage edited"
  await #expect(throws: (any Error).self) {
    try await model.save(edited, credentials: S3Credentials(accessKeyID: "new", secretAccessKey: "s"))
  }

  #expect(model.profiles == [original])
  #expect(try await credentials.load(reference: original.credentialReference).accessKeyID == "original")
}

@MainActor
@Test func editingKeepsCredentialReferenceAndKeychainItem() async throws {
  let directory = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let credentials = MemoryCredentialStore()
  let model = await makeModel(in: directory, credentials: credentials)
  let profile = try garageProfile()
  try await model.save(profile, credentials: S3Credentials(accessKeyID: "first", secretAccessKey: "s"))

  var edited = profile
  edited.name = "Garage edited"
  try await model.save(edited, credentials: S3Credentials(accessKeyID: "second", secretAccessKey: "s"))

  #expect(model.profiles.map(\.credentialReference) == [profile.credentialReference])
  #expect(await credentials.values.count == 1)
  #expect(try await credentials.load(reference: profile.credentialReference).accessKeyID == "second")
}

@MainActor
@Test func editingConnectionRestoresMissingCredentials() async throws {
  let directory = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let credentials = MemoryCredentialStore()
  let model = await makeModel(in: directory, credentials: credentials)
  let profile = try garageProfile()
  try await model.save(profile, credentials: S3Credentials(accessKeyID: "first", secretAccessKey: "s"))
  await credentials.delete(reference: profile.credentialReference)

  var edited = profile
  edited.name = "Garage restored"
  try await model.save(edited, credentials: S3Credentials(accessKeyID: "restored", secretAccessKey: "s"))

  #expect(model.selectedProfile?.name == "Garage restored")
  #expect(try await credentials.load(reference: profile.credentialReference).accessKeyID == "restored")
}

@MainActor
@Test func deletingAnotherProfileKeepsSelection() async throws {
  let directory = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let credentials = MemoryCredentialStore()
  let model = await makeModel(in: directory, credentials: credentials)
  let alpha = try garageProfile("Alpha")
  let beta = try garageProfile("Beta")
  let gamma = try garageProfile("Gamma")
  for profile in [alpha, beta, gamma] { try await model.save(profile, credentials: testCredentials) }
  #expect(model.selectedProfileID == gamma.id)

  try await model.delete(alpha)

  #expect(model.selectedProfileID == gamma.id)
  #expect(model.profiles == [beta, gamma])
  await #expect(throws: CredentialStoreError.notFound) {
    try await credentials.load(reference: alpha.credentialReference)
  }
}

@MainActor
@Test func unreadableProfilesFileIsKeptBeforeSaving() async throws {
  let directory = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  let garbage = Data("{ not profiles".utf8)
  try garbage.write(to: directory.appendingPathComponent("profiles.json"))

  let model = await makeModel(in: directory)
  #expect(model.connectionFailure?.category == .localFile)
  try await model.save(try garageProfile(), credentials: testCredentials)

  let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    .filter { $0.hasPrefix("profiles.unreadable-") }
  #expect(backups.count == 1)
  let backup = try #require(backups.first)
  #expect(try Data(contentsOf: directory.appendingPathComponent(backup)) == garbage)
}

@MainActor
@Test func profilesFileThatCannotBeReadBlocksSaving() async throws {
  let directory = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let fileURL = directory.appendingPathComponent("profiles.json")
  try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)

  let model = await makeModel(in: directory)
  await #expect(throws: S3Failure.self) {
    try await model.save(try garageProfile(), credentials: testCredentials)
  }

  var isDirectory: ObjCBool = false
  #expect(FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory))
  #expect(isDirectory.boolValue)
}

@MainActor
@Test func credentialsLoadOncePerSelection() async throws {
  let directory = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let profile = try garageProfile(bucket: "bucket")
  try await ProfileStore(fileURL: directory.appendingPathComponent("profiles.json")).save([profile])
  let credentials = MemoryCredentialStore()
  await credentials.save(testCredentials, reference: profile.credentialReference)

  let model = await makeModel(in: directory, credentials: credentials)
  try await waitUntil { model.browser.location != nil && !model.browser.isLoading }
  model.open(try S3Location(bucket: "bucket"))
  try await waitUntil { !model.isConnecting && !model.browser.isLoading }
  model.loadNextPage()
  try await waitUntil { model.browser.nextToken == nil && !model.browser.isLoading }
  let source = try #require(model.downloadSource())
  try await model.download(
    model.browser.objects[0], from: source, to: directory.appendingPathComponent("first.txt"),
    maximumBytes: .max
  ) { _ in }

  #expect(model.browser.objects.map(\.key) == ["first.txt", "second.txt"])
  #expect(await credentials.loadCount == 1)
}

@MainActor
@Test func downloadKeepsSourceWhenSelectionChanges() async throws {
  let directory = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = StubRepository()
  let model = await makeModel(in: directory, repository: repository)
  let first = try garageProfile("First", bucket: "first-bucket")
  try await model.save(first, credentials: testCredentials)
  try await waitUntil { model.browser.location != nil }
  let source = try #require(model.downloadSource())

  try await model.save(try garageProfile("Second", bucket: "second-bucket"), credentials: testCredentials)
  let destination = directory.appendingPathComponent("download.txt")
  let object = ObjectSummary(key: "example.txt", size: 11, lastModified: nil, eTag: nil)
  let progress = Recorder<Int64>()
  try await model.download(object, versionID: "v1", from: source, to: destination, maximumBytes: .max) {
    progress.values.append($0)
  }

  let request = try #require(await repository.downloads.last)
  #expect(request.profileID == first.id)
  #expect(request.bucket == "first-bucket")
  #expect(request.key == object.key)
  #expect(request.versionID == "v1")
  #expect(try String(contentsOf: destination, encoding: .utf8) == "example.txt")
  #expect(progress.values.last == 11)
}

@MainActor
@Test func awsProfileConnectionSkipsKeychain() async throws {
  let directory = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = StubRepository()
  let credentials = MemoryCredentialStore()
  let model = await makeModel(in: directory, repository: repository, credentials: credentials)
  let profile = try garageProfile(bucket: "bucket")
  try await model.save(profile, credentials: testCredentials)
  #expect(await credentials.values.count == 1)

  var switched = profile
  switched.credentialSource = .awsProfile("dev")
  try await model.save(switched, credentials: nil)
  try await waitUntil { !model.isConnecting && model.browser.location != nil }

  #expect(await credentials.values.isEmpty)
  #expect(await repository.resolvedProfiles == ["dev"])
  #expect(model.downloadSource() != nil)
  await #expect(throws: S3Failure.self) {
    try await model.save(profile, credentials: nil)
  }
}

@MainActor
@Test(arguments: [(30.0, 2), (3600.0, 1)])
func expiringCredentialsResolveAgainOnRefresh(expiresIn: TimeInterval, resolutions: Int) async throws {
  let directory = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let profile = try garageProfile(bucket: "bucket", source: .awsProfile("sso"))
  try await ProfileStore(fileURL: directory.appendingPathComponent("profiles.json")).save([profile])
  let repository = StubRepository(credentialLifetime: expiresIn)

  let model = await makeModel(in: directory, repository: repository)
  try await waitUntil { !model.isConnecting && model.browser.location != nil }
  model.refresh()
  try await waitUntil { !model.isConnecting }

  #expect(model.connectionFailure == nil)
  #expect(await repository.resolvedProfiles.count == resolutions)
}

@MainActor
@Test func temporaryCredentialsRefreshBeforeTheyExpire() async throws {
  let directory = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let profile = try garageProfile(bucket: "bucket", source: .awsProfile("sso"))
  try await ProfileStore(fileURL: directory.appendingPathComponent("profiles.json")).save([profile])
  // Each resolution lasts 60.2 s and is refreshed 60 s early, so a refresh follows ~0.2 s later.
  let repository = StubRepository(credentialLifetime: 60.2)

  let model = await makeModel(in: directory, repository: repository)
  try await waitUntil { !model.isConnecting && model.browser.location != nil && !model.browser.isLoading }
  let first = try #require(model.downloadSource()?.credentials.expiration)
  try await waitUntil { model.downloadSource().map { $0.credentials.expiration != first } ?? false }
  model.loadNextPage()
  try await waitUntil { model.browser.nextToken == nil && !model.browser.isLoading }

  let listed = await repository.listedExpirations
  #expect(listed.count == 2)
  #expect(listed.first == first)
  #expect(try #require(listed.last ?? nil) > first)
  #expect(model.connectionFailure == nil)
}

@MainActor
@Test func favoritesPersistOnTheSelectedProfile() async throws {
  let directory = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let model = await makeModel(in: directory)
  try await model.save(try garageProfile(bucket: "bucket"), credentials: testCredentials)
  let photos = try S3Location(bucket: "bucket", prefix: "photos/")
  let docs = try S3Location(bucket: "bucket", prefix: "docs/")

  try await model.toggleFavorite(photos)
  try await model.toggleFavorite(docs)
  try await model.toggleFavorite(photos)

  #expect(model.favorites == [docs])
  #expect(!model.isFavorite(photos))
  let reloaded = await makeModel(in: directory)
  #expect(reloaded.favorites == [docs])
}

@MainActor
@Test func overlappingFavoriteTogglesKeepBoth() async throws {
  let directory = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let model = await makeModel(in: directory)
  try await model.save(try garageProfile(bucket: "bucket"), credentials: testCredentials)
  let photos = try S3Location(bucket: "bucket", prefix: "photos/")
  let docs = try S3Location(bucket: "bucket", prefix: "docs/")

  // The second toggle starts while the first is still saving.
  let first = Task { try await model.toggleFavorite(photos) }
  let second = Task { try await model.toggleFavorite(docs) }
  try await first.value
  try await second.value

  #expect(Set(model.favorites) == [photos, docs])
  let reloaded = await makeModel(in: directory)
  #expect(Set(reloaded.favorites) == [photos, docs])
}

@MainActor
@Test func recentsAreNewestFirstDedupedAndLimited() async throws {
  let directory = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let defaults = scratchDefaults()
  let model = await makeModel(in: directory, defaults: defaults)
  let profile = try garageProfile(bucket: "bucket")
  try await model.save(profile, credentials: testCredentials)
  let locations = try (0..<12).map { try S3Location(bucket: "bucket", prefix: "p\($0)/") }

  for location in locations { model.open(location) }
  model.open(locations[5])

  let expected = [5, 11, 10, 9, 8, 7, 6, 4, 3, 2].map { locations[$0] }
  #expect(model.recents == expected)
  let key = "recents.\(profile.id.uuidString)"
  #expect(defaults.stringArray(forKey: key) == expected.map(\.displayString))
  try await model.delete(profile)
  #expect(defaults.object(forKey: key) == nil)
}

@MainActor
@Test func openLinkPicksProfileAndRevealsObject() async throws {
  let directory = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let model = await makeModel(in: directory)
  #expect(!model.openLink("s3://alpha-bucket/"))
  let alpha = try garageProfile("Alpha", bucket: "alpha-bucket")
  let beta = try garageProfile("Beta", bucket: "beta-bucket")
  try await model.save(alpha, credentials: testCredentials)
  try await model.save(beta, credentials: testCredentials)
  #expect(model.selectedProfileID == beta.id)

  #expect(!model.openLink("not a link"))
  #expect(model.openLink(" s3://alpha-bucket/photos/cat.jpg "))

  #expect(model.selectedProfileID == alpha.id)
  #expect(model.pendingSelectionKey == "photos/cat.jpg")
  let folder = try S3Location(bucket: "alpha-bucket", prefix: "photos/")
  try await waitUntil { !model.isConnecting && model.browser.location == folder }
  #expect(model.consumePendingSelectionKey() == "photos/cat.jpg")
  #expect(model.pendingSelectionKey == nil)

  #expect(model.openLink("s3://unknown-bucket/docs/"))
  #expect(model.selectedProfileID == alpha.id)
  #expect(model.pendingSelectionKey == nil)
  let docs = try S3Location(bucket: "unknown-bucket", prefix: "docs/")
  #expect(model.recents.first == docs)
}

@MainActor
@Test func linkProfilePrefersSelectedThenPinnedConnection() async throws {
  let directory = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let model = await makeModel(in: directory, repository: StubRepository(buckets: ["shared-bucket"]))
  let logs = try garageProfile("Logs", bucket: "acme-logs")
  let any = try garageProfile("Any")
  try await model.save(logs, credentials: testCredentials)
  try await model.save(any, credentials: testCredentials)
  try await waitUntil { !model.isConnecting }

  #expect(model.profile(forBucket: "shared-bucket")?.id == any.id)
  #expect(model.profile(forBucket: "acme-logs")?.id == logs.id)
  #expect(model.profile(forBucket: "elsewhere")?.id == any.id)
  #expect(model.isKnownBucket("acme-logs") && model.isKnownBucket("shared-bucket"))
  #expect(!model.isKnownBucket("elsewhere"))
}

@MainActor
@Test func openingInAnUnpinnedProfileListsItsBuckets() async throws {
  let directory = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let model = await makeModel(in: directory, repository: StubRepository(buckets: ["b", "a"]))
  let any = try garageProfile("Any")
  let pinned = try garageProfile("Pinned", bucket: "pinned")
  try await model.save(any, credentials: testCredentials)
  try await model.save(pinned, credentials: testCredentials)
  try await waitUntil { !model.isConnecting }
  #expect(model.buckets.isEmpty)

  let docs = try S3Location(bucket: "a", prefix: "docs/")
  model.open(docs, inProfile: any.id)
  try await waitUntil { !model.isConnecting && model.browser.location == docs }

  #expect(model.selectedProfileID == any.id)
  #expect(model.buckets == ["a", "b"])
}
