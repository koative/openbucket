import Foundation
import Testing

@testable import OpenBucket

@Test func longPreviewNameKeepsFileExtension() {
  let name = PreviewFileName.from(objectKey: "photos/\(String(repeating: "a", count: 130)).png")

  #expect(name.hasSuffix(".png"))
  #expect(name.utf8.count <= 120)
}

@Test func previewNameIsSafeForLocalTemporaryFile() {
  let name = PreviewFileName.from(objectKey: "photos/\(String(repeating: "🌊", count: 80)):\\bad\n.mp4")

  #expect(name.hasSuffix(".mp4"))
  #expect(name.utf8.count <= 120)
  #expect(!name.contains(":"))
  #expect(!name.contains("\\"))
  #expect(!name.contains("\n"))
}

@Test(arguments: ["a/../\u{301}x.png", "a/..", "a/.", "photos/", "/\u{301}", "../\u{301}..\u{301}/x"])
func fileNamesAreOneLocalPathComponent(key: String) {
  var used = Set<String>()
  let names = [
    PreviewFileName.from(objectKey: key),
    BatchDownloadNames.uniqueName(for: key, usedNames: &used),
    BatchDownloadNames.uniqueName(for: key, usedNames: &used),
  ]

  for name in names {
    #expect(!name.unicodeScalars.contains("/"))
    #expect(!["", ".", ".."].contains(name))
    let directory = URL(fileURLWithPath: "/openbucket-export", isDirectory: true)
    let parent = directory.appendingPathComponent(name).standardizedFileURL.deletingLastPathComponent()
    #expect(parent.path == directory.path)
  }
}
