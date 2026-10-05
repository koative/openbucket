import Foundation
import Observation
import OpenBucketCore

/// One-way sync on a finished comparison: copies new and changed files to one side and never deletes. Update
/// Mac moves each local file it replaces to the Trash; Update S3 overwrites (versioned buckets keep the old one).
@MainActor @Observable
final class FolderSync {
  typealias Status = BackupVerification.Status

  enum Direction: Sendable {
    /// Update S3: upload from the Mac.
    case toS3
    /// Update Mac: download from S3.
    case toMac
  }

  struct Item: Sendable {
    let relativePath: String
    let key: String
    /// Nil when the path can't be a file below the local folder ("..", empty components).
    let localURL: URL?
    /// Size on the side copied from.
    let size: Int64
    /// The target already has a file at this path, which gets replaced.
    let replaces: Bool
  }

  struct Plan: Sendable {
    let direction: Direction
    let items: [Item]
    /// Files on both sides that stay as they are: identical, unverified and unreadable.
    let leftAlone: [Status: Int]
    /// Files only on the target side; they stay.
    let targetOnly: Int

    var newFiles: Int { items.count(where: { !$0.replaces }) }
    var changedFiles: Int { items.count(where: \.replaces) }
  }

  let plan: Plan
  /// Finished files count at their listed size, failed ones included, so the totals are reached at the end.
  private(set) var progress: BatchDownloadProgress
  private(set) var transferredFiles = 0
  private(set) var failedPaths: [String] = []
  private(set) var isRunning = false
  private(set) var isFinished = false
  private(set) var wasCancelled = false

  @ObservationIgnored private let repository: any S3Repository
  @ObservationIgnored private let source: AppModel.DownloadSource
  @ObservationIgnored private let trash: @Sendable (URL) throws -> Void
  /// Internal so tests can await a run deterministically.
  @ObservationIgnored private(set) var task: Task<Void, Never>?

  init(
    plan: Plan,
    repository: any S3Repository,
    source: AppModel.DownloadSource,
    trash: @escaping @Sendable (URL) throws -> Void = {
      try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }
  ) {
    self.plan = plan
    progress = BatchDownloadProgress(
      completedFiles: 0, totalFiles: plan.items.count, receivedBytes: 0,
      totalBytes: plan.items.reduce(0) { $0 + $1.size })
    self.repository = repository
    self.source = source
    self.trash = trash
  }

  // MARK: Planning

  /// What `direction` copies, given the entries of a complete comparison of `localFolder` with `location`.
  nonisolated static func plan(
    _ direction: Direction, entries: [BackupVerification.Entry], location: S3Location, localFolder: URL
  ) -> Plan {
    let (new, targetOnly): (Status, Status) =
      direction == .toS3 ? (.missingInS3, .onlyInS3) : (.onlyInS3, .missingInS3)
    var items: [Item] = []
    var leftAlone: [Status: Int] = [:]
    var targetOnlyCount = 0
    for entry in entries {
      switch entry.status {
      case new, .different, .sizeMismatch:
        items.append(
          Item(
            relativePath: entry.relativePath, key: key(for: entry, under: location.prefix),
            localURL: localURL(for: entry.relativePath, in: localFolder),
            size: (direction == .toS3 ? entry.localSize : entry.remoteSize) ?? 0,
            replaces: entry.status != new))
      case targetOnly: targetOnlyCount += 1
      default: leftAlone[entry.status, default: 0] += 1
      }
    }
    return Plan(direction: direction, items: items, leftAlone: leftAlone, targetOnly: targetOnlyCount)
  }

  /// The existing object's exact key, else `prefix` + the relative path.
  nonisolated static func key(for entry: BackupVerification.Entry, under prefix: String) -> String {
    entry.remoteKey ?? prefix + entry.relativePath
  }

  /// `folder` plus each "/"-separated component; nil when a component would leave or alias the folder.
  nonisolated static func localURL(for relativePath: String, in folder: URL) -> URL? {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
    return components.reduce(folder) { $0.appending(component: String($1), directoryHint: .notDirectory) }
  }

  // MARK: Running

  /// Copies every planned file, four at a time, once. Update S3 refuses to run unless the connection allows
  /// changes.
  func start() {
    guard task == nil, plan.direction == .toMac || source.profile.allowsChanges else { return }
    isRunning = true
    let (items, direction, repository, source, trash) =
      (plan.items, plan.direction, repository, source, trash)
    let tally = BatchTally(items.map { (1, $0.size) }) { [weak self] in self?.progress = $0 }
    task = Task {
      await forEachConcurrently(Array(items.indices), width: 4) { index in
        do {
          try await Self.transfer(
            items[index], direction: direction, repository: repository, source: source, trash: trash
          ) { tally.send(index, bytes: $0) }
          tally.finish(index)
        } catch {
          if !Task.isCancelled { tally.finish(index, failedKeys: [items[index].relativePath]) }
        }
      }
      (transferredFiles, failedPaths) = await tally.result()
      wasCancelled = Task.isCancelled
      isRunning = false
      isFinished = true
    }
  }

  /// Stops starting files; running ones stop through their task. Files already copied stay copied.
  func cancel() {
    task?.cancel()
  }

  /// Update Mac downloads next to the destination first, so a failed or cancelled download leaves the local file
  /// in place; then it moves whatever is at the destination to the Trash and puts the download there.
  private nonisolated static func transfer(
    _ item: Item, direction: Direction, repository: any S3Repository, source: AppModel.DownloadSource,
    trash: @Sendable (URL) throws -> Void, progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    guard let localURL = item.localURL else {
      throw S3Failure(category: .localFile, message: "This path can't be saved on a Mac.")
    }
    guard direction == .toMac else {
      try await repository.uploadFile(
        profile: source.profile, credentials: source.credentials, bucket: source.bucket, key: item.key,
        from: localURL, headers: ObjectHeaders(contentType: ObjectChanges.contentType(forKey: item.key)),
        progress: progress)
      return
    }
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let staging = try fileManager.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: localURL, create: true)
    defer { try? fileManager.removeItem(at: staging) }
    let downloaded = staging.appending(component: localURL.lastPathComponent)
    try await repository.downloadObject(
      profile: source.profile, credentials: source.credentials, bucket: source.bucket, key: item.key,
      versionID: nil, to: downloaded, maximumBytes: .max, progress: progress)
    try Task.checkCancellation()
    // attributesOfItem doesn't follow symbolic links, so a link in the way is trashed, not its target.
    if let type = (try? fileManager.attributesOfItem(atPath: localURL.path))?[.type] as? FileAttributeType {
      guard type != .typeDirectory else {
        throw S3Failure(category: .localFile, message: "A folder on this Mac has the same name.")
      }
      try trash(localURL)
    }
    try fileManager.moveItem(at: downloaded, to: localURL)
  }
}
