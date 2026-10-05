import AppKit
import CoreTransferable
import Observation
import OpenBucketCore
import UniformTypeIdentifiers

enum BrowserLayout: String {
  case grid
  case list
}

struct EditorTarget: Identifiable {
  let id = UUID()
  let profile: ConnectionProfile?
}

/// `move` = rename or move (copy, then delete the source); `copy` = restore an old version.
enum TransferKind {
  case download, upload, move, copy, delete
}

enum Transfer {
  case running(kind: TransferKind, name: String?, progress: BatchDownloadProgress)
  case finished(message: String, succeeded: Bool, reveal: URL?, failedKeys: [String])
}

/// Finder-style prompt shown while an upload or move waits for an answer.
struct ConflictPrompt: Identifiable {
  let id: UUID
  /// The file name, as the user knows it.
  let name: String
  /// The destination key that already exists.
  let key: String
  /// Always false: folders merge, files conflict.
  let isFolder: Bool
  /// Conflicts after this one in the same operation, for "Apply to all".
  let remaining: Int
}

enum ConflictChoice {
  case replace, keepBoth, skip
}

struct RenameTarget: Identifiable {
  let id: BrowserRow.ID
  let name: String
  let isFolder: Bool
}

struct MoveTarget: Identifiable {
  let id = UUID()
  let ids: Set<BrowserRow.ID>
  let names: [String]
}

struct DeleteConfirmation: Identifiable {
  let id = UUID()
  let ids: Set<BrowserRow.ID>
  /// "Delete “photo.jpg”?" or "Delete 3 items?".
  let title: String
  /// Nil when unknown.
  let versioning: BucketVersioning?
}

struct MetadataTarget: Identifiable {
  let id = UUID()
  let object: ObjectSummary
  let headers: ObjectHeaders
  /// Nil when tagging is unsupported or denied: tags aren't editable then.
  let tags: [String: String]?
}

struct PreviewFailure {
  let id: BrowserRow.ID
  let message: String
}

struct ShareTarget: Identifiable {
  let object: ObjectSummary
  let versionID: String?
  let id = UUID()
}

/// Previous-versions views of the current folder, built from `FolderHistory`.
enum HistoryMode: Equatable {
  /// Current files plus files whose latest entry is a delete marker.
  case deleted
  /// The folder's files as they were at the date.
  case asOf(Date)
}

/// Back/Forward over visited locations. An entry is committed only once its location has loaded.
struct LocationHistory {
  private(set) var locations: [S3Location] = []
  private(set) var index = -1
  private var pending: Int?

  var canGoBack: Bool { index > 0 }
  var canGoForward: Bool { index + 1 < locations.count }

  mutating func back() -> S3Location? { step(-1) }
  mutating func forward() -> S3Location? { step(1) }

  mutating func visit(_ location: S3Location?) {
    defer { pending = nil }
    guard let location else {
      locations = []
      index = -1
      return
    }
    if let pending, locations[pending] == location {
      index = pending
      return
    }
    if locations.indices.contains(index), locations[index] == location { return }
    locations.removeSubrange((index + 1)...)
    locations.append(location)
    index += 1
  }

  /// Steps from a still-loading Back/Forward target, so repeated presses keep going.
  private mutating func step(_ offset: Int) -> S3Location? {
    let target = (pending ?? index) + offset
    guard locations.indices.contains(target) else { return nil }
    pending = target
    return locations[target]
  }
}

/// Window-level browser UI state shared by the views and the menu commands.
@MainActor @Observable
final class BrowserController {
  let model: AppModel

  var layout: BrowserLayout =
    BrowserLayout(rawValue: UserDefaults.standard.string(forKey: "browserLayout") ?? "") ?? .grid
  {
    didSet { UserDefaults.standard.set(layout.rawValue, forKey: "browserLayout") }
  }
  var sortOrder: [KeyPathComparator<BrowserRow>] = [
    KeyPathComparator(\BrowserRow.name, comparator: .localizedStandard)
  ]
  var selection = Set<BrowserRow.ID>()
  var showsInspector = false
  var editorTarget: EditorTarget?
  var showsLocationSheet = false
  var showsAsOfSheet = false
  var shareTarget: ShareTarget?
  /// Message of the last failed favorites change, shown in an alert.
  var favoriteError: String?
  private(set) var history = LocationHistory()
  /// Filters the loaded rows; also the query of `deepSearch`. Clearing it returns to the folder.
  var searchText = "" {
    didSet { if searchText.isEmpty { endSearch() } }
  }
  /// Bumped by Edit ▸ Find (⌘F); the browser focuses its search field on change.
  private(set) var searchFocusRequest = 0
  /// Mirrors the search field's focus so ⌘↑/⌘↓ menu items step aside for text editing.
  var isSearchFocused = false

  func focusSearch() { searchFocusRequest += 1 }
  /// Search below the current folder; while set, its results replace the folder's rows.
  private(set) var deepSearch: DeepSearch?
  /// Kept across navigation; each folder loads its own `folderHistory`. Deep search lists current objects
  /// only, so it ends when a history mode starts.
  var historyMode: HistoryMode? {
    didSet {
      guard historyMode != oldValue else { return }
      if historyMode != nil { endSearch() }
      loadHistory()
    }
  }
  private(set) var folderHistory: FolderHistory?
  /// Why the last history mode was switched off.
  private(set) var historyFailure: S3Failure?
  /// Item selected by a link or search result once its folder has loaded; the view scrolls to it.
  private(set) var revealedID: BrowserRow.ID?
  /// Quick Look file. Replacing or clearing it (Quick Look closed) removes the old private temp directory.
  var previewURL: URL? {
    didSet {
      if let oldValue, oldValue != previewURL {
        try? FileManager.default.removeItem(at: oldValue.deletingLastPathComponent())
      }
    }
  }
  private(set) var preparingPreview: ObjectSummary?
  private(set) var previewFailure: PreviewFailure?
  private(set) var transfer: Transfer?
  var isTransferring: Bool {
    if case .running = transfer { true } else { false }
  }
  /// Bumped after every finished write, so views reload details and versions.
  private(set) var changeGeneration = 0
  /// Shown as a dialog while an upload or move waits in `askConflict`.
  private(set) var conflict: ConflictPrompt?
  /// New Folder sheet while set.
  var newFolderParent: S3Location?
  var renameTarget: RenameTarget?
  var moveTarget: MoveTarget?
  var deleteConfirmation: DeleteConfirmation?
  var metadataTarget: MetadataTarget?

