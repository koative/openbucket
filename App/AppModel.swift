import Foundation
import Observation
import OpenBucketCore

@MainActor @Observable
final class AppModel {
  struct DownloadSource: Sendable {
    let profile: ConnectionProfile
    let bucket: String
    let credentials: S3Credentials
  }

  private(set) var profiles: [ConnectionProfile] = []
  private(set) var selectedProfileID: UUID?
  private(set) var buckets: [String] = []
  private(set) var isConnecting = false
  private(set) var connectionFailure: S3Failure?
  /// Recently opened locations of the selected profile, newest first.
  private(set) var recents: [S3Location] = []
  /// Object key a link asked to reveal once its folder is listed; see `consumePendingSelectionKey()`.
  private(set) var pendingSelectionKey: String?
  let browser: BrowseSession

  @ObservationIgnored let repository: any S3Repository
  @ObservationIgnored private let profileStore: ProfileStore
  @ObservationIgnored private let credentialStore: any CredentialStore
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var connectionTask: Task<Void, Never>?
  /// Re-resolves temporary credentials shortly before they expire; see `adopt(_:)`.
  @ObservationIgnored private var credentialRefreshTask: Task<Void, Never>?
  /// Temporary credentials are re-resolved this many seconds before they expire.
  @ObservationIgnored var credentialRefreshLead: TimeInterval = 60
  /// False until profiles.json has been read, and after an I/O failure: saving then would overwrite it.
  @ObservationIgnored private var profilesLoaded = false
  /// Credentials of the selected profile, resolved once per selection (again when they are about to expire).
  private var selectedCredentials: S3Credentials?

  private static let recentsLimit = 10

  init(
    repository: any S3Repository,
    profileStore: ProfileStore,
    credentialStore: any CredentialStore,
    defaults: UserDefaults = .standard
  ) {
    self.repository = repository
    self.profileStore = profileStore
    self.credentialStore = credentialStore
    self.defaults = defaults
    browser = BrowseSession(repository: repository)
  }

  var selectedProfile: ConnectionProfile? {
    profiles.first { $0.id == selectedProfileID }
  }

  /// Intents and `s3://` links can arrive before the window has loaded the saved connections.
  func loadProfilesIfNeeded() async {
    if !profilesLoaded { await loadProfiles() }
  }

  func loadProfiles() async {
    do {
      profiles = try await profileStore.load()
      profilesLoaded = true
    } catch let error as UnreadableProfilesError {
      profiles = []
      profilesLoaded = true
      connectionFailure = S3Failure(
        category: .localFile,
        message: "Saved connections couldn't be read. A copy was kept as \(error.backupName).")
      return
    } catch {
      profilesLoaded = false
      connectionFailure = S3Failure(
        category: .localFile, message: "Saved connections couldn't be read.",
        technicalDetail: error.localizedDescription)
      return
    }
    if selectedProfileID == nil {
      selectProfile(profiles.first?.id)
    }
  }

  /// `credentials` is required for `.keychain` profiles and ignored for `.awsProfile` ones.
  func save(_ profile: ConnectionProfile, credentials: S3Credentials?) async throws {
    try requireLoadedProfiles()
    let previous = profiles.first { $0.id == profile.id }
    let usesKeychain = profile.credentialSource == .keychain
    var previousCredentials: S3Credentials?
    if usesKeychain {
      guard let credentials else {
        throw S3Failure(
          category: .missingCredentials, message: "Enter an access key ID and secret access key.")
      }
      if previous != nil {
        previousCredentials = try? await credentialStore.load(reference: profile.credentialReference)
      }
      try await credentialStore.save(credentials, reference: profile.credentialReference)
    }
    var updated = profiles.filter { $0.id != profile.id }
    updated.append(profile)
    updated.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    do {
      try await profileStore.save(updated)
    } catch {
      if usesKeychain {
        if let previousCredentials {
          try? await credentialStore.save(previousCredentials, reference: profile.credentialReference)
        } else {
          try? await credentialStore.delete(reference: profile.credentialReference)
        }
      }
      throw error
    }
    profiles = updated
    if !usesKeychain, previous?.credentialSource == .keychain {
      try? await credentialStore.delete(reference: profile.credentialReference)
    }
    selectProfile(profile.id)
  }

