import Darwin
import Foundation
import OpenBucketCore

/// profiles.json existed but couldn't be decoded; it was moved aside to `backupName` in the same directory.
struct UnreadableProfilesError: Error {
  let backupName: String
}

actor ProfileStore {
  private let fileURL: URL

  init(fileURL: URL) {
    self.fileURL = fileURL
  }

  func load() throws -> [ConnectionProfile] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    let data = try Data(contentsOf: fileURL)
    do {
      return try JSONDecoder().decode([ConnectionProfile].self, from: data)
    } catch {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyyMMdd-HHmmss"
      let backupName = "profiles.unreadable-\(formatter.string(from: Date())).json"
      try FileManager.default.moveItem(
        at: fileURL, to: fileURL.deletingLastPathComponent().appendingPathComponent(backupName))
      throw UnreadableProfilesError(backupName: backupName)
    }
  }

  func save(_ profiles: [ConnectionProfile]) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let temporaryURL = directory.appendingPathComponent(".profiles-\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    try encoder.encode(profiles).write(to: temporaryURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
    guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
  }
}
