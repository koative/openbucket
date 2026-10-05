import CryptoKit
import Foundation
import Observation
import OpenBucketCore

/// Compares a local folder with an S3 folder by path, size and MD5-based ETag. Read-only on both sides.
@MainActor @Observable
final class BackupVerification {
  enum Status: String, Sendable {
    case identical
    /// Same size, but the MD5 differs from a single-part ETag (or the ETag isn't an MD5, e.g. SSE-KMS).
    case different
    case sizeMismatch
    case missingInS3
    case onlyInS3
    /// Same size, but the ETag can't prove the content (unknown multipart part size or no ETag).
    case unverified
    /// The local file couldn't be read (permissions, deleted mid-run, offline cloud file); not compared.
    case unreadable
  }

  struct Entry: Identifiable, Sendable {
    /// NFC-normalised path relative to both folders, "/"-separated.
    let relativePath: String
    let status: Status
    let localSize: Int64?
    let remoteSize: Int64?
    var id: String { relativePath }
  }

  let location: S3Location
  let localFolder: URL
  private(set) var entries: [Entry] = []
  private(set) var checkedFiles = 0
  private(set) var totalFiles = 0
  private(set) var isRunning = false
  private(set) var failure: S3Failure?

  @ObservationIgnored private let repository: any S3Repository
  @ObservationIgnored private let source: AppModel.DownloadSource
  /// Internal so tests can await a run deterministically.
  @ObservationIgnored private(set) var task: Task<Void, Never>?

  init(
    repository: any S3Repository,
    source: AppModel.DownloadSource,
    location: S3Location,
    localFolder: URL
  ) {
    self.repository = repository
    self.source = source
    self.location = location
    self.localFolder = localFolder
  }

  /// Restarts the comparison from scratch.
  func start() {
    cancel()
    entries = []
    checkedFiles = 0
    totalFiles = 0
    failure = nil
    isRunning = true
    task = Task {
      do {
        let local = try await Self.localFiles(in: localFolder)
        var remote: [String: ObjectSummary] = [:]
        try await source.forEachObjectPage(repository, prefix: location.prefix) { page in
          for object in page.objects {
            guard let path = relativeKey(object.key, under: location.prefix), !path.isEmpty,
              path.unicodeScalars.last != "/", !Self.isFinderJunk(path)
            else { continue }
            remote[path.precomposedStringWithCanonicalMapping] = object
          }
          return true
        }
        let paths = Set(local.keys).union(remote.keys).sorted {
          $0.localizedStandardCompare($1) == .orderedAscending
        }
        totalFiles = paths.count
        for path in paths {
          let file = local[path]
          let object = remote[path]
          let status: Status
          switch (file, object) {
          case (nil, _): status = .onlyInS3
          case (_, nil): status = .missingInS3
          case (let file?, let object?) where file.size != object.size: status = .sizeMismatch
          case (let file?, let object?):
            do {
              var matches: Bool?
              if let eTag = object.eTag {
                matches = try await Self.matches(file.url, size: file.size, eTag: eTag)
              }
              status = matches.map { $0 ? .identical : .different } ?? .unverified
            } catch let error as CancellationError {
              throw error
            } catch {
              status = .unreadable
            }
            try Task.checkCancellation()
          }
          entries.append(
            Entry(relativePath: path, status: status, localSize: file?.size, remoteSize: object?.size))
          checkedFiles += 1
        }
      } catch {
        guard !Task.isCancelled else { return }
        failure = AppModel.failure(for: error)
      }
      isRunning = false
    }
  }

  /// Stops comparing and keeps the entries checked so far.
  func cancel() {
    task?.cancel()
    task = nil
    isRunning = false
  }