  func delete(_ profile: ConnectionProfile) async throws {
    try requireLoadedProfiles()
    let updated = profiles.filter { $0.id != profile.id }
    try await profileStore.save(updated)
    profiles = updated
    defaults.removeObject(forKey: Self.recentsKey(profile.id))
    if selectedProfileID == profile.id { selectProfile(updated.first?.id) }
    guard profile.credentialSource == .keychain else { return }
    do {
      try await credentialStore.delete(reference: profile.credentialReference)
    } catch {
      throw S3Failure(
        category: .unknown,
        message: "The connection was removed, but its Keychain item couldn't be deleted.",
        technicalDetail: "\(error)")
    }
  }

  /// Keychain access keys, or the resolved AWS CLI profile (which may be temporary, see `expiration`).
  func credentials(for profile: ConnectionProfile) async throws -> S3Credentials {
    switch profile.credentialSource {
    case .keychain: return try await credentialStore.load(reference: profile.credentialReference)
    case .awsProfile(let name): return try await repository.resolveAWSProfile(name)
    }
  }

  func selectProfile(_ id: UUID?) {
    resetSelection(id)
    connect { profile, credentials in
      if let bucket = profile.knownBucket, !bucket.isEmpty {
        let location = try S3Location(bucket: bucket, prefix: profile.startingPrefix)
        self.browser.navigate(profile: profile, credentials: credentials, to: location)
      } else {
        self.buckets = try await self.sortedBuckets(profile: profile, credentials: credentials)
      }
    }
    if let profile = selectedProfile, let bucket = profile.knownBucket, !bucket.isEmpty,
      let start = try? S3Location(bucket: bucket, prefix: profile.startingPrefix)
    {
      record(start)
    }
  }

  func open(_ location: S3Location) {
    guard selectedProfile != nil else { return }
    record(location)
    connect { profile, credentials in
      self.browser.navigate(profile: profile, credentials: credentials, to: location)
    }
  }

  /// Switches to profile `id` if needed (cancelling the old connection) and opens `location` there.
  /// An unpinned profile lists its buckets first, as `selectProfile` does, so the sidebar shows them.
  func open(_ location: S3Location, inProfile id: UUID) {
    guard id != selectedProfileID else { return open(location) }
    resetSelection(id)
    guard selectedProfile != nil else { return }
    record(location)
    connect { profile, credentials in
      if (profile.knownBucket ?? "").isEmpty {
        // The location may be reachable without permission to list every bucket.
        if let found = try? await self.sortedBuckets(profile: profile, credentials: credentials) {
          self.buckets = found
        }
        try Task.checkCancellation()
      }
      self.browser.navigate(profile: profile, credentials: credentials, to: location)
    }
  }

  private func sortedBuckets(profile: ConnectionProfile, credentials: S3Credentials) async throws -> [String]
  {
    let found = try await repository.listBuckets(profile: profile, credentials: credentials)
    try Task.checkCancellation()
    return found.sorted()
  }

  /// Opens an `s3://`, AWS console or S3 object URL; object links open the parent folder and set
  /// `pendingSelectionKey`. `profileID` pins the connection (e.g. a window bound to one); otherwise it is
  /// chosen by bucket. False when the text isn't a recognised link or there is no profile.
  @discardableResult func openLink(_ text: String, inProfile profileID: UUID? = nil) -> Bool {
    guard let link = S3Location(link: text),
      let profile = profileID.flatMap({ id in profiles.first { $0.id == id } })
        ?? self.profile(forBucket: link.bucket)
    else {
      return false
    }
    var location = link
    pendingSelectionKey = nil
    if !link.prefix.isEmpty, !link.prefix.hasSuffix("/"), let parent = link.parent {
      location = parent
      pendingSelectionKey = link.prefix
    }
    open(location, inProfile: profile.id)
    return true
  }

  func consumePendingSelectionKey() -> String? {
    defer { pendingSelectionKey = nil }
    return pendingSelectionKey
  }

  /// The selected profile when it pins or lists `bucket`, else one pinned to it, else the selected one.
  func profile(forBucket bucket: String) -> ConnectionProfile? {
    if let selected = selectedProfile, selected.knownBucket == bucket || buckets.contains(bucket) {
      return selected
    }
    return profiles.first { $0.knownBucket == bucket } ?? selectedProfile ?? profiles.first
  }

