import Foundation
import OpenBucketCore

/// `receivedBytes` counts finished files (including failed ones) at their listed size, so it reaches
/// `totalBytes` when the batch ends.
struct BatchDownloadProgress: Equatable {
  let completedFiles: Int
  let totalFiles: Int
  let receivedBytes: Int64
  let totalBytes: Int64
}

struct BatchDownloadResult {
  let directory: URL
  let downloaded: Int
  let failedKeys: [String]
  let cancelled: Bool
}

/// One file of a download: `path` is relative to the destination folder; nil `versionID` = current version.
struct DownloadItem {
  let object: ObjectSummary
  let path: String
  var versionID: String? = nil
}

@MainActor
struct BatchDownloader {
  let repository: any S3Repository

  /// `versionIDs` maps an object's `id` (key bytes) to the version to fetch; absent = current version.
  func download(
    _ objects: [ObjectSummary],
    versionIDs: [[UInt8]: String] = [:],
    from source: AppModel.DownloadSource,
    into parentDirectory: URL,
    progress: @escaping @MainActor (BatchDownloadProgress) -> Void
  ) async throws -> BatchDownloadResult {
    let directory = parentDirectory.appendingPathComponent(
      "OpenBucket Export-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    var usedNames = Set<String>()
    let plan = objects.map {
      DownloadItem(
        object: $0, path: BatchDownloadNames.uniqueName(for: $0.key, usedNames: &usedNames),
        versionID: versionIDs[$0.id])
    }
    return await download(plan, into: directory, from: source, progress: progress)
  }

  /// Downloads `plan` below `root`, four files at a time, creating subfolders. Per-file failures (including paths
  /// that would leave `root`) land in `failedKeys`; cancelling the task returns `cancelled: true`.
  func download(
    _ plan: [DownloadItem],
    into root: URL,
    from source: AppModel.DownloadSource,
    progress: @escaping @MainActor (BatchDownloadProgress) -> Void
  ) async -> BatchDownloadResult {
    let rootPath = root.standardized.path + "/"
    let tally = BatchTally(plan.map { (files: 1, bytes: $0.object.size) }, progress: progress)
    await forEachConcurrently(Array(plan.indices)) { [repository] index in
      let item = plan[index]
      let destination = root.appendingPathComponent(item.path)
      guard destination.standardized.path.hasPrefix(rootPath) else {
        tally.finish(index, failedKeys: [item.object.key])
        return
      }
      do {
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await repository.downloadObject(
          profile: source.profile, credentials: source.credentials, bucket: source.bucket,
          key: item.object.key, versionID: item.versionID, to: destination, maximumBytes: .max
        ) { tally.send(index, bytes: $0) }
        tally.finish(index)
      } catch {
        if !Task.isCancelled { tally.finish(index, failedKeys: [item.object.key]) }
      }
    }
    let result = await tally.result()
    return BatchDownloadResult(
      directory: root, downloaded: result.done, failedKeys: result.failedKeys, cancelled: Task.isCancelled)
  }
}

enum BatchDownloadNames {
  /// Names are compared case-insensitively (String equality already ignores normalization), like APFS.
  static func uniqueName(for key: String, usedNames: inout Set<String>) -> String {
    var name = PreviewFileName.from(objectKey: key)
    var number = 1
    while !usedNames.insert(name.lowercased()).inserted {
      number += 1
      name = PreviewFileName.from(objectKey: key, suffix: " (\(number))")
    }
    return name
  }
}

/// Forwards progress reported from any thread to the main actor, newest value only, at most ~10 times a
/// second. `finish()` delivers the last value and waits until it has been delivered.
final class ProgressThrottle<Value: Sendable>: Sendable {
  private let continuation: AsyncStream<Value>.Continuation
  private let delivery: Task<Void, Never>

  @MainActor init(_ deliver: @escaping @MainActor (Value) -> Void) {
    let (stream, continuation) = AsyncStream.makeStream(of: Value.self, bufferingPolicy: .bufferingNewest(1))
    self.continuation = continuation
    delivery = Task { @MainActor in
      for await value in stream {
        deliver(value)
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  func send(_ value: Value) {
    continuation.yield(value)
  }

  func finish() async {
    continuation.finish()
    await delivery.value
  }
}
