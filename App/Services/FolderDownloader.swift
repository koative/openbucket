import Foundation
import OpenBucketCore

/// Downloads everything below an S3 folder into a new local folder, recreating the hierarchy.
@MainActor
struct FolderDownloader {
  let repository: any S3Repository

  /// Creates `<parent>/<folder name>` (" 2", " 3"… when taken) and downloads into it like `BatchDownloader`.
  /// Every path component is sanitised and made unique per directory.
  func download(
    _ location: S3Location,
    from source: AppModel.DownloadSource,
    into parent: URL,
    progress: @escaping @MainActor (BatchDownloadProgress) -> Void
  ) async throws -> BatchDownloadResult {
    // ponytail: whole listing held in memory, stream pages into the plan if folders reach millions of keys.
    var objects: [ObjectSummary] = []
    try await source.forEachObjectPage(repository, prefix: location.prefix) { page in
      objects += page.objects
      return true
    }
    let plan = Self.localPaths(for: objects, under: location.prefix)
    let root = try Self.createFolder(named: Self.folderName(location), in: parent)
    return await BatchDownloader(repository: repository).download(
      plan, into: root, from: source, progress: progress)
  }

  /// Sanitised relative local paths ("a/b (2)/c.txt") for every object below `prefix`, folder markers skipped.
  nonisolated static func localPaths(for objects: [ObjectSummary], under prefix: String) -> [DownloadItem] {
    var usedNames: [String: Set<String>] = [:]  // local directory path → lowercased names in it
    var folders: [String: String] = [:]  // S3 folder path → local directory path
    var plan: [DownloadItem] = []
    for object in objects {
      // Unicode scalars: a "/" fused with a combining mark is still a separator.
      guard let relative = relativeKey(object.key, under: prefix), relative.unicodeScalars.last != "/"
      else { continue }
      let parts = relative.unicodeScalars.split(separator: "/").map { String(String.UnicodeScalarView($0)) }
      guard let fileName = parts.last else { continue }
      var directory = ""
      var s3Folder = ""
      for part in parts.dropLast() {
        s3Folder += part + "/"
        if let known = folders[s3Folder] {
          directory = known
          continue
        }
        let name = BatchDownloadNames.uniqueName(for: part, usedNames: &usedNames[directory, default: []])
        directory += name + "/"
        folders[s3Folder] = directory
      }
      let name = BatchDownloadNames.uniqueName(for: fileName, usedNames: &usedNames[directory, default: []])
      plan.append(DownloadItem(object: object, path: directory + name))
    }
    return plan
  }

  /// The folder's last path component, or the bucket name at the root.
  private static func folderName(_ location: S3Location) -> String {
    let folder = location.prefix.hasSuffix("/") ? String(location.prefix.dropLast()) : location.prefix
    return PreviewFileName.from(objectKey: folder.isEmpty ? location.bucket : folder)
  }

  /// Creates `name`, or "name 2", "name 3"… when it already exists.
  private static func createFolder(named name: String, in parent: URL) throws -> URL {
    var number = 1
    while true {
      let folder = parent.appendingPathComponent(number == 1 ? name : "\(name) \(number)", isDirectory: true)
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
      } catch CocoaError.fileWriteFileExists {
        number += 1
      }
    }
  }
}
