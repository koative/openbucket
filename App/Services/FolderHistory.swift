import Foundation
import Observation
import OpenBucketCore

/// Every version and delete marker directly inside a folder, for "folder as of date" and deleted files.
@MainActor @Observable
final class FolderHistory {
  let location: S3Location
  /// Child folders, deduplicated, in S3 order.
  private(set) var prefixes: [String] = []
  /// Versions and delete markers in S3 order.
  private(set) var versions: [ObjectVersion] = []
  /// True when loading stopped at `limit` versions with more left to list.
  private(set) var truncated = false
  private(set) var isRunning = false
  private(set) var failure: S3Failure?

  @ObservationIgnored private let repository: any S3Repository
  @ObservationIgnored private let source: AppModel.DownloadSource
  @ObservationIgnored private let limit: Int
  /// Internal so tests can await a load deterministically.
  @ObservationIgnored private(set) var task: Task<Void, Never>?

  init(
    repository: any S3Repository,
    source: AppModel.DownloadSource,
    location: S3Location,
    limit: Int = 100_000
  ) {
    self.repository = repository
    self.source = source
    self.location = location
    self.limit = limit
  }

  /// Reloads all versions from scratch.
  func start() {
    cancel()
    prefixes = []
    versions = []
    truncated = false
    failure = nil
    isRunning = true
    task = Task {
      var seenPrefixes = Set<String>()
      do {
        try await source.forEachVersionPage(repository, prefix: location.prefix, delimiter: "/") { page in
          prefixes += page.prefixes.filter { seenPrefixes.insert($0).inserted }
          let room = limit - versions.count
          versions += page.versions.prefix(room)
          truncated =
            page.versions.count > room
            || (page.versions.count == room && (page.nextKeyMarker != nil || page.nextVersionIDMarker != nil))
          return !truncated
        }
      } catch {
        guard !Task.isCancelled else { return }
        failure = AppModel.failure(for: error)
      }
      isRunning = false
    }
  }

  /// Stops loading and keeps the versions loaded so far.
  func cancel() {
    task?.cancel()
    task = nil
    isRunning = false
  }
}

/// Every version and delete marker of one object key, newest first.
@MainActor @Observable
final class ObjectHistory {
  let key: String
  private(set) var versions: [ObjectVersion] = []
  /// True when loading stopped at `limit` versions with more left to list.
  private(set) var truncated = false
  private(set) var isRunning = false
  private(set) var failure: S3Failure?

  @ObservationIgnored private let repository: any S3Repository
  @ObservationIgnored private let source: AppModel.DownloadSource
  @ObservationIgnored private let limit: Int
  /// Internal so tests can await a load deterministically.
  @ObservationIgnored private(set) var task: Task<Void, Never>?

  init(repository: any S3Repository, source: AppModel.DownloadSource, key: String, limit: Int = 100_000) {
    self.repository = repository
    self.source = source
    self.key = key
    self.limit = limit
  }

  /// Reloads all versions from scratch.
  func start() {
    cancel()
    versions = []
    truncated = false
    failure = nil
    isRunning = true
    task = Task {
      do {
        try await source.forEachVersionPage(repository, prefix: key, delimiter: nil) { page in
          // S3 lists keys in byte order, so this key's versions (newest first) precede longer keys.
          let mine = page.versions.prefix { $0.key.utf8.elementsEqual(key.utf8) }
          let room = limit - versions.count
          versions += mine.prefix(room)
          truncated = mine.count > room
          return !truncated && mine.count == page.versions.count
        }
      } catch {
        guard !Task.isCancelled else { return }
        failure = AppModel.failure(for: error)
      }
      isRunning = false
    }
  }

  /// Stops loading and keeps the versions loaded so far.
  func cancel() {
    task?.cancel()
    task = nil
    isRunning = false
  }
}