  /// Some profile pins `bucket`, or the selected profile listed it.
  func isKnownBucket(_ bucket: String) -> Bool {
    buckets.contains(bucket) || profiles.contains { $0.knownBucket == bucket }
  }

  // MARK: Favorites and recents

  /// Favorites of the selected profile.
  var favorites: [S3Location] { selectedProfile?.favorites ?? [] }

  func isFavorite(_ location: S3Location) -> Bool {
    favorites.contains(location)
  }

  /// Adds or removes `location` in the selected profile's favorites and saves profiles.json.
  /// `profiles` changes before the save, so overlapping toggles build on each other.
  func toggleFavorite(_ location: S3Location) async throws {
    try requireLoadedProfiles()
    guard let id = selectedProfileID, profiles.contains(where: { $0.id == id }) else { return }
    func flip() {
      profiles = profiles.map { profile in
        guard profile.id == id else { return profile }
        var profile = profile
        if let index = profile.favorites.firstIndex(of: location) {
          profile.favorites.remove(at: index)
        } else {
          profile.favorites.append(location)
        }
        return profile
      }
    }
    flip()
    do {
      try await profileStore.save(profiles)
    } catch {
      flip()  // Undo only this change; a later toggle may already be applied.
      throw error
    }
  }

  private static func recentsKey(_ id: UUID) -> String { "recents.\(id.uuidString)" }

  private func record(_ location: S3Location) {
    guard let id = selectedProfileID else { return }
    recents.removeAll { $0 == location }
    recents.insert(location, at: 0)
    recents = Array(recents.prefix(Self.recentsLimit))
    defaults.set(recents.map(\.displayString), forKey: Self.recentsKey(id))
  }

  private func resetSelection(_ id: UUID?) {
    browser.cancel()
    credentialRefreshTask?.cancel()
    credentialRefreshTask = nil
    selectedProfileID = id
    selectedCredentials = nil
    buckets = []
    let stored = id.flatMap { defaults.stringArray(forKey: Self.recentsKey($0)) } ?? []
    recents = stored.compactMap { try? S3Location($0) }
  }

  /// Runs `body` with the selected profile's credentials; a newer `connect` cancels it and drops its results.
  private func connect(
    _ body: @escaping @MainActor (ConnectionProfile, S3Credentials) async throws -> Void
  ) {
    connectionTask?.cancel()
    connectionFailure = nil
    isConnecting = false
    guard let profile = selectedProfile else { return }
    isConnecting = true
    connectionTask = Task {
      do {
        let credentials: S3Credentials
        if let selectedCredentials,
          (selectedCredentials.expiration?.timeIntervalSinceNow ?? .infinity) > credentialRefreshLead
        {
          credentials = selectedCredentials
        } else {
          credentials = try await self.credentials(for: profile)
          try Task.checkCancellation()
          adopt(credentials)
        }
        try await body(profile, credentials)
        guard !Task.isCancelled else { return }
        isConnecting = false
      } catch {
        guard !Task.isCancelled else { return }
        browser.cancel()
        connectionFailure = Self.failure(for: error)
        isConnecting = false
      }
    }
  }

