import Foundation
import OpenBucketCore
import Testing

@testable import OpenBucket

@Test func batchNamesRemainUniqueAfterSanitizing() {
  var used = Set<String>()
  let first = BatchDownloadNames.uniqueName(for: "a:report.txt", usedNames: &used)
  let second = BatchDownloadNames.uniqueName(for: "a\\report.txt", usedNames: &used)

  #expect(first == "areport.txt")
  #expect(second == "areport (2).txt")
  #expect(used.count == 2)
}

@Test func batchNamesDifferIgnoringCaseAndNormalization() {
  var used = Set<String>()
  let names = ["IMG.jpg", "img.jpg", "caf\u{E9}.txt", "cafe\u{301}.txt"].map {
    BatchDownloadNames.uniqueName(for: $0, usedNames: &used)
  }

  #expect(names == ["IMG.jpg", "img (2).jpg", "caf\u{E9}.txt", "cafe\u{301} (2).txt"])
}

@MainActor
@Test func batchDownloadKeepsFailuresSeparateAndWritesToNewFolder() async throws {
  let parent = scratchDirectory()
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: parent) }

  let source = AppModel.DownloadSource(
    profile: try garageProfile(), bucket: "test-bucket", credentials: testCredentials)
  let objects = ["one.txt", "bad.txt", "two.txt"].map {
    ObjectSummary(key: $0, size: 1, lastModified: nil, eTag: nil)
  }
  let progress = Recorder<BatchDownloadProgress>()
  let result = try await BatchDownloader(repository: StubRepository()).download(
    objects, from: source, into: parent
  ) { progress.values.append($0) }

  #expect(result.downloaded == 2)
  #expect(result.failedKeys == ["bad.txt"])
  #expect(!result.cancelled)
  #expect(result.directory.deletingLastPathComponent().path == parent.path)
  #expect(
    try String(contentsOf: result.directory.appendingPathComponent("one.txt"), encoding: .utf8) == "one.txt")
  #expect(
    try String(contentsOf: result.directory.appendingPathComponent("two.txt"), encoding: .utf8) == "two.txt")
  #expect(!FileManager.default.fileExists(atPath: result.directory.appendingPathComponent("bad.txt").path))
  #expect(
    progress.values.last
      == BatchDownloadProgress(completedFiles: 3, totalFiles: 3, receivedBytes: 3, totalBytes: 3))
}

@MainActor
@Test func planDownloadCreatesSubfoldersFetchesVersionsAndRejectsEscapes() async throws {
  let parent = scratchDirectory()
  let root = parent.appendingPathComponent("root", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: parent) }
  let source = AppModel.DownloadSource(
    profile: try garageProfile(), bucket: "test-bucket", credentials: testCredentials)
  func object(_ key: String) -> ObjectSummary {
    ObjectSummary(key: key, size: 1, lastModified: nil, eTag: nil)
  }
  let repository = StubRepository()

  let result = await BatchDownloader(repository: repository).download(
    [
      DownloadItem(object: object("a.txt"), path: "x/y/a.txt", versionID: "v1"),
      DownloadItem(object: object("escape.txt"), path: "../escape.txt"),
      DownloadItem(object: object("bad.txt"), path: "bad.txt"),
    ],
    into: root, from: source
  ) { _ in }

  #expect(result.downloaded == 1)
  #expect(result.failedKeys == ["escape.txt", "bad.txt"])
  #expect(try String(contentsOf: root.appendingPathComponent("x/y/a.txt"), encoding: .utf8) == "a.txt")
  #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("escape.txt").path))
  #expect(await repository.downloads.map(\.versionID) == ["v1", nil])
}
