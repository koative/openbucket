import Foundation
import OpenBucketCore
import UniformTypeIdentifiers

struct BrowserRow: Identifiable {
  /// Exact key bytes, so keys that differ only in Unicode normalization stay distinct.
  struct ID: Hashable, Sendable {
    let isFolder: Bool
    let key: [UInt8]

    var keyString: String { String(decoding: key, as: UTF8.self) }
  }

  static let thumbnailLimit: Int64 = 8 * 1024 * 1024
  static let previewLimit: Int64 = 64 * 1024 * 1024

  let id: ID
  let name: String
  let fullKey: String
  let object: ObjectSummary?
  /// Nil for the current object; set for rows from previous versions (Browse As Of, deleted files).
  let versionID: String?
  /// The key's latest entry is a delete marker; `object`/`versionID` are its newest real version.
  let isDeleted: Bool

  var isFolder: Bool { id.isFolder }
  var sortSize: Int64 { object?.size ?? -1 }
  var sortModified: Date { object?.lastModified ?? .distantPast }

  private var type: UTType? {
    isFolder ? .folder : UTType(filenameExtension: (fullKey as NSString).pathExtension)
  }

  var kindLabel: String {
    isFolder ? "Folder" : type?.localizedDescription ?? "File"
  }

  var sizeLabel: String? {
    object.map { $0.size.formatted(.byteCount(style: .file)) }
  }

  /// "name, kind, size" for VoiceOver.
  var accessibilityLabel: String {
    [name, isDeleted ? "deleted" : nil, kindLabel, sizeLabel].compactMap { $0 }.joined(separator: ", ")
  }

  var symbol: String {
    if isFolder { return "folder.fill" }
    guard let type else { return "doc" }
    if type.conforms(to: .image) { return "photo" }
    if type.conforms(to: .movie) { return "play.rectangle" }
    if type.conforms(to: .audio) { return "waveform" }
    if type.conforms(to: .pdf) { return "doc.richtext" }
    if type.conforms(to: .text) { return "doc.text" }
    return "doc"
  }

  var isVideo: Bool { !isFolder && type?.conforms(to: .movie) == true }

  var hasThumbnail: Bool {
    guard let object, object.size <= Self.thumbnailLimit, let type else { return false }
    return type.conforms(to: .image) || type.conforms(to: .movie)
  }

  init(prefix: String, parentPrefix: String) {
    id = ID(isFolder: true, key: Array(prefix.utf8))
    fullKey = prefix
    object = nil
    versionID = nil
    isDeleted = false
    var relative = Self.relativeBytes(prefix, to: parentPrefix)
    if relative.last == UInt8(ascii: "/") { relative.removeLast() }
    name = String(decoding: relative, as: UTF8.self)
  }

  init(object: ObjectSummary, parentPrefix: String, versionID: String? = nil, isDeleted: Bool = false) {
    id = ID(isFolder: false, key: object.id)
    fullKey = object.key
    self.object = object
    self.versionID = versionID
    self.isDeleted = isDeleted
    let relative = Self.relativeBytes(object.key, to: parentPrefix)
    name = relative.isEmpty ? "(folder marker)" : String(decoding: relative, as: UTF8.self)
  }

  /// `key` up to and including its last "/" ("a/b/c.txt" → "a/b/"), byte-wise like S3.
  static func folder(of key: String) -> String {
    let bytes = Array(key.utf8)
    let end = bytes.lastIndex(of: UInt8(ascii: "/")).map { $0 + 1 } ?? 0
    return String(decoding: bytes[..<end], as: UTF8.self)
  }

  /// Byte-wise, so a combining mark after "/" can't shift the cut.
  private static func relativeBytes(_ key: String, to parent: String) -> ArraySlice<UInt8> {
    let bytes = ArraySlice(key.utf8)
    return bytes.starts(with: parent.utf8) ? bytes.dropFirst(parent.utf8.count) : bytes
  }
}

/// "1 file", "3 files", "1,204 folders".
func countLabel(_ count: Int, _ noun: String) -> String {
  "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")"
}

extension S3Location {
  /// The folder's name, or the bucket at its root, for UI copy like “Search All of “photos””.
  var displayName: String { prefix.split(separator: "/").last.map(String.init) ?? bucket }
}