  /// Stores freshly resolved credentials and, when they are temporary, schedules one re-resolve
  /// `credentialRefreshLead` seconds before they expire, so downloads, scans and Load More keep working.
  private func adopt(_ credentials: S3Credentials) {
    selectedCredentials = credentials
    credentialRefreshTask?.cancel()
    credentialRefreshTask = nil
    guard let profileID = selectedProfileID, let expiration = credentials.expiration else { return }
    let delay = expiration.timeIntervalSinceNow - credentialRefreshLead
    // Credentials that are already that close re-resolve on the next `connect` instead of looping here.
    guard delay > 0 else { return }
    credentialRefreshTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self, let profile = self.selectedProfile, profile.id == profileID else {
        return
      }
      do {
        let fresh = try await self.credentials(for: profile)
        guard !Task.isCancelled else { return }
        self.browser.updateCredentials(fresh)
        self.adopt(fresh)
      } catch {
        guard !Task.isCancelled else { return }
        self.connectionFailure = Self.failure(for: error)
      }
    }
  }

  func refresh() {
    guard profilesLoaded else {
      Task { await loadProfiles() }
      return
    }
    if let location = browser.location { open(location) } else { selectProfile(selectedProfileID) }
  }

  func loadNextPage() {
    browser.loadNextPage()
  }

  /// Nil until a bucket is open and the selected profile's credentials are loaded.
  func downloadSource() -> DownloadSource? {
    guard let profile = selectedProfile, let location = browser.location, let selectedCredentials else {
      return nil
    }
    return DownloadSource(profile: profile, bucket: location.bucket, credentials: selectedCredentials)
  }

  /// `progress` gets cumulative bytes on the main actor, at most ~10 times a second plus a final call.
  /// `versionID` nil downloads the current version.
  func download(
    _ object: ObjectSummary,
    versionID: String? = nil,
    from source: DownloadSource,
    to destination: URL,
    maximumBytes: Int64,
    progress: @escaping @MainActor (_ bytesReceived: Int64) -> Void
  ) async throws {
    let throttle = ProgressThrottle(progress)
    do {
      try await repository.downloadObject(
        profile: source.profile, credentials: source.credentials, bucket: source.bucket,
        key: object.key, versionID: versionID, to: destination, maximumBytes: maximumBytes
      ) { throttle.send($0) }
    } catch {
      await throttle.finish()
      throw error
    }
    await throttle.finish()
  }

  /// Downloads into a fresh 0700 temporary directory. The caller removes `url.deletingLastPathComponent()`.
  func downloadToPrivateTemp(
    _ object: ObjectSummary,
    versionID: String? = nil,
    from source: DownloadSource,
    maximumBytes: Int64
  ) async throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("OpenBucket-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let file = directory.appendingPathComponent(PreviewFileName.from(objectKey: object.key))
    do {
      try await repository.downloadObject(
        profile: source.profile, credentials: source.credentials, bucket: source.bucket,
        key: object.key, versionID: versionID, to: file, maximumBytes: maximumBytes
      ) { _ in }
      return file
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  /// `versionIDs`: object `id` → version to fetch; objects not in it download their current version.
  func downloadSelected(
    _ objects: [ObjectSummary],
    versionIDs: [[UInt8]: String] = [:],
    from source: DownloadSource,
    into directory: URL,
    progress: @escaping @MainActor (BatchDownloadProgress) -> Void
  ) async throws -> BatchDownloadResult {
    try await BatchDownloader(repository: repository).download(
      objects, versionIDs: versionIDs, from: source, into: directory, progress: progress)
  }

  private func requireLoadedProfiles() throws {
    guard profilesLoaded else {
      throw S3Failure(
        category: .localFile,
        message: "Saved connections couldn't be read, so this change wasn't saved. Try again.")
    }
  }

  func test(profile: ConnectionProfile, credentials: S3Credentials) async throws -> String {
    if let bucket = profile.knownBucket, !bucket.isEmpty {
      _ = try await repository.listObjects(
        profile: profile,
        credentials: credentials,
        bucket: bucket,
        prefix: profile.startingPrefix,
        continuationToken: nil
      )
      return "Connected to \(bucket)."
    }
    let buckets = try await repository.listBuckets(profile: profile, credentials: credentials)
    return "Connected. Found \(buckets.count) buckets."
  }

  static func failure(for error: Error) -> S3Failure {
    if let failure = error as? S3Failure { return failure }
    if let error = error as? CredentialStoreError {
      switch error {
      case .notFound:
        return S3Failure(
          category: .missingCredentials,
          message: "Credentials are missing. Edit this connection to add them again.")
      case .invalidData, .keychain:
        return S3Failure(
          category: .missingCredentials, message: "Credentials could not be read from Keychain.",
          technicalDetail: "\(error)")
      }
    }
    if let error = error as? S3Location.ParseError {
      switch error {
      case .missingBucket:
        return S3Failure(category: .unknown, message: "Enter only the bucket name, without s3:// or slashes.")
      case .invalidScheme:
        return S3Failure(category: .unknown, message: "Enter a location such as s3://bucket/photos/.")
      }
    }
    return S3Failure(category: .unknown, message: "The request could not be completed.")
  }
}
