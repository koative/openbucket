import Foundation
import OpenBucketCore
import Testing

@testable import OpenBucket

private func source() throws -> AppModel.DownloadSource {
  AppModel.DownloadSource(
    profile: try garageProfile(), bucket: "test-bucket", credentials: testCredentials)
}

private func file(_ key: String) -> BrowserRow {
  BrowserRow(
    object: ObjectSummary(key: key, size: 1, lastModified: nil, eTag: nil),
    parentPrefix: ObjectChanges.parentPrefix(of: key))
}

private func folder(_ key: String) -> BrowserRow {
  BrowserRow(prefix: key, parentPrefix: ObjectChanges.parentPrefix(of: key))
}

private func bytes(_ keys: [String]) -> Set<[UInt8]> {
  Set(keys.map { Array($0.utf8) })
}

@Test func uploadItemsRecurseSkippingHiddenFilesAndSymlinksAndMarkEmptyFolders() throws {
  let root = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let photos = root.appendingPathComponent("photos")
  let manager = FileManager.default
  try manager.createDirectory(at: photos.appendingPathComponent("sub"), withIntermediateDirectories: true)
  try manager.createDirectory(at: photos.appendingPathComponent("empty"), withIntermediateDirectories: true)
  try manager.createDirectory(
    at: photos.appendingPathComponent("hidden only"), withIntermediateDirectories: true)
  try Data("abc".utf8).write(to: photos.appendingPathComponent("a.jpg"))
  try Data().write(to: photos.appendingPathComponent(".DS_Store"))
  try Data().write(to: photos.appendingPathComponent("hidden only/.secret"))
  try Data("b".utf8).write(to: photos.appendingPathComponent("sub/b.txt"))
  try manager.createSymbolicLink(
    at: photos.appendingPathComponent("link"), withDestinationURL: photos.appendingPathComponent("a.jpg"))

  let items = try ObjectChanges.uploadItems(for: photos, into: "dest/")

  #expect(
    items.map(\.key) == [
      "dest/photos/a.jpg", "dest/photos/empty/", "dest/photos/hidden only/", "dest/photos/sub/b.txt",
    ])
  #expect(items.map(\.size) == [3, 0, 0, 1])
  #expect(items[1].source == nil)
  // A single file keeps its name; a dropped symlink means its target.
  #expect(
    try ObjectChanges.uploadItems(for: photos.appendingPathComponent("link"), into: "").map(\.key) == ["link"]
  )
}

@Test func contentTypeComesFromTheExtension() {
  #expect(ObjectChanges.contentType(forKey: "a/photo.JPG") == "image/jpeg")
  #expect(ObjectChanges.contentType(forKey: "a/blob.zzzz") == "application/octet-stream")
  #expect(ObjectChanges.contentType(forKey: "a/noext") == "application/octet-stream")
}

@Test func keepBothPicksTheFirstFreeNumberCaseSensitively() {
  let taken = bytes(["d/a.txt", "d/a 2.txt", "d/A 3.txt", "d/noext"])
  #expect(ObjectChanges.keepBothKey("d/a.txt", taken: taken) == "d/a 3.txt")
  #expect(ObjectChanges.keepBothKey("d/noext", taken: taken) == "d/noext 2")
  #expect(ObjectChanges.keepBothKey("a.tar.gz", taken: []) == "a.tar 2.gz")
  #expect(ObjectChanges.keepBothKey("d/.env", taken: []) == "d/.env 2")
  // Listing the stem covers every Keep Both candidate.
  #expect(ObjectChanges.listingPrefix(forKey: "d/a.txt") == "d/a")
  #expect(ObjectChanges.listingPrefix(forKey: "d/photos/") == "d/photos/")
}

@MainActor
@Test func conflictsAskWithRemainingCountAndApplyToAll() async {
  let keys = ["d/a.txt", "d/b.txt", "d/c.txt", "d/new.txt", "d/sub/"]
  let existing = bytes(["d/a.txt", "d/a 2.txt", "d/b.txt", "d/c.txt", "d/sub/"])
  let asked = Recorder<String>()
  let answers: [ConflictAnswer] = [(.keepBoth, false), (.skip, true)]

  let resolved = await ObjectChanges.resolveConflicts(keys, existing: existing) { key, remaining in
    asked.values.append("\(key) \(remaining)")
    return answers[asked.values.count - 1]
  }

  #expect(asked.values == ["d/a.txt 2", "d/b.txt 1"])  // c.txt follows "apply to all"; folders merge
  #expect(resolved == ["d/a 3.txt", nil, nil, "d/new.txt", "d/sub/"])

  let cancelled = await ObjectChanges.resolveConflicts(keys, existing: existing) { _, _ in nil }
  #expect(cancelled == nil)
}