  /// The entries as RFC 4180 CSV with a header row. Values a spreadsheet would run as a formula get a
  /// leading `'`, since S3 keys are attacker-controlled.
  func csv() -> String {
    func field(_ value: String) -> String {
      // Scalars, not Characters: "\r\n" is one Character.
      let value =
        value.unicodeScalars.first.map { "=+-@\t\r".unicodeScalars.contains($0) } == true
        ? "'" + value : value
      return value.contains { $0 == "," || $0 == "\"" || $0.isNewline }
        ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
    }
    let rows = entries.map { entry in
      [
        entry.relativePath, entry.status.rawValue, entry.localSize.map(String.init) ?? "",
        entry.remoteSize.map(String.init) ?? "",
      ].map(field).joined(separator: ",")
    }
    return (["path,status,local_size,remote_size"] + rows).map { $0 + "\r\n" }.joined()
  }

  /// `.DS_Store` and AppleDouble `._*` files Finder leaves behind; skipped on both sides.
  private nonisolated static func isFinderJunk(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent
    return name == ".DS_Store" || name.hasPrefix("._")
  }

  /// Regular files below `folder` by NFC relative path; Finder junk and symbolic links are skipped.
  @concurrent private nonisolated static func localFiles(in folder: URL) async throws -> [String: LocalFile] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      let enumerator = FileManager.default.enumerator(atPath: folder.path)
    else {
      throw S3Failure(category: .localFile, message: "The local folder couldn't be read.")
    }
    var files: [String: LocalFile] = [:]
    while let path = enumerator.nextObject() as? String {
      try Task.checkCancellation()
      guard !isFinderJunk(path), let attributes = enumerator.fileAttributes,
        attributes[.type] as? FileAttributeType == .typeRegular
      else { continue }
      let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
      files[path.precomposedStringWithCanonicalMapping] = (folder.appendingPathComponent(path), size)
    }
    return files
  }

  /// Whether the file reproduces `eTag`: a plain MD5, or a multipart "md5-N" for a guessed part size.
  /// Nil when no tried part size fits the multipart ETag, so the content can't be proven either way.
  @concurrent private nonisolated static func matches(_ file: URL, size: Int64, eTag: String) async throws
    -> Bool?
  {
    let tag = eTag.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
    let pieces = tag.split(separator: "-")
    let mebibyte: Int64 = 1 << 20
    var partSizes: [Int64] = []  // empty: single-part
    if pieces.count == 2 {
      guard let parts = Int64(pieces[1]), parts > 0 else { return nil }
      let implied = ((size + parts - 1) / parts + mebibyte - 1) / mebibyte * mebibyte
      for partSize in [8, 16, 5, 15, 32, 64].map({ $0 * mebibyte }) + [implied]
      where partSize > 0 && (size + partSize - 1) / partSize == parts && !partSizes.contains(partSize) {
        partSizes.append(partSize)
      }
      guard !partSizes.isEmpty else { return nil }
    } else if pieces.count != 1 {
      return nil
    }

    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var whole = Insecure.MD5()
    // Part sizes are whole MiB, so part boundaries always fall on 1 MiB chunk boundaries.
    var running = partSizes.map { _ in (part: Insecure.MD5(), digests: Data()) }
    var offset: Int64 = 0
    while let chunk = try handle.read(upToCount: Int(mebibyte)), !chunk.isEmpty {
      try Task.checkCancellation()
      offset += Int64(chunk.count)
      if partSizes.isEmpty { whole.update(data: chunk) }
      for index in running.indices {
        running[index].part.update(data: chunk)
        if offset % partSizes[index] == 0 {
          running[index].digests.append(contentsOf: running[index].part.finalize())
          running[index].part = Insecure.MD5()
        }
      }
    }
    if partSizes.isEmpty { return hex(whole.finalize()) == tag }
    for index in running.indices {
      if offset % partSizes[index] != 0 {
        running[index].digests.append(contentsOf: running[index].part.finalize())
      }
      if hex(Insecure.MD5.hash(data: running[index].digests)) + "-\(pieces[1])" == tag { return true }
    }
    return nil
  }

  private nonisolated static func hex(_ digest: some Sequence<UInt8>) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  private typealias LocalFile = (url: URL, size: Int64)
}