  @ObservationIgnored private var anchor: BrowserRow.ID?
  @ObservationIgnored private var selectionAfterLoad: BrowserRow.ID?
  @ObservationIgnored private var pendingReveal: BrowserRow.ID?
  @ObservationIgnored private var deepSearchQuery: String?
  /// The browser window; save and open panels attach to it.
  @ObservationIgnored weak var window: NSWindow?
  @ObservationIgnored private var previewTask: Task<Void, Never>?
  @ObservationIgnored private var transferTask: Task<Void, Never>?
  @ObservationIgnored private var conflictAnswer: CheckedContinuation<ConflictAnswer?, Never>?

  init(model: AppModel) {
    self.model = model
  }

  var isSheetPresented: Bool {
    editorTarget != nil || showsLocationSheet || showsAsOfSheet || shareTarget != nil
      || newFolderParent != nil
      || renameTarget != nil || moveTarget != nil || metadataTarget != nil || conflict != nil
      || deleteConfirmation != nil
  }

  // MARK: Rows and sorting

  /// Search results, or the folder's (or its history's) folders then files, filtered by `searchText`;
  /// each group in `sortOrder`.
  func rows() -> [BrowserRow] {
    let order = sortOrder + [KeyPathComparator(\BrowserRow.name, comparator: .localizedStandard)]
    let rows = Self.filter(unsortedRows(), by: deepSearch == nil ? searchText : "")
    return rows.filter(\.isFolder).sorted(using: order) + rows.filter { !$0.isFolder }.sorted(using: order)
  }

  /// Case- and diacritic-insensitive substring match on the name; a blank filter keeps every row.
  nonisolated static func filter(_ rows: [BrowserRow], by text: String) -> [BrowserRow] {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty ? rows : rows.filter { $0.name.localizedStandardContains(query) }
  }

  /// Every row of the current view, unfiltered; the source for lookups by ID.
  // ponytail: rebuilt per call (history modes re-run VersionTimeline, O(versions)); cache per
  // history/listing change if folders with ~100k versions feel slow.
  private func unsortedRows() -> [BrowserRow] {
    if let deepSearch {
      return deepSearch.results.map { BrowserRow(object: $0, parentPrefix: BrowserRow.folder(of: $0.key)) }
    }
    guard let location = model.browser.location else { return [] }
    var prefixes = model.browser.prefixes
    var files: [BrowserRow]
    if let historyMode, let folderHistory, folderHistory.location == location {
      // ponytail: folders aren't time-filtered (any that ever held a version shows); recurse if needed.
      let listed = Set(prefixes.map { Array($0.utf8) })
      prefixes += folderHistory.prefixes.filter { !listed.contains(Array($0.utf8)) }
      files = Self.versionRows(
        historyMode, versions: folderHistory.versions, current: model.browser.objects,
        parentPrefix: location.prefix)
    } else {
      files = model.browser.objects.map { BrowserRow(object: $0, parentPrefix: location.prefix) }
    }
    // A folder's own zero-byte marker ("photos/") is how S3 keeps an empty folder, not a file inside it.
    let marker = Array(location.prefix.utf8)
    files.removeAll { $0.object?.size == 0 && $0.id.key == marker }
    return prefixes.map { BrowserRow(prefix: $0, parentPrefix: location.prefix) } + files
  }

  /// File rows for `mode`: `.deleted` adds each deleted key's newest real version to the listed files;
  /// `.asOf` is the snapshot at the date, with keys deleted since marked `isDeleted`.
  nonisolated static func versionRows(
    _ mode: HistoryMode, versions: [ObjectVersion], current: [ObjectSummary], parentPrefix: String
  ) -> [BrowserRow] {
    let deleted = VersionTimeline.deleted(versions)
    switch mode {
    case .deleted:
      let listed = Set(current.map(\.id))
      return current.map { BrowserRow(object: $0, parentPrefix: parentPrefix) }
        + deleted.filter { !listed.contains(Array($0.key.utf8)) }.map {
          BrowserRow(object: $0.summary, parentPrefix: parentPrefix, versionID: $0.versionID, isDeleted: true)
        }
    case .asOf(let date):
      // Always the listed version: "latest" was true when the history loaded, not necessarily now.
      let deletedKeys = Set(deleted.map { Array($0.key.utf8) })
      return VersionTimeline.snapshot(versions, at: date).map {
        BrowserRow(
          object: $0.summary, parentPrefix: parentPrefix, versionID: $0.versionID,
          isDeleted: deletedKeys.contains(Array($0.key.utf8)))
      }
    }
  }

  var sortKey: PartialKeyPath<BrowserRow> {
    get {
      guard let keyPath = sortOrder.first?.keyPath else { return \BrowserRow.name }
      return keyPath
    }
    set {
      let order = sortOrder.first?.order ?? .forward
      let comparator: KeyPathComparator<BrowserRow>
      if newValue == \BrowserRow.sortSize {
        comparator = KeyPathComparator(\BrowserRow.sortSize, order: order)
      } else if newValue == \BrowserRow.sortModified {
        comparator = KeyPathComparator(\BrowserRow.sortModified, order: order)
      } else {
        comparator = KeyPathComparator(\BrowserRow.name, comparator: .localizedStandard, order: order)
      }
      sortOrder = [comparator]
    }
  }

  var sortsAscending: Bool {
    get { sortOrder.first?.order != .reverse }
    set {
      guard !sortOrder.isEmpty else { return }
      sortOrder[0].order = newValue ? .forward : .reverse
    }
  }

  // MARK: Selection

