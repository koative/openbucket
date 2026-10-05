import Foundation
import OpenBucketCore
import Testing
import os

@testable import OpenBucket

private typealias Entry = BackupVerification.Entry

private func entry(
  _ path: String, _ status: BackupVerification.Status, local: Int64? = 1, remote: Int64? = 1,
  key: String? = nil
) -> Entry {
  Entry(
    relativePath: path, status: status, localSize: status == .onlyInS3 ? nil : local,
    remoteSize: status == .missingInS3 ? nil : remote,
    remoteKey: status == .missingInS3 ? nil : key ?? "backup/" + path)
}

private let location = try! S3Location(bucket: "test-bucket", prefix: "backup/")

private func source(allowsChanges: Bool) throws -> AppModel.DownloadSource {
  var profile = try garageProfile()
  profile.allowsChanges = allowsChanges
  return AppModel.DownloadSource(profile: profile, bucket: "test-bucket", credentials: testCredentials)
}

private func write(_ text: String, to path: String, in folder: URL) throws {
  let url = folder.appending(path: path)
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(text.utf8).write(to: url)
}

private func read(_ path: String, in folder: URL) throws -> String {
  try String(contentsOf: folder.appending(path: path), encoding: .utf8)
}

/// Moves trashed items into `folder` instead of the user's Trash.
private func trash(into folder: URL) -> @Sendable (URL) throws -> Void {
  { url in
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: url, to: folder.appending(path: url.lastPathComponent))
  }
}

// MARK: - Planning

@Test func syncPlansCopyNewAndChangedFilesTowardTheTarget() {
  let entries = [
    entry("same.txt", .identical), entry("changed.txt", .different, local: 5, remote: 5),
    entry("short.txt", .sizeMismatch, local: 2, remote: 3), entry("local.txt", .missingInS3, local: 4),
    entry("remote.txt", .onlyInS3, remote: 7), entry("odd.bin", .unverified),
    entry("locked.txt", .unreadable),
  ]
  let folder = URL(filePath: "/tmp/backup", directoryHint: .isDirectory)

  let toS3 = FolderSync.plan(.toS3, entries: entries, location: location, localFolder: folder)
  #expect(toS3.items.map(\.relativePath) == ["changed.txt", "short.txt", "local.txt"])
  #expect(toS3.items.map(\.replaces) == [true, true, false])
  #expect(toS3.items.map(\.size) == [5, 2, 4])
  #expect((toS3.newFiles, toS3.changedFiles, toS3.targetOnly) == (1, 2, 1))
  #expect(toS3.leftAlone == [.identical: 1, .unverified: 1, .unreadable: 1])

  let toMac = FolderSync.plan(.toMac, entries: entries, location: location, localFolder: folder)
  #expect(toMac.items.map(\.relativePath) == ["changed.txt", "short.txt", "remote.txt"])
  #expect(toMac.items.map(\.size) == [5, 3, 7])
  #expect((toMac.newFiles, toMac.changedFiles, toMac.targetOnly) == (1, 2, 1))
  #expect(toMac.leftAlone == [.identical: 1, .unverified: 1, .unreadable: 1])
}

@Test func syncMapsKeysExactlyAndKeepsLocalPathsInsideTheFolder() {
  let folder = URL(filePath: "/tmp/backup", directoryHint: .isDirectory)
  // An existing object keeps its exact key (here NFD), even though the comparison path is NFC.
  let existing = FolderSync.key(
    for: entry("caf\u{E9}.txt", .different, key: "backup/cafe\u{301}.txt"), under: "backup/")
  #expect(existing.unicodeScalars.elementsEqual("backup/cafe\u{301}.txt".unicodeScalars))
  #expect(FolderSync.key(for: entry("a/b/new.txt", .missingInS3), under: "backup/") == "backup/a/b/new.txt")

  #expect(FolderSync.localURL(for: "a/b/c.txt", in: folder)?.path == "/tmp/backup/a/b/c.txt")
  let colon = FolderSync.localURL(for: "with:colon and space.txt", in: folder)
  #expect(colon?.lastPathComponent == "with:colon and space.txt")
  for escaping in ["../x.txt", "a/../../x.txt", "a//b.txt", "/abs.txt", "./x.txt", "a/."] {
    #expect(FolderSync.localURL(for: escaping, in: folder) == nil, "\(escaping)")
  }
}

// MARK: - Running

