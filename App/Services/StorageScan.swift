import Foundation
import Observation
import OpenBucketCore

/// Sums sizes under a folder (per child folder and storage class) by listing every object below it.
@MainActor @Observable
final class StorageScan {
  let location: S3Location
  private(set) var summary: StorageSummary
  private(set) var scannedObjects = 0
  /// True when the scan stopped at `limit` objects with more left to list.
  private(set) var truncated = false
  private(set) var isRunning = false
  private(set) var failure: S3Failure?

  @ObservationIgnored private let repository: any S3Repository
  @ObservationIgnored private let source: AppModel.DownloadSource
  @ObservationIgnored private let limit: Int
  /// Internal so tests can await a scan deterministically.
  @ObservationIgnored private(set) var task: Task<Void, Never>?

  init(
    repository: any S3Repository,
    source: AppModel.DownloadSource,
    location: S3Location,
    limit: Int = 2_000_000
  ) {
    self.repository = repository
    self.source = source
    self.location = location
    self.limit = limit
    summary = StorageSummary(prefix: location.prefix)
  }

  /// Restarts the scan from scratch.
  func start() {
    cancel()
    summary = StorageSummary(prefix: location.prefix)
    scannedObjects = 0
    truncated = false
    failure = nil
    isRunning = true
    task = Task {
      do {
        try await source.forEachObjectPage(repository, prefix: location.prefix) { page in
          let room = limit - scannedObjects
          let objects = page.objects.prefix(room)
          summary.add(Array(objects))
          scannedObjects += objects.count
          truncated = page.objects.count > room || (page.objects.count == room && page.nextToken != nil)
          return !truncated
        }
      } catch {
        guard !Task.isCancelled else { return }
        failure = AppModel.failure(for: error)
      }
      isRunning = false
    }
  }

  /// Stops listing and keeps the totals scanned so far.
  func cancel() {
    task?.cancel()
    task = nil
    isRunning = false
  }
}
