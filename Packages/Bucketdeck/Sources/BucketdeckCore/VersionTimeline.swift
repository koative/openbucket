import Foundation

/// Point-in-time views over a ListObjectVersions result.
public enum VersionTimeline {
  /// Folder state at `date`: per key, the newest version with lastModified <= date;
  /// keys whose pick is a delete marker are dropped.
  public static func snapshot(_ versions: [ObjectVersion], at date: Date) -> [ObjectVersion] {
    newest(versions, at: date).filter { !$0.isDeleteMarker }
  }

  /// Keys whose latest entry is a delete marker, each with its newest real (non-marker) version.
  public static func deleted(_ versions: [ObjectVersion]) -> [ObjectVersion] {
    let real = Dictionary(
      newest(versions.filter { !$0.isDeleteMarker }, at: .distantFuture).map { (Array($0.key.utf8), $0) },
      uniquingKeysWith: { first, _ in first })
    return newest(versions, at: .distantFuture).filter(\.isDeleteMarker).compactMap {
      real[Array($0.key.utf8)]
    }
  }

  /// Per key (by UTF-8 bytes, in first-seen order), the entry with the latest lastModified <= `date`.
  /// Ties keep the earlier entry, which is the newer one in S3 order. A nil lastModified sorts oldest.
  private static func newest(_ versions: [ObjectVersion], at date: Date) -> [ObjectVersion] {
    var picks: [ObjectVersion] = []
    var index: [[UInt8]: Int] = [:]
    for version in versions {
      let modified = version.lastModified ?? .distantPast
      guard modified <= date else { continue }
      let key = Array(version.key.utf8)
      if let position = index[key] {
        if modified > (picks[position].lastModified ?? .distantPast) { picks[position] = version }
      } else {
        index[key] = picks.count
        picks.append(version)
      }
    }
    return picks
  }
}
