import Foundation
import Observation
import OpenBucketCore

/// Finds objects anywhere below a folder whose key (relative to the folder) contains a query.
@MainActor @Observable
final class DeepSearch {
  let location: S3Location
  private(set) var results: [ObjectSummary] = []
  private(set) var scanned = 0
  /// True when the search stopped at `scanLimit` objects or `matchLimit` results with more left to list.
  private(set) var truncated = false
  private(set) var isRunning = false
  private(set) var failure: S3Failure?

  @ObservationIgnored private let repository: any S3Repository
  @ObservationIgnored private let source: AppModel.DownloadSource
  @ObservationIgnored private let scanLimit: Int
  @ObservationIgnored private let matchLimit: Int
  /// Internal so tests can await a search deterministically.
  @ObservationIgnored private(set) var task: Task<Void, Never>?

  init(
    repository: any S3Repository,
    source: AppModel.DownloadSource,
    location: S3Location,
    scanLimit: Int = 200_000,
    matchLimit: Int = 10_000
  ) {
    self.repository = repository
    self.source = source
    self.location = location
    self.scanLimit = scanLimit
    self.matchLimit = matchLimit
  }

  /// Cancels any running search and starts one for `query` (case- and diacritic-insensitive substring).
  /// A blank query just clears the results.
  func run(query: String) {
    cancel()
    results = []
    scanned = 0
    truncated = false
    failure = nil
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return }
    isRunning = true
    task = Task {
      do {
        try await source.forEachObjectPage(repository, prefix: location.prefix) { page in
          var found: [ObjectSummary] = []
          var count = scanned
          var stopped = false
          for object in page.objects {
            guard count < scanLimit, results.count + found.count < matchLimit else {
              stopped = true
              break
            }
            count += 1
            if let name = relativeKey(object.key, under: location.prefix),
              name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            {
              found.append(object)
            }
          }
          scanned = count
          results += found
          let full = scanned == scanLimit || results.count == matchLimit
          truncated = stopped || (full && page.nextToken != nil)
          return !truncated
        }
      } catch {
        guard !Task.isCancelled else { return }
        failure = AppModel.failure(for: error)
      }
      isRunning = false
    }
  }

  /// Stops listing and keeps the results found so far.
  func cancel() {
    task?.cancel()
    task = nil
    isRunning = false
  }
}