@Test func moveMapsKeysBelowTheDestinationAndRefusesFolderIntoItself() {
  let objects = ["a/b/", "a/b/x.txt", "a/b/c/y.txt"].map {
    ObjectSummary(key: $0, size: 1, lastModified: nil, eTag: nil)
  }
  #expect(
    ObjectChanges.copyItems(objects, from: "a/", to: "z/").map(\.destinationKey) == [
      "z/b/", "z/b/x.txt", "z/b/c/y.txt",
    ])
  // Renaming a folder rebases from the folder itself.
  #expect(
    ObjectChanges.copyItems(objects, from: "a/b/", to: "a/new/").map(\.destinationKey).last == "a/new/c/y.txt"
  )
  // Objects that would stay put are left out, so their sources are never deleted.
  #expect(ObjectChanges.copyItems(objects, from: "a/", to: "a/").isEmpty)

  let rows = [folder("a/b/"), file("a/x.txt")]
  #expect(ObjectChanges.moveProblem(rows, to: "a/b/c/") == "“b” can't be moved into itself.")
  #expect(ObjectChanges.moveProblem(rows, to: "a/b/") == "“b” can't be moved into itself.")
  #expect(ObjectChanges.moveProblem(rows, to: "a/") == "These items are already in that folder.")
  #expect(ObjectChanges.moveProblem(rows, to: "a/bb/") == nil)
  #expect(ObjectChanges.moveProblem(rows, to: "") == nil)
}

@Test func namesRejectSlashesBlanksAndDots() {
  #expect(ObjectChanges.nameProblem("photos 2026") == nil)
  #expect(ObjectChanges.nameProblem("  ") == "Enter a name.")
  #expect(ObjectChanges.nameProblem("a/b") == "Names can't contain “/”.")
  #expect(ObjectChanges.nameProblem("..") != nil)
}

@MainActor
@Test func uploadPlanListsTheDestinationAndAppliesAnswers() async throws {
  let root = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(
    at: root.appendingPathComponent("photos"), withIntermediateDirectories: true)
  try Data().write(to: root.appendingPathComponent("photos/a.jpg"))
  try Data().write(to: root.appendingPathComponent("photos/bad.txt"))
  try Data().write(to: root.appendingPathComponent("notes.txt"))
  let repository = StubRepository(keys: ["dest/photos/a.jpg", "dest/notes.txt", "dest/notes 2.txt"])
  let changes = ObjectChanges(repository: repository, source: try source())

  let plan = try await changes.uploadPlan(
    [root.appendingPathComponent("photos"), root.appendingPathComponent("notes.txt")], into: "dest/"
  ) { key, _ in (choice: key.hasSuffix("a.jpg") ? .replace : .keepBoth, applyToAll: false) }
  let items = try #require(plan)
  #expect(items.map(\.key) == ["dest/photos/a.jpg", "dest/photos/bad.txt", "dest/notes 3.txt"])

  let result = await changes.upload(items) { _ in }
  #expect(result == ChangeResult(done: 2, failedKeys: ["dest/photos/bad.txt"], cancelled: false))
  #expect(await repository.uploads.map(\.contentType) == ["image/jpeg", "text/plain", "text/plain"])
}

@MainActor
@Test func moveCopiesThenDeletesAndKeepsSourcesWhoseCopyFailed() async throws {
  let repository = StubRepository(keys: ["a/b/x.txt", "a/b/bad.txt", "z/b/x.txt"])
  let changes = ObjectChanges(repository: repository, source: try source())

  let plan = try await changes.movePlan([folder("a/b/")], to: "z/") { _, _ in (.keepBoth, false) }
  let items = try #require(plan)
  let result = await changes.copy(items, deletingSources: true) { _ in }

  #expect(result.failedKeys == ["a/b/bad.txt"])
  #expect(await repository.keys?.sorted() == ["a/b/bad.txt", "z/b/x 2.txt", "z/b/x.txt"])
}

