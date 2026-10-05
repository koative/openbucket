import AppKit
import OpenBucketCore
import Testing

@testable import OpenBucket

private func fileID(_ key: String) -> BrowserRow.ID {
  BrowserRow.ID(isFolder: false, key: Array(key.utf8))
}

@Test func gridClicksSelectToggleAndExtendFromTheAnchor() {
  let ids = ["a", "b", "c", "d", "e"].map(fileID)

  var state = BrowserController.clicking(
    ids[3], in: ids, selection: [], anchor: nil, extend: false, toggle: false)
  #expect(state.selection == [ids[3]])

  // ⇧-click upwards adds the range anchor…clicked, and keeps the anchor.
  state = BrowserController.clicking(
    ids[1], in: ids, selection: state.selection, anchor: state.anchor, extend: true, toggle: false)
  #expect(state.selection == Set(ids[1...3]))
  #expect(state.anchor == ids[3])

  // ⌘-click toggles one item and moves the anchor to it.
  state = BrowserController.clicking(
    ids[2], in: ids, selection: state.selection, anchor: state.anchor, extend: false, toggle: true)
  #expect(state.selection == [ids[1], ids[3]])
  #expect(state.anchor == ids[2])

  // A plain click replaces the selection.
  state = BrowserController.clicking(
    ids[4], in: ids, selection: state.selection, anchor: state.anchor, extend: false, toggle: false)
  #expect(state.selection == [ids[4]])
}

@Test func historyCommitsOnLoadAndDropsForwardEntriesOnNewVisits() throws {
  let root = try S3Location(bucket: "bucket")
  let photos = try S3Location(bucket: "bucket", prefix: "photos/")
  let videos = try S3Location(bucket: "bucket", prefix: "videos/")
  var history = LocationHistory()

  history.visit(root)
  history.visit(photos)
  history.visit(photos)  // refresh doesn't add an entry
  #expect(history.canGoBack && !history.canGoForward)

  let back = history.back()
  #expect(back == root)
  #expect(history.canGoBack)  // nothing moves until the location has loaded
  history.visit(root)
  #expect(!history.canGoBack && history.canGoForward)

  history.visit(videos)
  #expect(history.locations == [root, videos])
  #expect(history.canGoBack && !history.canGoForward)

  history.visit(nil)  // switching connections starts over
  #expect(!history.canGoBack && !history.canGoForward)
}

@Test func filterMatchesNamesIgnoringCaseAndDiacritics() {
  let rows = ["Café Menu.pdf", "cafe-2.jpg", "notes.txt"].map {
    BrowserRow(
      object: ObjectSummary(key: "docs/\($0)", size: 1, lastModified: nil, eTag: nil), parentPrefix: "docs/")
  }
  #expect(BrowserController.filter(rows, by: " CAFE ").map(\.name) == ["Café Menu.pdf", "cafe-2.jpg"])
  #expect(BrowserController.filter(rows, by: "  ").count == 3)
}

@Test func versionRowsShowDeletedFilesAndPastSnapshots() {
  let day: TimeInterval = 86_400
  func version(_ key: String, _ id: String, day offset: Double, latest: Bool = false, marker: Bool = false)
    -> ObjectVersion
  {
    ObjectVersion(
      key: "f/\(key)", versionID: id, isLatest: latest, isDeleteMarker: marker,
      lastModified: Date(timeIntervalSince1970: offset * day), size: 1, eTag: nil, storageClass: nil)
  }
  // a: edited on day 2; b: deleted on day 3; c: created on day 4.
  let versions = [
    version("a", "a2", day: 2, latest: true), version("a", "a1", day: 1),
    version("b", "bm", day: 3, latest: true, marker: true), version("b", "b1", day: 1),
    version("c", "c1", day: 4, latest: true),
  ]
  let current = ["f/a", "f/c"].map { ObjectSummary(key: $0, size: 1, lastModified: nil, eTag: nil) }

  let deleted = BrowserController.versionRows(
    .deleted, versions: versions, current: current, parentPrefix: "f/")
  #expect(deleted.map(\.name) == ["a", "c", "b"])
  #expect(deleted.map(\.versionID) == [nil, nil, "b1"])
  #expect(deleted.map(\.isDeleted) == [false, false, true])

  let past = BrowserController.versionRows(
    .asOf(Date(timeIntervalSince1970: 1.5 * day)), versions: versions, current: current, parentPrefix: "f/")
  #expect(past.map(\.name) == ["a", "b"])
  #expect(past.map(\.versionID) == ["a1", "b1"])
  #expect(past.map(\.isDeleted) == [false, true])

  // Even the latest version is pinned: a newer upload after the history loaded mustn't replace the row.
  let now = BrowserController.versionRows(
    .asOf(Date(timeIntervalSince1970: 5 * day)), versions: versions, current: current, parentPrefix: "f/")
  #expect(now.map(\.versionID) == ["a2", "c1"])
}

@Test func revealFallsBackToTheFolderALinkWithoutSlashNames() {
  let folder = BrowserRow.ID(isFolder: true, key: Array("f/photos/".utf8))
  let file = fileID("f/photos")
  let ids = [folder, fileID("f/a.jpg")]
  #expect(BrowserController.revealTarget(fileID("f/a.jpg"), in: ids) == fileID("f/a.jpg"))
  #expect(BrowserController.revealTarget(file, in: ids) == folder)
  // A file with the exact key wins over the folder.
  #expect(BrowserController.revealTarget(file, in: ids + [file]) == file)
  #expect(BrowserController.revealTarget(fileID("f/missing"), in: ids) == nil)
}

@Test func folderOfKeyCutsAtTheLastSlash() {
  #expect(BrowserRow.folder(of: "a/b/c.txt") == "a/b/")
  #expect(BrowserRow.folder(of: "c.txt") == "")
  #expect(BrowserRow.folder(of: "a/b/") == "a/b/")
}

/// What a drop target receives from `provider`.
private func dropped(_ provider: NSItemProvider) async throws -> BrowserDrop {
  try await withCheckedThrowingContinuation { continuation in
    _ = provider.loadTransferable(type: BrowserDrop.self) { continuation.resume(with: $0) }
  }
}

@MainActor
@Test func ownDragsArriveAsItemsAndFinderFilesAsFiles() async throws {
  let directory = scratchDirectory()
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let model = AppModel(
    repository: StubRepository(),
    profileStore: ProfileStore(fileURL: directory.appendingPathComponent("profiles.json")),
    credentialStore: MemoryCredentialStore(), defaults: scratchDefaults())
  let reference = S3ItemReference(profileID: UUID(), bucket: "b", isFolder: false, key: Array("a/x.txt".utf8))
  // No source: if the drop took the Finder file instead of the item, exporting it would throw.
  let drag = S3FileDrag(
    id: fileID("a/x.txt"), model: model, source: nil,
    object: ObjectSummary(key: "a/x.txt", size: 1, lastModified: nil, eTag: nil), versionID: nil,
    reference: reference)
  let provider = NSItemProvider()
  provider.register(drag)
  guard case .item(let item) = try await dropped(provider) else {
    Issue.record("An in-app drag must arrive as an item to move, not as a file to upload")
    return
  }
  #expect(item == reference)

  let file = directory.appendingPathComponent("photo.jpg")
  try Data("x".utf8).write(to: file)
  guard case .file(let url) = try await dropped(NSItemProvider(object: file as NSURL)) else {
    Issue.record("A Finder file must arrive as a file to upload")
    return
  }
  #expect(url.standardizedFileURL == file.standardizedFileURL)
}