@MainActor
@Test func updateMacTrashesEachReplacedFileAndDeletesNothing() async throws {
  let root = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appending(path: "local")
  let trashed = root.appending(path: "trash")
  try write("old", to: "changed.txt", in: folder)
  try write("same", to: "same.txt", in: folder)
  try write("mine", to: "local-only.txt", in: folder)
  let repository = StubRepository()
  let plan = FolderSync.plan(
    .toMac,
    entries: [
      entry("changed.txt", .different), entry("nested/deep/new.txt", .onlyInS3),
      entry("same.txt", .identical), entry("local-only.txt", .missingInS3), entry("../escape.txt", .onlyInS3),
    ],
    location: location, localFolder: folder)

  // Read-only connections can still update the Mac.
  let sync = FolderSync(
    plan: plan, repository: repository, source: try source(allowsChanges: false), trash: trash(into: trashed))
  sync.start()
  await sync.task?.value

  #expect(try read("changed.txt", in: folder) == "backup/changed.txt")
  #expect(try read("changed.txt", in: trashed) == "old")
  #expect(try FileManager.default.contentsOfDirectory(atPath: trashed.path) == ["changed.txt"])
  #expect(try read("nested/deep/new.txt", in: folder) == "backup/nested/deep/new.txt")
  #expect(try read("same.txt", in: folder) == "same")
  #expect(try read("local-only.txt", in: folder) == "mine")
  #expect(!FileManager.default.fileExists(atPath: root.appending(path: "escape.txt").path))
  #expect(Set(await repository.downloads.map(\.key)) == ["backup/changed.txt", "backup/nested/deep/new.txt"])
  #expect(await repository.downloads.allSatisfy { $0.versionID == nil })
  #expect(await repository.deletes.isEmpty)
  #expect(sync.transferredFiles == 2)
  #expect(sync.failedPaths == ["../escape.txt"])
  #expect(!sync.wasCancelled && sync.isFinished && !sync.isRunning)
  #expect(sync.progress.completedFiles == 3)
}

@MainActor
@Test func updateS3UploadsNewAndChangedFilesOnlyWhenChangesAreAllowed() async throws {
  let folder = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: folder) }
  for path in ["changed.txt", "photos/new.jpg", "sub/bad.txt", "same.txt"] {
    try write(path, to: path, in: folder)
  }
  let repository = StubRepository()
  let plan = FolderSync.plan(
    .toS3,
    entries: [
      entry("changed.txt", .different), entry("photos/new.jpg", .missingInS3),
      entry("sub/bad.txt", .missingInS3), entry("same.txt", .identical), entry("remote-only.txt", .onlyInS3),
    ],
    location: location, localFolder: folder)

  let readOnly = FolderSync(plan: plan, repository: repository, source: try source(allowsChanges: false))
  readOnly.start()
  #expect(readOnly.task == nil)

  let sync = FolderSync(plan: plan, repository: repository, source: try source(allowsChanges: true))
  sync.start()
  await sync.task?.value

  let uploads = await repository.uploads
  #expect(Set(uploads.map(\.key)) == ["backup/changed.txt", "backup/photos/new.jpg", "backup/sub/bad.txt"])
  #expect(uploads.first { $0.key == "backup/photos/new.jpg" }?.contentType == "image/jpeg")
  #expect(await repository.deletes.isEmpty)
  #expect(sync.transferredFiles == 2)
  #expect(sync.failedPaths == ["sub/bad.txt"])
}

@MainActor
@Test func cancellingASyncStartsNoFurtherFiles() async throws {
  let root = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appending(path: "local")
  let paths = (1...8).map { "file\($0).txt" }
  for path in paths { try write("old", to: path, in: folder) }
  let repository = StubRepository()
  let plan = FolderSync.plan(
    .toMac, entries: paths.map { entry($0, .different) }, location: location, localFolder: folder)
  // The first file to reach the Trash step cancels the run, while at most four files have started.
  let run = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
  let moveToTrash = trash(into: root.appending(path: "trash"))
  let sync = FolderSync(
    plan: plan, repository: repository, source: try source(allowsChanges: false),
    trash: { url in
      run.withLock { $0?.cancel() }
      try moveToTrash(url)
    })
  sync.start()
  let task = sync.task
  run.withLock { $0 = task }
  await task?.value

  #expect(sync.wasCancelled)
  #expect(sync.failedPaths.isEmpty)
  let started = await repository.downloads.map(\.key)
  #expect(started.count <= 4)
  #expect(Set(started).isSubset(of: paths.prefix(4).map { "backup/" + $0 }))
  #expect(sync.transferredFiles >= 1)
}