  /// Grid click: plain click selects, ⌘ toggles, ⇧ adds the range from the anchor.
  nonisolated static func clicking(
    _ id: BrowserRow.ID, in ids: [BrowserRow.ID], selection: Set<BrowserRow.ID>, anchor: BrowserRow.ID?,
    extend: Bool, toggle: Bool
  ) -> (selection: Set<BrowserRow.ID>, anchor: BrowserRow.ID?) {
    if extend, let anchor, let from = ids.firstIndex(of: anchor), let to = ids.firstIndex(of: id) {
      return (selection.union(ids[min(from, to)...max(from, to)]), anchor)
    }
    if toggle { return (selection.symmetricDifference([id]), id) }
    return ([id], id)
  }

  func click(_ id: BrowserRow.ID, in ids: [BrowserRow.ID], extend: Bool, toggle: Bool) {
    (selection, anchor) = Self.clicking(
      id, in: ids, selection: selection, anchor: anchor, extend: extend, toggle: toggle)
  }

  /// Arrow-key movement in the grid; returns the newly selected item so the view can scroll to it.
  func moveSelection(by offset: Int, in ids: [BrowserRow.ID]) -> BrowserRow.ID? {
    guard !ids.isEmpty else { return nil }
    let current = anchor.flatMap { ids.firstIndex(of: $0) } ?? ids.firstIndex { selection.contains($0) }
    let target = ids[current.map { min(max($0 + offset, 0), ids.count - 1) } ?? 0]
    selection = [target]
    anchor = target
    return target
  }

  func selectAll(_ ids: [BrowserRow.ID]) {
    selection = Set(ids)
  }

  /// Context-menu target: the whole selection when the clicked item is part of it.
  func targets(for id: BrowserRow.ID) -> Set<BrowserRow.ID> {
    selection.contains(id) ? selection : [id]
  }

  func objects(for ids: Set<BrowserRow.ID>) -> [ObjectSummary] {
    fileRows(for: ids).compactMap(\.object)
  }

  /// File rows among `ids`, with their `versionID`s.
  func fileRows(for ids: Set<BrowserRow.ID>) -> [BrowserRow] {
    unsortedRows().filter { !$0.isFolder && ids.contains($0.id) }
  }

  /// The folder `id` names in the current bucket; nil for files.
  func location(of id: BrowserRow.ID) -> S3Location? {
    guard id.isFolder, let bucket = model.browser.location?.bucket else { return nil }
    return try? S3Location(bucket: bucket, prefix: id.keyString)
  }

  /// Target of folder-wide commands: the one selected folder, else the current folder.
  var folderTarget: S3Location? {
    (selection.count == 1 ? selection.first.flatMap(location(of:)) : nil) ?? model.browser.location
  }

  func showInfo(_ ids: Set<BrowserRow.ID>) {
    selection = ids
    showsInspector = true
  }

  // MARK: Navigation

  /// Folder → navigate; search result → reveal in its folder; file → Quick Look, or reveal in the
  /// inspector when too large to preview.
  func open(_ id: BrowserRow.ID) {
    if let location = location(of: id) {
      model.open(location)
    } else if deepSearch != nil {
      reveal(id)
    } else if let row = fileRows(for: [id]).first, let object = row.object {
      quickLook(object, versionID: row.versionID)
    }
  }

  func openSelection() {
    if selection.count == 1, let id = selection.first { open(id) }
  }

  func goBack() {
    if let location = history.back() { model.open(location) }
  }

  func goForward() {
    if let location = history.forward() { model.open(location) }
  }

  var enclosingLocation: S3Location? {
    guard let location = model.browser.location, !location.prefix.isEmpty else { return nil }
    // Bytes, not Characters: a "/" fused with a combining mark is still a separator in S3.
    var bytes = Array(location.prefix.utf8)
    if bytes.last == UInt8(ascii: "/") { bytes.removeLast() }
    let parent = bytes.lastIndex(of: UInt8(ascii: "/")).map { bytes[...$0] } ?? []
    return try? S3Location(bucket: location.bucket, prefix: String(decoding: parent, as: UTF8.self))
  }

  func goToEnclosingFolder() {
    guard let current = model.browser.location, let parent = enclosingLocation else { return }
    selectionAfterLoad = BrowserRow.ID(isFolder: true, key: Array(current.prefix.utf8))
    model.open(parent)
  }

  /// Called by the view whenever `model.browser.location` changes.
  func locationChanged(to location: S3Location?) {
    history.visit(location)
    let restored = location == nil ? nil : selectionAfterLoad
    selection = restored.map { [$0] } ?? []
    anchor = restored
    selectionAfterLoad = nil
    cancelPreview()
    previewURL = nil
    previewFailure = nil
    searchText = ""
    revealedID = nil
    loadHistory()
  }

  /// Called by the view when a listing finishes, and when folder versions finish loading: selects the item
  /// a link or search result asked for.
  func revealPendingSelection() {
    // While connecting, a finishing listing belongs to the folder being left.
    guard !model.isConnecting, model.browser.location != nil else { return }
    if let key = model.consumePendingSelectionKey() {
      pendingReveal = BrowserRow.ID(isFolder: false, key: Array(key.utf8))
    }
    guard let pending = pendingReveal else { return }
    // ponytail: only finds items on loaded pages; page on until found if deep links into huge folders matter.
    guard let id = Self.revealTarget(pending, in: unsortedRows().map(\.id)) else {
      // History rows appear only once the folder's versions have loaded.
      if historyMode == nil || folderHistory?.isRunning != true { pendingReveal = nil }
      return
    }
    pendingReveal = nil
    if id != pending, let folder = location(of: id) {
      model.open(folder)
      return
    }
    selection = [id]
    anchor = id
    revealedID = id
    showsInspector = true
  }

  /// `id` when listed, else the folder a link without a trailing slash meant (`photos` → `photos/`).
  nonisolated static func revealTarget(_ id: BrowserRow.ID, in ids: [BrowserRow.ID]) -> BrowserRow.ID? {
    if ids.contains(id) { return id }
    let folder = BrowserRow.ID(isFolder: true, key: id.key + [UInt8(ascii: "/")])
    return !id.isFolder && ids.contains(folder) ? folder : nil
  }

