import Foundation
import OpenBucketCore
import UniformTypeIdentifiers

/// One upload: a local file, or the marker of an empty folder (`source` nil).
struct UploadItem: Equatable, Sendable {
  let source: URL?
  var key: String
  let size: Int64
}

/// One server-side copy. Moves and renames delete `sourceKey` once its copy succeeded.
struct CopyItem: Equatable, Sendable {
  let sourceKey: String
  var sourceVersionID: String? = nil
  let size: Int64
  var destinationKey: String
}

struct ChangeResult: Equatable {
  let done: Int
  let failedKeys: [String]
  let cancelled: Bool
}

typealias ConflictAnswer = (choice: ConflictChoice, applyToAll: Bool)

/// Plans and runs writes for one connection, four objects at a time, like `BatchDownloader`.
@MainActor
struct ObjectChanges {
  let repository: any S3Repository
  let source: AppModel.DownloadSource

  // MARK: Planning

  /// Uploads for a local file or folder put into `prefix`. Folders recurse without hidden files and symlinks;
  /// an empty folder becomes a folder marker so it still shows up.
  nonisolated static func uploadItems(for url: URL, into prefix: String) throws -> [UploadItem] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
    var items: [UploadItem] = []
    /// True when `url` added anything.
    func walk(_ url: URL, key: String) throws -> Bool {
      let values = try url.resourceValues(forKeys: Set(keys))
      if values.isSymbolicLink == true { return false }
      if values.isDirectory == true {
        let folder = key + "/"
        let children = try FileManager.default.contentsOfDirectory(
          at: url, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)
        var added = false
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
          if try walk(child, key: folder + child.lastPathComponent) { added = true }
        }
        if !added { items.append(UploadItem(source: nil, key: folder, size: 0)) }
        return true
      }
      guard values.isRegularFile == true else { return false }
      items.append(UploadItem(source: url, key: key, size: Int64(values.fileSize ?? 0)))
      return true
    }
    do {
      // A dropped alias or symlink means its target; links inside folders are skipped.
      _ = try walk(url.resolvingSymlinksInPath(), key: prefix + url.lastPathComponent)
    } catch {
      throw S3Failure(
        category: .localFile, message: "“\(url.lastPathComponent)” couldn't be read.",
        technicalDetail: error.localizedDescription)
    }
    return items
  }

  nonisolated static func contentType(forKey key: String) -> String {
    UTType(filenameExtension: (key as NSString).pathExtension)?.preferredMIMEType
      ?? "application/octet-stream"
  }

  /// The last path component of a file key.
  nonisolated static func name(of key: String) -> String {
    String(decoding: key.utf8.dropFirst(BrowserRow.folder(of: key).utf8.count), as: UTF8.self)
  }

  /// The folder holding a file or folder key ("a/b/c.txt" and "a/b/c/" → "a/b/").
  nonisolated static func parentPrefix(of key: String) -> String {
    var bytes = Array(key.utf8)
    if bytes.last == UInt8(ascii: "/") { bytes.removeLast() }
    return BrowserRow.folder(of: String(decoding: bytes, as: UTF8.self))
  }

  nonisolated static func isMarker(_ key: String) -> Bool {
    key.utf8.last == UInt8(ascii: "/")
  }

  /// What to list to find a top-level item's conflicts: the folder, or for a file every key starting with its
  /// stem, so Keep Both's "name 2.ext" candidates are known too.
  nonisolated static func listingPrefix(forKey key: String) -> String {
    if isMarker(key) { return key }
    let name = name(of: key) as NSString
    return BrowserRow.folder(of: key)
      + (name.pathExtension.isEmpty ? name as String : name.deletingPathExtension)
  }

  /// `key` with " 2", " 3"… before its extension: the first not in `taken` (exact bytes, like S3).
  nonisolated static func keepBothKey(_ key: String, taken: Set<[UInt8]>) -> String {
    let name = name(of: key) as NSString
    let stem = name.pathExtension.isEmpty ? name as String : name.deletingPathExtension
    let suffix = name.pathExtension.isEmpty ? "" : "." + name.pathExtension
    var number = 2
    while true {
      let candidate = BrowserRow.folder(of: key) + "\(stem) \(number)\(suffix)"
      if !taken.contains(Array(candidate.utf8)) { return candidate }
      number += 1
    }
  }

  /// `key` moved from below `old` to below `new`; nil when it isn't below `old`.
  nonisolated static func rebase(_ key: String, from old: String, to new: String) -> String? {
    relativeKey(key, under: old).map { new + $0 }
  }

  /// Copies that move `objects` from below `old` to below `new`, leaving out objects that wouldn't move.
  nonisolated static func copyItems(_ objects: [ObjectSummary], from old: String, to new: String)
    -> [CopyItem]
  {
    objects.compactMap { object in
      guard let key = rebase(object.key, from: old, to: new), !key.utf8.elementsEqual(object.key.utf8) else {
        return nil
      }
      return CopyItem(sourceKey: object.key, size: object.size, destinationKey: key)
    }
  }

  /// Why `rows` can't move into the folder `prefix`, or nil.
  nonisolated static func moveProblem(_ rows: [BrowserRow], to prefix: String) -> String? {
    if let folder = rows.first(where: { $0.isFolder && prefix.utf8.starts(with: $0.fullKey.utf8) }) {
      return "“\(folder.name)” can't be moved into itself."
    }
    if rows.allSatisfy({ parentPrefix(of: $0.fullKey).utf8.elementsEqual(prefix.utf8) }) {
      return rows.count == 1
        ? "“\(rows[0].name)” is already in that folder." : "These items are already in that folder."
    }
    return nil
  }

  /// Why `name` can't name a file or folder, or nil.
  nonisolated static func nameProblem(_ name: String) -> String? {
    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a name." }
    if name.unicodeScalars.contains("/") { return "Names can't contain “/”." }
    if name == "." || name == ".." { return "“\(name)” can't be used as a name." }
    return nil
  }

  /// The final key of each planned key. Keys in `existing` go to `ask` (with how many conflicts follow) unless
  /// an earlier answer applied to all: Replace keeps the key, Keep Both picks a free name, Skip gives nil.
  /// Folder markers merge without asking. Nil when `ask` returns nil (cancelled).
  static func resolveConflicts(
    _ keys: [String], existing: Set<[UInt8]>,
    ask: (_ key: String, _ remaining: Int) async -> ConflictAnswer?
  ) async -> [String?]? {
    let conflicts = keys.filter { !isMarker($0) && existing.contains(Array($0.utf8)) }.count
    var taken = existing.union(keys.map { Array($0.utf8) })
    var asked = 0
    var always: ConflictChoice?
    var resolved: [String?] = []
    for key in keys {
      guard !isMarker(key), existing.contains(Array(key.utf8)) else {
        resolved.append(key)
        continue
      }
      asked += 1
      let choice: ConflictChoice
      if let always {
        choice = always
      } else {
        guard let answer = await ask(key, conflicts - asked) else { return nil }
        choice = answer.choice
        if answer.applyToAll { always = choice }
      }
      switch choice {
      case .replace:
        resolved.append(key)
      case .skip:
        resolved.append(nil)
      case .keepBoth:
        let renamed = keepBothKey(key, taken: taken)
        taken.insert(Array(renamed.utf8))
        resolved.append(renamed)
      }
    }
    return resolved
  }

  /// A file row's object, or everything listed below a folder row (its marker included).
  func objects(in row: BrowserRow) async throws -> [ObjectSummary] {
    if let object = row.object { return [object] }
    var objects: [ObjectSummary] = []
    try await source.forEachObjectPage(repository, prefix: row.fullKey) { page in
      objects += page.objects
      return true
    }
    return objects
  }

  /// Keys starting with `prefix`, as exact bytes.
  func existingKeys(under prefix: String) async throws -> Set<[UInt8]> {
    var keys = Set<[UInt8]>()
    try await source.forEachObjectPage(repository, prefix: prefix) { page in
      keys.formUnion(page.objects.map(\.id))
      return true
    }
    return keys
  }

  /// Uploads for `urls` into `prefix` with conflicts resolved; nil when the prompt was cancelled.
  func uploadPlan(
    _ urls: [URL], into prefix: String, ask: (_ key: String, _ remaining: Int) async -> ConflictAnswer?
  ) async throws -> [UploadItem]? {
    var items: [UploadItem] = []
    var existing = Set<[UInt8]>()
    for url in urls {
      let planned = try await Task.detached { try Self.uploadItems(for: url, into: prefix) }.value
      try Task.checkCancellation()
      guard !planned.isEmpty else { continue }
      let top = prefix + url.lastPathComponent
      let isFile =
        planned.count == 1 && planned[0].source != nil && planned[0].key.utf8.elementsEqual(top.utf8)
      existing.formUnion(try await existingKeys(under: Self.listingPrefix(forKey: isFile ? top : top + "/")))
      items += planned
    }
    guard let keys = await Self.resolveConflicts(items.map(\.key), existing: existing, ask: ask) else {
      return nil
    }
    return zip(items, keys).compactMap { item, key in
      guard let key else { return nil }
      var item = item
      item.key = key
      return item
    }
  }

  /// Copies that move `rows` into the folder `prefix` with conflicts resolved; nil when the prompt was
  /// cancelled. Check `moveProblem` first.
  func movePlan(
    _ rows: [BrowserRow], to prefix: String, ask: (_ key: String, _ remaining: Int) async -> ConflictAnswer?
  ) async throws -> [CopyItem]? {
    var items: [CopyItem] = []
    var existing = Set<[UInt8]>()
    for row in rows {
      let parent = Self.parentPrefix(of: row.fullKey)
      guard let top = Self.rebase(row.fullKey, from: parent, to: prefix),
        !top.utf8.elementsEqual(row.fullKey.utf8)
      else { continue }
      existing.formUnion(try await existingKeys(under: Self.listingPrefix(forKey: top)))
      items += Self.copyItems(try await objects(in: row), from: parent, to: prefix)
    }
    guard let keys = await Self.resolveConflicts(items.map(\.destinationKey), existing: existing, ask: ask)
    else {
      return nil
    }
    return zip(items, keys).compactMap { item, key in
      guard let key else { return nil }
      var item = item
      item.destinationKey = key
      return item
    }
  }

  /// Copies that rename `row` to `newKey` (a folder's ends in "/"); nil when that name is taken, since renames
  /// never replace.
  func renamePlan(_ row: BrowserRow, to newKey: String) async throws -> [CopyItem]? {
    let taken =
      if row.isFolder {
        try await exists(prefix: newKey)
      } else {
        try await existingKeys(under: newKey).contains(Array(newKey.utf8))
      }
    guard !taken else { return nil }
    return Self.copyItems(try await objects(in: row), from: row.fullKey, to: newKey)
  }

  /// Some key starts with `prefix`; one request.
  func exists(prefix: String) async throws -> Bool {
    try await !repository.listAllObjects(
      profile: source.profile, credentials: source.credentials, bucket: source.bucket, prefix: prefix,
      continuationToken: nil
    ).objects.isEmpty
  }

  // MARK: Running

  func upload(
    _ items: [UploadItem], progress: @escaping @MainActor (BatchDownloadProgress) -> Void
  ) async -> ChangeResult {
    await run(items.map { (key: $0.key, size: $0.size) }, progress: progress) {
      [repository, source] index, report in
      let item = items[index]
      if let file = item.source {
        try await repository.uploadFile(
          profile: source.profile, credentials: source.credentials, bucket: source.bucket, key: item.key,
          from: file, headers: ObjectHeaders(contentType: Self.contentType(forKey: item.key)),
          progress: report)
      } else {
        try await repository.putEmptyObject(
          profile: source.profile, credentials: source.credentials, bucket: source.bucket, key: item.key)
      }
    }
  }

  /// Copies each item; with `deletingSources` (moves, renames) its source is deleted once the copy succeeded.
  func copy(
    _ items: [CopyItem], deletingSources: Bool, progress: @escaping @MainActor (BatchDownloadProgress) -> Void
  ) async -> ChangeResult {
    // ponytail: one delete request per moved object; batch them if moving thousands feels slow.
    await run(items.map { (key: $0.sourceKey, size: $0.size) }, progress: progress) {
      [repository, source] index, _ in
      let item = items[index]
      try await repository.copyObject(
        profile: source.profile, credentials: source.credentials, bucket: source.bucket,
        sourceKey: item.sourceKey, sourceVersionID: item.sourceVersionID, size: item.size,
        destinationKey: item.destinationKey, headers: nil)
      guard deletingSources else { return }
      let failures = try await repository.deleteObjects(
        profile: source.profile, credentials: source.credentials, bucket: source.bucket,
        keys: [item.sourceKey])
      if let failure = failures.first { throw S3Failure(category: .service, message: failure.message) }
    }
  }

  /// Deletes 1000 keys per request, up to four requests at a time; keys the server rejects, or of a failed
  /// request, land in `failedKeys`.
  func delete(
    _ objects: [ObjectSummary], progress: @escaping @MainActor (BatchDownloadProgress) -> Void
  ) async -> ChangeResult {
    let batches = stride(from: 0, to: objects.count, by: 1000).map {
      Array(objects[$0..<min($0 + 1000, objects.count)])
    }
    let tally = BatchTally(
      batches.map { (files: $0.count, bytes: $0.reduce(Int64.zero) { $0 + $1.size }) }, progress: progress)
    await forEachConcurrently(Array(batches.indices)) { [repository, source] index in
      let keys = batches[index].map(\.key)
      do {
        let failures = try await repository.deleteObjects(
          profile: source.profile, credentials: source.credentials, bucket: source.bucket, keys: keys)
        tally.finish(index, failedKeys: failures.map(\.key))
      } catch {
        if !Task.isCancelled { tally.finish(index, failedKeys: keys) }
      }
    }
    let result = await tally.result()
    return ChangeResult(done: result.done, failedKeys: result.failedKeys, cancelled: Task.isCancelled)
  }

  /// Runs `body` for each item, four at a time, reporting progress like `BatchDownloader`: failures land in
  /// `failedKeys`, cancelling starts no further items and cancels the running ones.
  private func run(
    _ items: [(key: String, size: Int64)],
    progress: @escaping @MainActor (BatchDownloadProgress) -> Void,
    _ body:
      @escaping @Sendable (_ index: Int, _ report: @escaping @Sendable (Int64) -> Void) async throws -> Void
  ) async -> ChangeResult {
    let tally = BatchTally(items.map { (files: 1, bytes: $0.size) }, progress: progress)
    await forEachConcurrently(Array(items.indices)) { index in
      do {
        try await body(index) { tally.send(index, bytes: $0) }
        tally.finish(index)
      } catch {
        if !Task.isCancelled { tally.finish(index, failedKeys: [items[index].key]) }
      }
    }
    let result = await tally.result()
    return ChangeResult(done: result.done, failedKeys: result.failedKeys, cancelled: Task.isCancelled)
  }
}
