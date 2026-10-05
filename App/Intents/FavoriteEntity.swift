import AppIntents
import CoreSpotlight
import OpenBucketCore

/// A favorite folder of one connection, for Shortcuts, Siri and Spotlight.
struct FavoriteEntity: AppEntity, IndexedEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Favorite"
  static let defaultQuery = FavoriteQuery()

  /// Profile id + location, so the same folder favorited in two connections stays distinct.
  let id: String
  let profileID: UUID
  let profileName: String
  let location: S3Location

  init(profile: ConnectionProfile, location: S3Location) {
    id = profile.id.uuidString + location.displayString
    profileID = profile.id
    profileName = profile.name
    self.location = location
  }

  /// Last folder name of the prefix, or the bucket at its root.
  var name: String {
    location.prefix.split(separator: "/").last.map(String.init) ?? location.bucket
  }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(name)",
      subtitle: "\(location.displayString) · \(profileName)",
      image: .init(systemName: "star"))
  }

  static func all(in profiles: [ConnectionProfile]) -> [FavoriteEntity] {
    profiles.flatMap { profile in profile.favorites.map { FavoriteEntity(profile: profile, location: $0) } }
  }
}

struct FavoriteQuery: EntityStringQuery {
  @Dependency private var model: AppModel

  @MainActor func entities(for identifiers: [String]) async throws -> [FavoriteEntity] {
    await all().filter { identifiers.contains($0.id) }
  }

  @MainActor func entities(matching string: String) async throws -> [FavoriteEntity] {
    await all().filter {
      $0.location.displayString.localizedStandardContains(string)
        || $0.profileName.localizedStandardContains(string)
    }
  }

  @MainActor func suggestedEntities() async throws -> [FavoriteEntity] {
    await all()
  }

  @MainActor private func all() async -> [FavoriteEntity] {
    await model.loadProfilesIfNeeded()
    return FavoriteEntity.all(in: model.profiles)
  }
}

enum FavoritesIndex {
  @MainActor private static var pending: Task<Void, Never>?

  /// Replaces the Spotlight entries with the favorites of `profiles`. Updates run one after another so
  /// an older list can't land after a newer one.
  @MainActor static func update(_ profiles: [ConnectionProfile]) {
    let entities = FavoriteEntity.all(in: profiles)
    pending = Task { [previous = pending] in
      await previous?.value
      let index = CSSearchableIndex.default()
      // ponytail: delete-all then reindex, diff ids if favorites ever number in the thousands
      try? await index.deleteAppEntities(ofType: FavoriteEntity.self)
      try? await index.indexAppEntities(entities)
    }
    OpenBucketShortcuts.updateAppShortcutParameters()
  }
}