  /// Leaves the search and selects the result in its folder.
  private func reveal(_ id: BrowserRow.ID) {
    guard let bucket = model.browser.location?.bucket,
      let folder = try? S3Location(bucket: bucket, prefix: BrowserRow.folder(of: id.keyString))
    else { return }
    searchText = ""
    pendingReveal = id
    if folder == model.browser.location {
      revealPendingSelection()
    } else {
      model.open(folder)
    }
  }

  // MARK: Search

  /// Searches everything below the current folder for `searchText`. Not in history modes: the search
  /// lists current objects, so typing only filters the history rows there.
  func searchAll() {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, historyMode == nil, let location = model.browser.location else { return }
    // Return and the pause-triggered search ask for the same search; keep the running or finished one.
    if let deepSearch, deepSearch.location == location, deepSearchQuery == query, deepSearch.failure == nil {
      return
    }
    guard let source = model.downloadSource() else { return }
    deepSearch?.cancel()
    let search = DeepSearch(repository: model.repository, source: source, location: location)
    deepSearch = search
    deepSearchQuery = query
    search.run(query: query)
  }

  private func endSearch() {
    deepSearch?.cancel()
    deepSearch = nil
  }

  // MARK: Previous versions

  /// ⌘R, the toolbar and Try Again: reloads the listing and, in a history mode, the folder's versions.
  func refresh() {
    model.refresh()
    folderHistory?.cancel()
    folderHistory = nil
    loadHistory()
  }

  /// Exit button and failures: leaves Browse As Of / Show Deleted Files.
  func exitHistory() {
    historyMode = nil
  }

  func dismissHistoryFailure() {
    historyFailure = nil
  }

  /// Loads the current folder's versions when a history mode is on and they aren't loaded yet.
  private func loadHistory() {
    historyFailure = nil
    guard historyMode != nil, let location = model.browser.location else {
      folderHistory?.cancel()
      folderHistory = nil
      return
    }
    guard folderHistory?.location != location, let source = model.downloadSource() else { return }
    folderHistory?.cancel()
    let folderHistory = FolderHistory(repository: model.repository, source: source, location: location)
    self.folderHistory = folderHistory
    folderHistory.start()
    Task {
      await folderHistory.task?.value
      guard self.folderHistory === folderHistory else { return }
      // E.g. a provider without versioning support: say why and switch the mode off.
      if let failure = folderHistory.failure {
        historyMode = nil
        historyFailure = failure
      }
      revealPendingSelection()
    }
  }

  /// Drops selected items that vanished after a refresh or reload of the same folder.
  func pruneSelection(to ids: [BrowserRow.ID]) {
    guard !selection.isEmpty else { return }
    selection.formIntersection(ids)
  }

  // MARK: Quick Look

  /// The one selected file.
  var quickLookTarget: BrowserRow? {
    guard selection.count == 1, let id = selection.first, !id.isFolder else { return nil }
    return fileRows(for: [id]).first
  }

  func toggleQuickLook() {
    if previewURL != nil {
      previewURL = nil
    } else if let row = quickLookTarget, let object = row.object {
      quickLook(object, versionID: row.versionID)
    }
  }

  /// `versionID` nil previews the current version.
  func quickLook(_ object: ObjectSummary, versionID: String? = nil) {
    let id = BrowserRow.ID(isFolder: false, key: object.id)
    guard object.size <= BrowserRow.previewLimit else {
      selection = [id]
      anchor = id
      showsInspector = true
      return
    }
    guard let source = model.downloadSource() else { return }
    cancelPreview()
    previewFailure = nil
    preparingPreview = object
    previewTask = Task {
      do {
        let url = try await model.downloadToPrivateTemp(
          object, versionID: versionID, from: source, maximumBytes: BrowserRow.previewLimit)
        guard !Task.isCancelled else {
          try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
          return
        }
        previewURL = url
      } catch {
        guard !Task.isCancelled else { return }
        previewFailure = PreviewFailure(id: id, message: AppModel.failure(for: error).message)
      }
      preparingPreview = nil
      previewTask = nil
    }
  }

  func cancelPreview() {
    previewTask?.cancel()
    previewTask = nil
    preparingPreview = nil
  }

  func dismissPreviewFailure() {
    previewFailure = nil
  }

  // MARK: Transfers

  /// One item, or files among several. Folder downloads fetch current files, so not in history modes.
  var canDownloadSelection: Bool {
    selection.contains { !$0.isFolder } || (selection.count == 1 && historyMode == nil)
  }

  func downloadSelection() {
    download(selection)
  }

  /// A single folder → folder download; otherwise the files among `ids`, each at its row's version.
  func download(_ ids: Set<BrowserRow.ID>) {
    if ids.count == 1, let folder = ids.first.flatMap(location(of:)) {
      downloadFolder(folder)
      return
    }
    let rows = fileRows(for: ids)
    guard !isTransferring, !rows.isEmpty, let source = model.downloadSource() else { return }
    if rows.count == 1, let object = rows[0].object {
      save(object, versionID: rows[0].versionID, from: source)
    } else {
      let versionIDs = Dictionary(
        rows.compactMap { row in row.versionID.map { (row.id.key, $0) } },
        uniquingKeysWith: { first, _ in first })
      save(rows.compactMap(\.object), versionIDs: versionIDs, from: source)
    }
  }

  /// One file at `versionID` (nil = current) through a save panel.
  func download(_ object: ObjectSummary, versionID: String?) {
    guard !isTransferring, let source = model.downloadSource() else { return }
    save(object, versionID: versionID, from: source)
  }

  /// Recreates the folder and everything below it inside a chosen local folder. Current files only, so
  /// not offered in history modes.
  func downloadFolder(_ location: S3Location) {
    guard !isTransferring, historyMode == nil, let source = model.downloadSource() else { return }
    let name = location.displayName
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Download"
    panel.message = "OpenBucket will create a folder named “\(name)” here with everything inside it."
    Task {
      guard let directory = await choose(panel), !isTransferring else { return }
      start(.download, name: name, Self.preparing) {
        let result = try await FolderDownloader(repository: self.model.repository).download(
          location, from: source, into: directory
        ) { self.update($0) }
        return Self.finished(result)
      }
    }
  }

