import AppIntents
import OpenBucketCore

/// An error whose message Shortcuts and Siri show as is.
struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
  let localizedStringResource: LocalizedStringResource

  init(_ message: String) { localizedStringResource = "\(message)" }
}

/// Opening a favorite; also what Spotlight runs when a favorite result is chosen.
struct OpenFavoriteIntent: OpenIntent {
  static let title: LocalizedStringResource = "Open Favorite"
  static let description = IntentDescription("Opens a favorite folder in OpenBucket.")
  static let supportedModes: IntentModes = .foreground(.immediate)

  @Parameter(title: "Favorite") var target: FavoriteEntity
  @Dependency private var model: AppModel

  init() {}

  init(favorite: FavoriteEntity) { target = favorite }

  @MainActor func perform() async throws -> some IntentResult {
    await model.loadProfilesIfNeeded()
    guard model.profiles.contains(where: { $0.id == target.profileID }) else {
      throw IntentFailure("This favorite's connection no longer exists.")
    }
    model.open(target.location, inProfile: target.profileID)
    return .result()
  }
}

struct OpenS3LocationIntent: AppIntent {
  static let title: LocalizedStringResource = "Open S3 Location"
  static let description = IntentDescription(
    "Opens an s3:// link, AWS console link or S3 URL in OpenBucket. Links to a file reveal it in its folder.")
  static let supportedModes: IntentModes = .foreground(.immediate)

  @Parameter(title: "Location") var location: String
  @Dependency private var model: AppModel

  init() {}

  init(location: String) { self.location = location }

  static var parameterSummary: some ParameterSummary { Summary("Open \(\.$location)") }

  @MainActor func perform() async throws -> some IntentResult {
    guard S3Location(link: location) != nil else {
      throw IntentFailure(
        "OpenBucket doesn't recognise this location. Use a link such as s3://bucket/photos/.")
    }
    await model.loadProfilesIfNeeded()
    guard model.openLink(location) else { throw IntentFailure("Add a connection in OpenBucket first.") }
    return .result()
  }
}

/// Link lifetimes offered by the Share Link sheet and Copy Share Link.
enum ShareLinkExpiry: Int, AppEnum {
  case fifteenMinutes = 900
  case hour = 3600
  case day = 86_400
  case week = 604_800

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Link Expiry"
  static let caseDisplayRepresentations: [ShareLinkExpiry: DisplayRepresentation] = [
    .fifteenMinutes: "15 minutes", .hour: "1 hour", .day: "1 day", .week: "7 days",
  ]

  var title: LocalizedStringResource {
    Self.caseDisplayRepresentations[self]?.title ?? "\(rawValue) seconds"
  }

  /// Seconds a link signed with `credentials` lives, and why it may stop working sooner.
  /// Nil when the credentials expire within a minute.
  func lifetime(signedWith credentials: S3Credentials, now: Date = .now)
    -> (seconds: TimeInterval, warning: String?)?
  {
    let requested = TimeInterval(rawValue)
    guard let expiration = credentials.expiration else {
      // Session tokens without a known expiry (pasted keys, static profiles) can end at any time.
      let warning = "This link may stop working earlier because it was signed with temporary credentials."
      return (requested, credentials.sessionToken == nil ? nil : warning)
    }
    let remaining = expiration.timeIntervalSince(now).rounded(.down)
    if remaining >= requested { return (requested, nil) }
    guard remaining >= 60 else { return nil }
    return (remaining, "This link expires early, when the temporary credentials it was signed with do.")
  }
}

/// Presigned GET link, signed locally; never uploads, changes or deletes anything.
struct CopyShareLinkIntent: AppIntent {
  static let title: LocalizedStringResource = "Copy Share Link"
  static let description = IntentDescription(
    "Copies a link that lets anyone download a file until it expires. The link is signed on this Mac.")
  static let supportedModes: IntentModes = .background

  @Parameter(title: "File", description: "An s3:// link to a file, such as s3://bucket/report.pdf.")
  var object: String
  @Parameter(title: "Expires After", default: .day) var expiry: ShareLinkExpiry
  @Dependency private var model: AppModel

  init() {}

  init(object: String, expiry: ShareLinkExpiry) {
    self.object = object
    self.expiry = expiry
  }

  static var parameterSummary: some ParameterSummary {
    Summary("Copy share link to \(\.$object) expiring after \(\.$expiry)")
  }

  @MainActor func perform() async throws -> some IntentResult & ReturnsValue<URL> & ProvidesDialog {
    guard let location = S3Location(link: object), !location.prefix.isEmpty else {
      throw IntentFailure("Enter a link to a file, such as s3://bucket/report.pdf.")
    }
    guard !location.prefix.hasSuffix("/") else {
      throw IntentFailure("Share links work for files, not folders. Choose a file inside the folder.")
    }
    await model.loadProfilesIfNeeded()
    guard let profile = model.profile(forBucket: location.bucket) else {
      throw IntentFailure("No connection can open the bucket \(location.bucket). Add one in OpenBucket.")
    }
    let credentials: S3Credentials
    do {
      credentials = try await model.credentials(for: profile)
    } catch {
      throw IntentFailure(AppModel.failure(for: error).message)
    }

    guard let lifetime = expiry.lifetime(signedWith: credentials) else {
      throw IntentFailure("The temporary credentials of \(profile.name) have expired. Sign in again.")
    }
    let url: URL
    do {
      url = try await model.repository.presignedURL(
        profile: profile, credentials: credentials, bucket: location.bucket, key: location.prefix,
        versionID: nil, expiresIn: .seconds(lifetime.seconds),
        downloadFileName: PreviewFileName.from(objectKey: location.prefix))
    } catch {
      throw IntentFailure(AppModel.failure(for: error).message)
    }

    copyToPasteboard(url.absoluteString)
    let expires = (Date.now + lifetime.seconds).formatted(date: .abbreviated, time: .shortened)
    let name = (location.prefix as NSString).lastPathComponent
    let note = lifetime.warning.map { " \($0)" } ?? ""
    let message = "Copied a link to “\(name)” that works until \(expires).\(note)"
    return .result(value: url, dialog: "\(message) Anyone with it can download the file.")
  }
}

struct OpenBucketShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: OpenFavoriteIntent(),
      phrases: [
        "Open \(\.$target) in \(.applicationName)",
        "Open a favorite in \(.applicationName)",
        "Show my \(.applicationName) favorites",
      ],
      shortTitle: "Open Favorite",
      systemImageName: "star")
    AppShortcut(
      intent: OpenS3LocationIntent(),
      phrases: [
        "Open an S3 location in \(.applicationName)",
        "Open an S3 link in \(.applicationName)",
      ],
      shortTitle: "Open S3 Location",
      systemImageName: "link")
    AppShortcut(
      intent: CopyShareLinkIntent(),
      phrases: [
        "Copy a share link with \(.applicationName)",
        "Create a download link in \(.applicationName)",
      ],
      shortTitle: "Copy Share Link",
      systemImageName: "link.badge.plus")
  }
}