@MainActor
@Test func renameRefusesTakenNames() async throws {
  let repository = StubRepository(keys: ["a/x.txt", "a/y.txt", "a/f/1.txt", "a/g/2.txt"])
  let changes = ObjectChanges(repository: repository, source: try source())

  #expect(try await changes.renamePlan(file("a/x.txt"), to: "a/y.txt") == nil)
  #expect(try await changes.renamePlan(folder("a/f/"), to: "a/g/") == nil)
  #expect(
    try await changes.renamePlan(folder("a/f/"), to: "a/h/")
      == [CopyItem(sourceKey: "a/f/1.txt", size: 1, destinationKey: "a/h/1.txt")])
  // Keys that merely start with the new name ("a/x.txt" for "a/x") don't count as taken.
  #expect(try await changes.renamePlan(file("a/y.txt"), to: "a/x") != nil)
}

@MainActor
@Test func deleteListsFoldersAndBatchesRequests() async throws {
  let keys = (0..<1001).map { "a/f/\($0).txt" } + ["a/f/locked.txt"]
  let repository = StubRepository(keys: keys)
  let changes = ObjectChanges(repository: repository, source: try source())

  let objects = try await changes.objects(in: folder("a/f/"))
  let result = await changes.delete(objects) { _ in }

  #expect(await repository.deletes.map(\.count) == [1000, 2])
  #expect(result == ChangeResult(done: 1001, failedKeys: ["a/f/locked.txt"], cancelled: false))
}

@MainActor
@Test func cancellingDuringAConflictPromptStopsTheUpload() async throws {
  let directory = scratchDirectory()
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let local = directory.appendingPathComponent("first.txt")
  try Data("x".utf8).write(to: local)
  let repository = StubRepository(keys: ["first.txt"])
  let credentials = MemoryCredentialStore()
  let model = AppModel(
    repository: repository,
    profileStore: ProfileStore(fileURL: directory.appendingPathComponent("profiles.json")),
    credentialStore: credentials, defaults: scratchDefaults())
  await model.loadProfiles()
  var profile = try garageProfile(bucket: "test-bucket")
  profile.allowsChanges = true
  try await model.save(profile, credentials: testCredentials)
  try await waitUntil { model.downloadSource() != nil && !model.isConnecting }
  let browser = BrowserController(model: model)
  let location = try #require(model.browser.location)

  browser.upload([local], into: location)
  try await waitUntil { browser.conflict != nil }
  #expect(browser.conflict?.name == "first.txt")
  browser.cancelTransfer()
  try await waitUntil { !browser.isTransferring }

  #expect(browser.transfer == nil && browser.conflict == nil)
  #expect(await repository.uploads.isEmpty)

  browser.upload([local], into: location)
  try await waitUntil { browser.conflict != nil }
  browser.resolveConflict(.replace, applyToAll: false)
  try await waitUntil { !browser.isTransferring }
  #expect(await repository.uploads.map(\.key) == ["first.txt"])
  #expect(browser.changeGeneration == 1)
}

@MainActor
@Test func droppingItemsOnAnotherFolderMovesThemAndOnTheirOwnFolderDoesNothing() async throws {
  let directory = scratchDirectory()
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = StubRepository(keys: ["first.txt"])
  let model = AppModel(
    repository: repository,
    profileStore: ProfileStore(fileURL: directory.appendingPathComponent("profiles.json")),
    credentialStore: MemoryCredentialStore(), defaults: scratchDefaults())
  await model.loadProfiles()
  var profile = try garageProfile(bucket: "test-bucket")
  profile.allowsChanges = true
  try await model.save(profile, credentials: testCredentials)
  try await waitUntil { model.downloadSource() != nil && !model.isConnecting }
  let browser = BrowserController(model: model)
  let location = try #require(model.browser.location)
  let first = S3ItemReference(
    profileID: profile.id, bucket: "test-bucket", isFolder: false, key: Array("first.txt".utf8))
  let elsewhere = S3ItemReference(profileID: UUID(), bucket: "test-bucket", isFolder: false, key: first.key)
  let folder = try S3Location(bucket: "test-bucket", prefix: "archive/")

  #expect(!browser.accept([.item(first)], into: location))
  #expect(!browser.accept([.item(elsewhere)], into: folder))
  #expect(await repository.copies.isEmpty)

  #expect(browser.accept([.item(first)], into: folder))
  try await waitUntil { browser.changeGeneration == 1 }
  #expect(await repository.copies.map(\.destination) == ["archive/first.txt"])
  #expect(await repository.deletes == [["first.txt"]])
}
