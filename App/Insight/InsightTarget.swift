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
}