  /// Also answers a pending conflict prompt, so the waiting transfer can stop.
  func cancelTransfer() {
    transferTask?.cancel()
    answerConflict(nil)
  }

  func dismissTransfer() {
    if !isTransferring { transfer = nil }
  }

  private func save(_ object: ObjectSummary, versionID: String?, from source: AppModel.DownloadSource) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = PreviewFileName.from(objectKey: object.key)
    panel.canCreateDirectories = true
    Task {
      guard let destination = await choose(panel), !isTransferring else { return }
      let name = destination.lastPathComponent
      let total = object.size
      let initial = BatchDownloadProgress(
        completedFiles: 0, totalFiles: 1, receivedBytes: 0, totalBytes: total)
      start(.download, name: name, initial) {
        try await self.model.download(
          object, versionID: versionID, from: source, to: destination, maximumBytes: .max
        ) { bytes in
          self.update(
            BatchDownloadProgress(completedFiles: 0, totalFiles: 1, receivedBytes: bytes, totalBytes: total))
        }
        return .finished(message: "Downloaded \(name)", succeeded: true, reveal: destination, failedKeys: [])
      }
    }
  }

  private func save(
    _ objects: [ObjectSummary], versionIDs: [[UInt8]: String], from source: AppModel.DownloadSource
  ) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Download"
    panel.message = "OpenBucket will create a new folder here for the \(countLabel(objects.count, "file"))."
    Task {
      guard let directory = await choose(panel), !isTransferring else { return }
      let total = objects.reduce(Int64.zero) { $0 + $1.size }
      let initial = BatchDownloadProgress(
        completedFiles: 0, totalFiles: objects.count, receivedBytes: 0, totalBytes: total)
      start(.download, name: nil, initial) {
        let result = try await self.model.downloadSelected(
          objects, versionIDs: versionIDs, from: source, into: directory
        ) { self.update($0) }
        return Self.finished(result)
      }
    }
  }

  /// Sheet on the browser window (app-modal when it's closed); the chosen URL, nil when cancelled.
  private func choose(_ panel: NSSavePanel) async -> URL? {
    let response: NSApplication.ModalResponse
    if let window, window.isVisible {
      response = await panel.beginSheetModal(for: window)
    } else {
      response = panel.runModal()
    }
    return response == .OK ? panel.url : nil
  }

  private static func finished(_ result: BatchDownloadResult) -> Transfer {
    let downloaded = countLabel(result.downloaded, "file")
    let message =
      result.cancelled
      ? "Stopped after \(downloaded)"
      : result.failedKeys.isEmpty
        ? "Downloaded \(downloaded)"
        : "Downloaded \(downloaded) · \(result.failedKeys.count.formatted()) failed"
    return .finished(
      message: message, succeeded: !result.cancelled && result.failedKeys.isEmpty,
      reveal: result.directory, failedKeys: result.failedKeys)
  }

  private static func finished(_ result: ChangeResult, _ verb: String) -> Transfer {
    let done = countLabel(result.done, "file")
    let message =
      result.cancelled
      ? "Stopped after \(done)"
      : result.failedKeys.isEmpty
        ? "\(verb) \(done)"
        : "\(verb) \(done) · \(result.failedKeys.count.formatted()) failed"
    return .finished(
      message: message, succeeded: !result.cancelled && result.failedKeys.isEmpty, reveal: nil,
      failedKeys: result.failedKeys)
  }

  /// Shown while a transfer lists what it will do.
  private static let preparing = BatchDownloadProgress(
    completedFiles: 0, totalFiles: 0, receivedBytes: 0, totalBytes: 0)

  private func start(
    _ kind: TransferKind, name: String?, _ progress: BatchDownloadProgress,
    _ work: @escaping @MainActor () async throws -> Transfer
  ) {
    transfer = .running(kind: kind, name: name, progress: progress)
    transferTask = Task {
      do {
        transfer = try await work()
      } catch {
        let verb =
          switch kind {
          case .download: "download"
          case .upload: "upload"
          case .move: "move"
          case .copy: "restore"
          case .delete: "delete"
          }
        transfer =
          Task.isCancelled
          ? nil
          : .finished(
            message: "Couldn't \(verb) \(name ?? "the files"). \(AppModel.failure(for: error).message)",
            succeeded: false, reveal: nil, failedKeys: [])
      }
      transferTask = nil
    }
  }

  /// Transfers drain their progress before returning, so only the running transfer receives updates.
  private func update(_ progress: BatchDownloadProgress) {
    guard case .running(let kind, let name, _) = transfer else { return }
    transfer = .running(kind: kind, name: name, progress: progress)
  }

  // MARK: Changes

  /// Help text for disabled write commands; nil when changes are allowed.
  var modifyUnavailableReason: String? {
    guard let profile = model.selectedProfile, model.browser.location != nil else {
      return "Open a bucket to make changes."
    }
    if !profile.allowsChanges {
      return "This connection is read-only. Edit the connection and turn on Allow Changes."
    }
    if historyMode != nil { return "Return to the current files to make changes." }
    if deepSearch != nil { return "Clear the search to make changes." }
    return nil
  }

  /// The connection allows changes and a bucket folder (not history or search results) is shown.
  var canModify: Bool { modifyUnavailableReason == nil }

  /// The connection to write with; nil unless it allows changes. Every write checks this itself.
  private func writeSource() -> AppModel.DownloadSource? {
    guard let source = model.downloadSource(), source.profile.allowsChanges else { return nil }
    return source
  }

  private func changes(_ source: AppModel.DownloadSource) -> ObjectChanges {
    ObjectChanges(repository: model.repository, source: source)
  }

  private static let busy = "Wait for the current transfer to finish."
  private static let notReady = "The connection isn't ready yet. Try again in a moment."

  /// Listed rows among `ids`, folders included.
  private func listedRows(for ids: Set<BrowserRow.ID>) -> [BrowserRow] {
    unsortedRows().filter { ids.contains($0.id) }
  }

  /// Shared by the New Folder and Rename sheets; nil when `name` is valid.
  func validateName(_ name: String) -> String? {
    ObjectChanges.nameProblem(name)
  }

  /// Reloads what a write changed and selects `id` when given (an item of the shown folder).
  private func finishWrite(selecting id: BrowserRow.ID? = nil) {
    changeGeneration += 1
    refresh()
    if let id {
      selection = [id]
      anchor = id
    }
  }

  /// Shows `conflict` and waits for `resolveConflict`; nil when the transfer is cancelled instead.
  private func askConflict(key: String, remaining: Int) async -> ConflictAnswer? {
    guard !Task.isCancelled else { return nil }
    return await withCheckedContinuation { continuation in
      conflictAnswer = continuation
      conflict = ConflictPrompt(
        id: UUID(), name: ObjectChanges.name(of: key), key: key, isFolder: false, remaining: remaining)
    }
  }

  func resolveConflict(_ choice: ConflictChoice, applyToAll: Bool) {
    answerConflict((choice, applyToAll))
  }

  private func answerConflict(_ answer: ConflictAnswer?) {
    let continuation = conflictAnswer
    conflictAnswer = nil
    conflict = nil
    continuation?.resume(returning: answer)
  }

  /// Open panel for files and folders to upload into `location` (nil = the current folder).
  func uploadFiles(into location: S3Location? = nil) {
    guard canModify, !isTransferring, let location = location ?? model.browser.location else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.prompt = "Upload"
    panel.message = "Choose files and folders to upload to “\(location.displayName)”."
    Task {
      guard await choose(panel) != nil else { return }
      upload(panel.urls, into: location)
    }
  }

  /// Uploads files, and folders with everything inside, into `location`; taken names go to `conflict`.
  func upload(_ urls: [URL], into location: S3Location) {
    guard canModify, !isTransferring, !urls.isEmpty, let source = writeSource(),
      location.bucket == source.bucket
    else { return }
    let changes = changes(source)
    start(.upload, name: urls.count == 1 ? urls[0].lastPathComponent : nil, Self.preparing) {
      let plan = try await changes.uploadPlan(urls, into: location.prefix) {
        await self.askConflict(key: $0, remaining: $1)
      }
      guard let items = plan else { throw CancellationError() }
      let result = await changes.upload(items) { self.update($0) }
      let file = items.count == 1 && items[0].source != nil && location == self.model.browser.location
      self.finishWrite(selecting: file ? BrowserRow.ID(isFolder: false, key: Array(items[0].key.utf8)) : nil)
      return Self.finished(result, "Uploaded")
    }
  }

  /// New Folder sheet for `location` (nil = the current folder).
  func requestNewFolder(in location: S3Location? = nil) {
    guard canModify else { return }
    newFolderParent = location ?? model.browser.location
  }

  /// Creates the folder marker "<parent>name/"; nil on success, else what went wrong.
  func createFolder(named name: String, in parent: S3Location) async -> String? {
    guard canModify, let source = writeSource(), parent.bucket == source.bucket else {
      return modifyUnavailableReason ?? "Open “\(parent.bucket)” to make changes there."
    }
    if let problem = validateName(name) { return problem }
    let key = parent.prefix + name + "/"
    do {
      guard try await !changes(source).exists(prefix: key) else {
        return "A folder named “\(name)” already exists here."
      }
      try await model.repository.putEmptyObject(
        profile: source.profile, credentials: source.credentials, bucket: source.bucket, key: key)
    } catch {
      return AppModel.failure(for: error).message
    }
    newFolderParent = nil
    finishWrite(
      selecting: parent == model.browser.location ? BrowserRow.ID(isFolder: true, key: Array(key.utf8)) : nil)
    return nil
  }

  func requestRename(_ id: BrowserRow.ID) {
    guard canModify, let row = listedRows(for: [id]).first else { return }
    renameTarget = RenameTarget(id: id, name: row.name, isFolder: row.isFolder)
  }

  /// Renames a file, or every object below a folder, as a transfer; nil once started, else why not. A taken name
  /// is refused rather than replaced.
  func rename(_ target: RenameTarget, to newName: String) async -> String? {
    guard canModify, let source = writeSource() else { return modifyUnavailableReason ?? Self.notReady }
    if let problem = validateName(newName) { return problem }
    guard !newName.utf8.elementsEqual(target.name.utf8) else {
      renameTarget = nil
      return nil
    }
    guard !isTransferring else { return Self.busy }
    guard let row = listedRows(for: [target.id]).first else { return "“\(target.name)” is no longer here." }
    let newKey = ObjectChanges.parentPrefix(of: row.fullKey) + newName + (row.isFolder ? "/" : "")
    let changes = changes(source)
    let items: [CopyItem]
    do {
      guard let planned = try await changes.renamePlan(row, to: newKey) else {
        return "An item named “\(newName)” already exists in this folder."
      }
      items = planned
    } catch {
      return AppModel.failure(for: error).message
    }
    guard !items.isEmpty else { return "“\(target.name)” is no longer here." }
    guard !isTransferring else { return Self.busy }
    renameTarget = nil
    let location = model.browser.location
    start(.move, name: target.name, Self.preparing) {
      let result = await changes.copy(items, deletingSources: true) { self.update($0) }
      self.finishWrite(
        selecting: location == self.model.browser.location
          ? BrowserRow.ID(isFolder: row.isFolder, key: Array(newKey.utf8)) : nil)
      guard result.cancelled || !result.failedKeys.isEmpty else {
        return .finished(message: "Renamed to “\(newName)”", succeeded: true, reveal: nil, failedKeys: [])
      }
      return Self.finished(result, "Renamed")
    }
    return nil
  }

  func requestMove(_ ids: Set<BrowserRow.ID>) {
    let rows = listedRows(for: ids)
    guard canModify, !rows.isEmpty else { return }
    moveTarget = MoveTarget(ids: Set(rows.map(\.id)), names: rows.map(\.name))
  }

  /// Moves the items into `destination` (same bucket) as a transfer; nil once started, else why not.
  func move(_ target: MoveTarget, to destination: S3Location) async -> String? {
    guard canModify, let source = writeSource() else { return modifyUnavailableReason ?? Self.notReady }
    guard destination.bucket == source.bucket else {
      return "Items can only be moved within “\(source.bucket)”."
    }
    guard !isTransferring else { return Self.busy }
    let rows = listedRows(for: target.ids)
    guard !rows.isEmpty else { return "These items are no longer here." }
    let prefix =
      destination.prefix.isEmpty || ObjectChanges.isMarker(destination.prefix)
      ? destination.prefix : destination.prefix + "/"
    if let problem = ObjectChanges.moveProblem(rows, to: prefix) { return problem }
    moveTarget = nil
    let changes = changes(source)
    start(.move, name: rows.count == 1 ? rows[0].name : nil, Self.preparing) {
      let plan = try await changes.movePlan(rows, to: prefix) {
        await self.askConflict(key: $0, remaining: $1)
      }
      guard let items = plan else { throw CancellationError() }
      let result = await changes.copy(items, deletingSources: true) { self.update($0) }
      self.finishWrite()
      return Self.finished(result, "Moved")
    }
    return nil
  }

  /// Asks for confirmation through `deleteConfirmation`, worded by the bucket's versioning.
  func requestDelete(_ ids: Set<BrowserRow.ID>) {
    let rows = listedRows(for: ids)
    guard canModify, !isTransferring, !rows.isEmpty, let source = writeSource() else { return }
    let title = rows.count == 1 ? "Delete “\(rows[0].name)”?" : "Delete \(rows.count.formatted()) items?"
    Task {
      let versioning = try? await model.repository.bucketVersioning(
        profile: source.profile, credentials: source.credentials, bucket: source.bucket)
      guard canModify else { return }
      deleteConfirmation = DeleteConfirmation(ids: Set(rows.map(\.id)), title: title, versioning: versioning)
    }
  }

  /// Deletes the confirmed files and everything below the confirmed folders, as a transfer.
  func confirmDelete(_ confirmation: DeleteConfirmation) {
    deleteConfirmation = nil
    let rows = listedRows(for: confirmation.ids)
    guard canModify, !isTransferring, !rows.isEmpty, let source = writeSource() else { return }
    let changes = changes(source)
    start(.delete, name: rows.count == 1 ? rows[0].name : nil, Self.preparing) {
      var objects: [ObjectSummary] = []
      for row in rows { objects += try await changes.objects(in: row) }
      let result = await changes.delete(objects) { self.update($0) }
      self.finishWrite()
      return Self.finished(result, "Deleted")
    }
  }

  /// Deleted rows with a version to bring back.
  private func restorableRows(_ ids: Set<BrowserRow.ID>) -> [BrowserRow] {
    fileRows(for: ids).filter { $0.isDeleted && $0.versionID != nil }
  }

  /// Works in history modes, unlike `canModify`.
  var canRestoreSelection: Bool {
    model.selectedProfile?.allowsChanges == true && !isTransferring && !restorableRows(selection).isEmpty
  }

  func restore(_ version: ObjectVersion) {
    guard !version.isDeleteMarker else { return }
    restoreVersions([
      CopyItem(
        sourceKey: version.key, sourceVersionID: version.versionID, size: version.size,
        destinationKey: version.key)
    ])
  }

  /// Deleted rows (Show Deleted Files) come back at their row's version.
  func restore(_ ids: Set<BrowserRow.ID>) {
    restoreVersions(
      restorableRows(ids).compactMap { row in
        row.object.map {
          CopyItem(sourceKey: $0.key, sourceVersionID: row.versionID, size: $0.size, destinationKey: $0.key)
        }
      })
  }

  /// Copies versions onto their own keys, making them current; history is kept.
  private func restoreVersions(_ items: [CopyItem]) {
    guard !isTransferring, !items.isEmpty, let source = writeSource() else { return }
    let changes = changes(source)
    let initial = BatchDownloadProgress(
      completedFiles: 0, totalFiles: items.count, receivedBytes: 0,
      totalBytes: items.reduce(Int64.zero) { $0 + $1.size })
    start(.copy, name: items.count == 1 ? ObjectChanges.name(of: items[0].sourceKey) : nil, initial) {
      let result = await changes.copy(items, deletingSources: false) { self.update($0) }
      self.finishWrite()
      return Self.finished(result, "Restored")
    }
  }

  /// Loads the object's headers and tags, then opens `metadataTarget`.
  func requestEditMetadata(_ object: ObjectSummary) {
    guard canModify, let source = writeSource() else { return }
    Task {
      do {
        let details = try await model.repository.objectDetails(
          profile: source.profile, credentials: source.credentials, bucket: source.bucket, key: object.key,
          versionID: nil)
        metadataTarget = MetadataTarget(object: object, headers: ObjectHeaders(details), tags: details.tags)
      } catch {
        guard !isTransferring else { return }
        transfer = .finished(
          message: "Couldn't read the metadata of “\(ObjectChanges.name(of: object.key))”. "
            + AppModel.failure(for: error).message,
          succeeded: false, reveal: nil, failedKeys: [])
      }
    }
  }

  /// Replaces the headers (copy onto itself) and tags that changed; nil on success, else what went wrong.
  func saveMetadata(_ target: MetadataTarget, headers: ObjectHeaders, tags: [String: String]?) async
    -> String?
  {
    guard canModify, let source = writeSource() else { return modifyUnavailableReason ?? Self.notReady }
    let key = target.object.key
    let headersChanged = headers != target.headers
    let newTags = target.tags == nil || tags == target.tags ? nil : tags
    var wrote = false
    do {
      if headersChanged {
        try await model.repository.copyObject(
          profile: source.profile, credentials: source.credentials, bucket: source.bucket, sourceKey: key,
          sourceVersionID: nil, size: target.object.size, destinationKey: key, headers: headers)
        wrote = true
      }
      if let newTags {
        try await model.repository.putObjectTags(
          profile: source.profile, credentials: source.credentials, bucket: source.bucket, key: key,
          tags: newTags)
        wrote = true
      }
    } catch {
      if wrote { finishWrite() }
      return AppModel.failure(for: error).message
    }
    metadataTarget = nil
    if wrote { finishWrite() }
    return nil
  }

  // MARK: Share and favorites

  /// Opens the share sheet for the file row `id`, at its version.
  func share(_ id: BrowserRow.ID) {
    guard let row = fileRows(for: [id]).first, let object = row.object else { return }
    shareTarget = ShareTarget(object: object, versionID: row.versionID)
  }

  func toggleFavorite(_ location: S3Location) {
    Task {
      do {
        try await model.toggleFavorite(location)
      } catch {
        favoriteError = AppModel.failure(for: error).message
      }
    }
  }

  // MARK: Pasteboard

  func copyURIs(_ ids: Set<BrowserRow.ID>) {
    guard let bucket = model.browser.location?.bucket else { return }
    copy(ids.map { "s3://\(bucket)/\($0.keyString)" }.sorted())
  }

  func copyKeys(_ ids: Set<BrowserRow.ID>) {
    copy(ids.map(\.keyString).sorted())
  }

  func copy(_ lines: [String]) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
  }

  // MARK: Drag and drop

  func dragItem(_ row: BrowserRow) -> S3FileDrag {
    let source = model.downloadSource()
    return S3FileDrag(
      id: row.id, model: model, source: source, object: row.object, versionID: row.versionID,
      reference: reference(to: row, in: source))
  }

  /// Every listed item among `ids`: files also drag out to Finder, folders only move inside the app.
  func dragItems(_ ids: [BrowserRow.ID]) -> [S3FileDrag] {
    let source = model.downloadSource()
    return listedRows(for: Set(ids)).map {
      S3FileDrag(
        id: $0.id, model: model, source: source, object: $0.object, versionID: $0.versionID,
        reference: reference(to: $0, in: source))
    }
  }

  private func reference(to row: BrowserRow, in source: AppModel.DownloadSource?) -> S3ItemReference? {
    // Old versions stay where they are; drop targets check that changes are allowed.
    guard let source, row.versionID == nil else { return nil }
    return S3ItemReference(
      profileID: source.profile.id, bucket: source.bucket, isFolder: row.isFolder, key: row.id.key)
  }

  /// A drop on `folder`: browser items move there, Finder files and folders upload there. False when ignored.
  @discardableResult
  func accept(_ drops: [BrowserDrop], into folder: S3Location) -> Bool {
    let items = drops.compactMap { if case .item(let item) = $0 { item } else { nil } }
    guard items.isEmpty else { return moveDropped(items, into: folder) }
    let urls = drops.compactMap { if case .file(let url) = $0 { url } else { nil } }
    guard canModify, !isTransferring, !urls.isEmpty else { return false }
    upload(urls, into: folder)
    return true
  }

  private func moveDropped(_ items: [S3ItemReference], into destination: S3Location) -> Bool {
    guard canModify, let location = model.browser.location, let profileID = model.selectedProfileID else {
      return false
    }
    let ids = Set(
      items.filter { $0.profileID == profileID && $0.bucket == location.bucket }
        .map { BrowserRow.ID(isFolder: $0.isFolder, key: $0.key) })
    // Dropped back into their own folder, or a folder onto itself: nothing to do, like Finder.
    let destinationFolder = BrowserRow.ID(isFolder: true, key: Array(destination.prefix.utf8))
    guard destination.prefix != location.prefix, !ids.contains(destinationFolder) else { return false }
    let rows = listedRows(for: ids)
    guard !rows.isEmpty else { return false }
    Task {
      let target = MoveTarget(ids: Set(rows.map(\.id)), names: rows.map(\.name))
      if let problem = await move(target, to: destination) {
        transfer = .finished(message: problem, succeeded: false, reveal: nil, failedKeys: [])
      }
    }
    return true
  }
}

