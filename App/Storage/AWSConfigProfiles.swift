import Foundation

/// Profile names from the AWS CLI's shared config and credentials files. Secret values are never kept.
enum AWSConfigProfiles {
  struct Entry: Hashable, Identifiable {
    let name: String
    let region: String?
    let usesSSO: Bool
    var id: String { name }
  }

  /// Merged by name, `default` first, then by name. Always `~/.aws/*`: Soto's providers ignore
  /// `AWS_CONFIG_FILE`/`AWS_SHARED_CREDENTIALS_FILE`, so profiles only listed there couldn't connect.
  static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Entry] {
    func file(_ name: String) -> URL { home.appendingPathComponent(".aws/\(name)") }
    var settings: [String: [String: String]] = [:]
    for (header, values) in sections(file("config")) {
      let name: String
      if header == "default" {
        name = header
      } else if header.hasPrefix("profile ") {
        name = header.dropFirst(8).trimmingCharacters(in: .whitespaces)
      } else {
        continue  // sso-session, services, …
      }
      settings[name, default: [:]].merge(values) { $1 }
    }
    for (name, values) in sections(file("credentials")) {
      settings[name, default: [:]].merge(values) { old, _ in old }
    }
    return settings.filter { !$0.key.isEmpty }
      .map { name, values in
        Entry(
          name: name, region: values["region"],
          usesSSO: values["sso_session"] != nil || values["sso_start_url"] != nil)
      }
      .sorted { lhs, rhs in
        if (lhs.name == "default") != (rhs.name == "default") { return lhs.name == "default" }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
  }

  /// Section header → the non-secret keys we use; every other value (including keys) is dropped.
  private static func sections(_ url: URL) -> [String: [String: String]] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var result: [String: [String: String]] = [:]
    var current: String?
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") && line.hasSuffix("]") {
        let header = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        current = header
        if result[header] == nil { result[header] = [:] }
      } else if let current, let equals = line.firstIndex(of: "=") {
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        guard ["region", "sso_session", "sso_start_url"].contains(key) else { continue }
        result[current, default: [:]][key] = line[line.index(after: equals)...]
          .trimmingCharacters(in: .whitespaces)
      }
    }
    return result
  }
}
