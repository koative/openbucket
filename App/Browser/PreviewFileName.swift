import Foundation

enum PreviewFileName {
  /// One safe local path component for the last segment of `objectKey`, at most 120 UTF-8 bytes.
  /// `suffix` (e.g. " (2)") goes before the extension and counts toward the same budget.
  static func from(objectKey: String, suffix: String = "") -> String {
    // Unicode scalars, not Characters: a "/" fused with a combining mark is still a path separator.
    let key = objectKey.unicodeScalars
    let lastSegment = key[(key.lastIndex(of: "/").map(key.index(after:)) ?? key.startIndex)...]
    let scalars: [Unicode.Scalar] = lastSegment.filter {
      $0 != ":" && $0 != "\\" && !CharacterSet.controlCharacters.contains($0)
        && !CharacterSet.newlines.contains($0)
    }
    let extensionScalars = scalars.lastIndex(of: ".").map { scalars[($0 + 1)...] } ?? []
    let hasExtension =
      !extensionScalars.isEmpty && extensionScalars.count <= 16
      && extensionScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    let fileExtension = hasExtension ? "." + String(String.UnicodeScalarView(extensionScalars)) : ""
    let stem = String(
      String.UnicodeScalarView(scalars.dropLast(hasExtension ? extensionScalars.count + 1 : 0)))
    let byteLimit = 120 - suffix.utf8.count - fileExtension.utf8.count
    var shortened = ""
    for character in stem {
      guard shortened.utf8.count + character.utf8.count <= byteLimit else { break }
      shortened.append(character)
    }
    let safeStem = shortened.isEmpty || shortened == "." || shortened == ".." ? "object" : shortened
    return safeStem + suffix + fileExtension
  }
}