extension UTType {
  /// Files and folders dragged inside OpenBucket; declared in Info.plist.
  static let openBucketItem = UTType(exportedAs: "dev.openbucket.item")
}

/// A browser item dragged inside the app: enough to move it, none of its data.
struct S3ItemReference: Codable, Hashable, Sendable, Transferable {
  let profileID: UUID
  let bucket: String
  let isFolder: Bool
  /// Key bytes, like `BrowserRow.ID`, so keys that differ only in Unicode normalization stay apart.
  let key: [UInt8]

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .openBucketItem)
  }
}

/// What browser drop targets accept: the app's own items (moved) or files and folders from Finder (uploaded).
enum BrowserDrop: Transferable, Sendable {
  case item(S3ItemReference)
  case file(URL)

  static var transferRepresentation: some TransferRepresentation {
    // Own items first, so a drag that also offers a file for Finder is still taken as a move.
    ProxyRepresentation(importing: { (item: S3ItemReference) in BrowserDrop.item(item) })
    ProxyRepresentation(importing: { (url: URL) in BrowserDrop.file(url) })
  }
}

/// Drag-out to Finder: the object is downloaded when the drop asks for the file. Inside the app the drag also
/// carries `reference`, which drop targets use to move the item instead.
struct S3FileDrag: Transferable, Identifiable, Sendable {
  let id: BrowserRow.ID
  let model: AppModel
  let source: AppModel.DownloadSource?
  /// Nil for folders, which have no file representation.
  let object: ObjectSummary?
  let versionID: String?
  /// Nil when the item can't be moved (old versions, search results, no open bucket).
  let reference: S3ItemReference?

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .data) { item in
      guard let object = item.object, let source = item.source else {
        throw S3Failure(category: .unknown, message: "Open a bucket before dragging files.")
      }
      // ponytail: the private temp copy is left for the OS to purge because we can't tell when the
      // receiver has finished copying it; track and sweep on quit if temp usage ever matters.
      return SentTransferredFile(
        try await item.model.downloadToPrivateTemp(
          object, versionID: item.versionID, from: source, maximumBytes: .max))
    }
    .exportingCondition { $0.object != nil }
    .suggestedFileName { item in item.object.map { PreviewFileName.from(objectKey: $0.key) } }
    ProxyRepresentation(exporting: { (item: S3FileDrag) in
      guard let reference = item.reference else { throw CancellationError() }
      return reference
    })
    .exportingCondition { $0.reference != nil }
  }
}
