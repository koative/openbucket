import Synchronization

/// Runs `work` for each item with at most `width` running at once, starting them in order. Returns when every
/// started item has finished. After the calling task is cancelled no new item starts; running ones see the
/// cancellation through their own task.
func forEachConcurrently<Item: Sendable>(
  _ items: [Item], width: Int = 4, _ work: @escaping @Sendable (Item) async -> Void
) async {
  await withTaskGroup(of: Void.self) { group in
    for (index, item) in items.enumerated() {
      if index >= width { await group.next() }
      if Task.isCancelled { break }
      group.addTask { await work(item) }
    }
  }
}

/// Progress of a batch whose items run at once (see `forEachConcurrently`): each running item's bytes behind a
/// lock, reported as one total through `ProgressThrottle`. Finished items count at their listed size, failed ones
/// included; items stopped by cancellation don't count as finished.
final class BatchTally: Sendable {
  private struct State {
    var bytes: [Int64]
    var receivedBytes: Int64 = 0
    var completedFiles = 0
    var failures: [(index: Int, keys: [String])] = []
  }

  private let items: [(files: Int, bytes: Int64)]
  private let totalFiles: Int
  private let totalBytes: Int64
  private let state: Mutex<State>
  private let throttle: ProgressThrottle<BatchDownloadProgress>

  /// `items`: how many files and listed bytes each item stands for (a delete request covers many files).
  @MainActor init(
    _ items: [(files: Int, bytes: Int64)], progress: @escaping @MainActor (BatchDownloadProgress) -> Void
  ) {
    self.items = items
    totalFiles = items.reduce(0) { $0 + $1.files }
    totalBytes = items.reduce(0) { $0 + $1.bytes }
    state = Mutex(State(bytes: Array(repeating: 0, count: items.count)))
    throttle = ProgressThrottle(progress)
  }

  /// Bytes moved so far by the running item `index`.
  func send(_ index: Int, bytes: Int64) {
    update(index, bytes: min(bytes, items[index].bytes), files: 0, failedKeys: [])
  }

  /// Item `index` has finished; `failedKeys` are its files that failed.
  func finish(_ index: Int, failedKeys: [String] = []) {
    update(index, bytes: items[index].bytes, files: items[index].files, failedKeys: failedKeys)
  }

  /// Delivers the last progress; files done, and failed keys in item order.
  func result() async -> (done: Int, failedKeys: [String]) {
    await throttle.finish()
    let (completed, failures) = state.withLock { ($0.completedFiles, $0.failures) }
    let failedKeys = failures.sorted { $0.index < $1.index }.flatMap(\.keys)
    return (completed - failedKeys.count, failedKeys)
  }

  private func update(_ index: Int, bytes: Int64, files: Int, failedKeys: [String]) {
    state.withLock { state in
      state.receivedBytes += bytes - state.bytes[index]
      state.bytes[index] = bytes
      state.completedFiles += files
      if !failedKeys.isEmpty { state.failures.append((index, failedKeys)) }
      // Sent under the lock so updates reach the throttle in order.
      throttle.send(
        BatchDownloadProgress(
          completedFiles: state.completedFiles, totalFiles: totalFiles, receivedBytes: state.receivedBytes,
          totalBytes: totalBytes))
    }
  }
}
