import Foundation
import Testing

@testable import OpenBucketCore

private func at(_ day: Double) -> Date { Date(timeIntervalSince1970: day * 86_400) }

private func version(_ key: String, _ id: String, day: Double, marker: Bool = false, latest: Bool = false)
  -> ObjectVersion
{
  ObjectVersion(
    key: key, versionID: id, isLatest: latest, isDeleteMarker: marker, lastModified: at(day), size: 1,
    eTag: nil,
    storageClass: nil)
}

/// "a" was written twice then deleted, "b" is live, "c" only ever had a delete marker. S3 order.
private let history = [
  version("a", "a3", day: 3, marker: true, latest: true),
  version("a", "a2", day: 2),
  version("a", "a1", day: 1),
  version("b", "b1", day: 1, latest: true),
  version("c", "c1", day: 2, marker: true, latest: true),
]

@Test func snapshotPicksNewestVersionAtDateAndHidesDeletedKeys() {
  #expect(VersionTimeline.snapshot(history, at: at(2.5)).map(\.versionID) == ["a2", "b1"])
  #expect(VersionTimeline.snapshot(history, at: at(1)).map(\.versionID) == ["a1", "b1"])
  #expect(VersionTimeline.snapshot(history, at: at(3)).map(\.versionID) == ["b1"])
  #expect(VersionTimeline.snapshot(history, at: at(0.5)).isEmpty)
}

@Test func deletedReturnsNewestRealVersionOfDeletedKeys() {
  #expect(VersionTimeline.deleted(history).map(\.versionID) == ["a2"])
  #expect(VersionTimeline.deleted(history.filter { $0.versionID != "a3" }).isEmpty)
}

@Test func storageSummaryGroupsChildrenAndStorageClasses() {
  var summary = StorageSummary(prefix: "p/")
  summary.add([
    ObjectSummary(key: "p/", size: 0, lastModified: nil, eTag: nil),
    ObjectSummary(key: "p/x/1", size: 5, lastModified: nil, eTag: nil, storageClass: "GLACIER"),
    ObjectSummary(key: "p/x/y/2", size: 7, lastModified: nil, eTag: nil),
  ])
  summary.add([
    ObjectSummary(key: "p/x", size: 3, lastModified: nil, eTag: nil),
    ObjectSummary(key: "p/f", size: 1, lastModified: nil, eTag: nil, storageClass: "STANDARD"),
  ])

  #expect(summary.totalBytes == 16)
  #expect(summary.objectCount == 5)
  #expect(summary.children.map(\.id) == ["x/", "x", "f"].map { Array($0.utf8) })
  #expect(summary.children.map(\.bytes) == [12, 3, 1])
  #expect(summary.children.map(\.objectCount) == [2, 1, 1])
  #expect(summary.storageClasses.map(\.name) == ["STANDARD", "GLACIER"])
  #expect(summary.storageClasses.map(\.bytes) == [11, 5])
  #expect(summary.storageClasses.map(\.objectCount) == [4, 1])
}

@Test func storageSummaryKeepsNormalizationVariantsDistinct() {
  var summary = StorageSummary(prefix: "")
  summary.add([
    ObjectSummary(key: "caf\u{00E9}/a", size: 1, lastModified: nil, eTag: nil),
    ObjectSummary(key: "cafe\u{0301}/a", size: 2, lastModified: nil, eTag: nil),
  ])
  #expect(Set(summary.children.map(\.id)).count == 2)
}

@Test func storageSummaryKeepsTheTwentyLargestAcrossPages() {
  var summary = StorageSummary(prefix: "")
  let objects = (1...25).map { ObjectSummary(key: "k\($0)", size: Int64($0), lastModified: nil, eTag: nil) }
  summary.add(Array(objects[..<12]))
  summary.add(Array(objects[12...]))

  #expect(summary.largest.count == 20)
  #expect(summary.largest.first?.size == 25)
  #expect(summary.largest.last?.size == 6)
}
