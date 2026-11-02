import Foundation

/// Sizes under one folder prefix, accumulated page by page from `listAllObjects`.
public struct StorageSummary: Sendable {
  public struct Node: Identifiable, Sendable {
    /// The name's UTF-8 bytes plus "/" for folders, so a file and a folder with the same name, or names that
    /// differ only by Unicode normalization, stay distinct.
    public let id: [UInt8]
    public let name: String
    public let isFolder: Bool
    public let bytes: Int64
    public let objectCount: Int
  }

  public let prefix: String
  public private(set) var totalBytes: Int64 = 0
  public private(set) var objectCount: Int = 0
  /// Top 20 objects by size.
  public private(set) var largest: [ObjectSummary] = []
  private var nodes: [[UInt8]: Node] = [:]
  private var classes: [String: (bytes: Int64, objectCount: Int)] = [:]

  public init(prefix: String) {
    self.prefix = prefix
  }

  /// Adds objects listed under `prefix`; each child is the first path component after it
  /// ("x/…" → folder "x").
  public mutating func add(_ objects: [ObjectSummary]) {
    let prefixBytes = Array(prefix.utf8)
    for object in objects {
      totalBytes += object.size
      objectCount += 1
      let storageClass = object.storageClass ?? "STANDARD"
      classes[storageClass, default: (0, 0)].bytes += object.size
      classes[storageClass, default: (0, 0)].objectCount += 1
      guard object.id.starts(with: prefixBytes) else { continue }
      let rest = object.id.dropFirst(prefixBytes.count)
      guard !rest.isEmpty else { continue }  // the folder's own marker object
      let slash = rest.firstIndex(of: UInt8(ascii: "/"))
      let nameBytes = rest[..<(slash ?? rest.endIndex)]
      let id = Array(nameBytes) + (slash == nil ? [] : [UInt8(ascii: "/")])
      let old = nodes[id]
      nodes[id] = Node(
        id: id, name: old?.name ?? String(decoding: nameBytes, as: UTF8.self), isFolder: slash != nil,
        bytes: (old?.bytes ?? 0) + object.size, objectCount: (old?.objectCount ?? 0) + 1)
    }
    largest = Array((largest + objects).sorted { $0.size > $1.size }.prefix(20))
  }

  /// Direct children, largest first.
  public var children: [Node] {
    nodes.values.sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
  }

  /// Totals per storage class (nil class counts as "STANDARD"), largest first.
  public var storageClasses: [(name: String, bytes: Int64, objectCount: Int)] {
    classes.map { (name: $0.key, bytes: $0.value.bytes, objectCount: $0.value.objectCount) }
      .sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
  }
}
