import Foundation
import OpenBucketCore

/// What a Storage Overview or Compare window shows: a folder on one connection, independent of the main
/// window's selection.
struct InsightTarget: Codable, Hashable, Sendable {
  let profileID: UUID
  let location: S3Location
}

extension AppModel {
  /// The target's connection with its credentials resolved now; windows restored at launch wait for
  /// profiles.json.
  func downloadSource(for target: InsightTarget) async throws -> DownloadSource {
    await loadProfilesIfNeeded()
    guard let profile = profiles.first(where: { $0.id == target.profileID }) else {
      throw S3Failure(
        category: .unknown, message: "The connection this window was opened from no longer exists.")
    }
    return DownloadSource(
      profile: profile, bucket: target.location.bucket, credentials: try await credentials(for: profile))
  }

  /// `source` with the target's connection settings as saved now, nil once it was deleted. Syncs use it, so
  /// turning off Allow changes stops writes from windows that connected before.
  func current(_ source: DownloadSource, for target: InsightTarget) -> DownloadSource? {
    profiles.first { $0.id == target.profileID }.map {
      DownloadSource(profile: $0, bucket: source.bucket, credentials: source.credentials)
    }
  }
}
