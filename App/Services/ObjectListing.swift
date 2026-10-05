import Foundation
import OpenBucketCore

extension AppModel.DownloadSource {
  /// Pages `listAllObjects` under `prefix` until `body` returns false or the listing ends.
  /// Throws `CancellationError` once the task is cancelled, and a service failure when a token repeats.
  @MainActor func forEachObjectPage(
    _ repository: any S3Repository,
    prefix: String,
    _ body: (ObjectPage) throws -> Bool
  ) async throws {
    var token: String?
    var seenTokens = Set<String>()
    repeat {
      let page = try await repository.listAllObjects(
        profile: profile, credentials: credentials, bucket: bucket, prefix: prefix, continuationToken: token)
      try Task.checkCancellation()
      guard try body(page) else { return }
      token = page.nextToken
      if let token, !seenTokens.insert(token).inserted { throw Self.repeatedPage(token) }
    } while token != nil
  }

  /// Pages `listObjectVersions` under `prefix` like `forEachObjectPage`.
  @MainActor func forEachVersionPage(
    _ repository: any S3Repository,
    prefix: String,
    delimiter: String?,
    _ body: (VersionPage) throws -> Bool
  ) async throws {
    var markers: (key: String?, versionID: String?) = (nil, nil)
    var seenMarkers = Set<[String?]>()
    repeat {
      let page = try await repository.listObjectVersions(
        profile: profile, credentials: credentials, bucket: bucket, prefix: prefix, delimiter: delimiter,
        keyMarker: markers.key, versionIDMarker: markers.versionID)
      try Task.checkCancellation()
      guard try body(page) else { return }
      markers = (page.nextKeyMarker, page.nextVersionIDMarker)
      if markers.key != nil || markers.versionID != nil,
        !seenMarkers.insert([markers.key, markers.versionID]).inserted
      {
        throw Self.repeatedPage("\(markers.key ?? "") \(markers.versionID ?? "")")
      }
    } while markers.key != nil || markers.versionID != nil
  }

  /// A server that hands out the same page again would loop forever; the listing can't be completed.
  private static func repeatedPage(_ marker: String) -> S3Failure {
    S3Failure(
      category: .service,
      message: "The server returned the same page of results twice, so the listing is incomplete.",
      technicalDetail: "Repeated continuation marker: \(marker)")
  }
}

/// `key` without its leading `prefix`, compared byte-wise like S3; nil when `key` isn't under `prefix`.
func relativeKey(_ key: String, under prefix: String) -> String? {
  guard key.utf8.starts(with: prefix.utf8) else { return nil }
  return String(decoding: key.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
}
