import Foundation
import Observation

@MainActor @Observable
public final class BrowseSession {
  public private(set) var location: S3Location?
  public private(set) var prefixes: [String] = []
  public private(set) var objects: [ObjectSummary] = []
  public private(set) var nextToken: String?
  public private(set) var isLoading = false
  public private(set) var failure: S3Failure?

  @ObservationIgnored private let repository: any S3Repository
  /// Internal so tests can await a load deterministically.
  @ObservationIgnored private(set) var activeTask: Task<Void, Never>?
  @ObservationIgnored private var connection: (profile: ConnectionProfile, credentials: S3Credentials)?
  /// Continuation tokens already requested for `location`, so A→B→A cycles stop.
  @ObservationIgnored private var seenTokens = Set<String>()
  @ObservationIgnored private var seenPrefixes = Set<[UInt8]>()
  @ObservationIgnored private var seenObjects = Set<[UInt8]>()

  /// Consecutive empty pages followed before handing the token back to the user.
  private static let emptyPageLimit = 16

  public init(repository: any S3Repository) {
    self.repository = repository
  }

  public func navigate(profile: ConnectionProfile, credentials: S3Credentials, to location: S3Location) {
    activeTask?.cancel()
    connection = (profile, credentials)
    seenTokens = []
    load(location, token: nil, append: false)
  }

  /// Loads the page after the current one with the connection given to `navigate`.
  public func loadNextPage() {
    guard let location, let token = nextToken, !isLoading else { return }
    load(location, token: token, append: true)
  }

  /// Replaces the credentials later `loadNextPage` calls use, e.g. after temporary credentials refresh.
  public func updateCredentials(_ credentials: S3Credentials) {
    connection?.credentials = credentials
  }

  public func cancel() {
    activeTask?.cancel()
    activeTask = nil
    connection = nil
    seenTokens = []
    show(nil)
    failure = nil
    isLoading = false
  }

  private func show(_ location: S3Location?) {
    self.location = location
    prefixes = []
    objects = []
    nextToken = nil
    seenPrefixes = []
    seenObjects = []
  }

  private func load(_ location: S3Location, token: String?, append: Bool) {
    guard let connection else { return }
    isLoading = true
    failure = nil
    // The task runs on the MainActor, so `navigate`/`cancel` mark it cancelled before it can resume;
    // checking `Task.isCancelled` after each await is enough to drop stale responses.
    activeTask = Task {
      do {
        var token = token
        var emptyPages = 0
        while true {
          let page = try await repository.listObjects(
            profile: connection.profile,
            credentials: connection.credentials,
            bucket: location.bucket,
            prefix: location.prefix,
            continuationToken: token
          )
          guard !Task.isCancelled else { return }
          if let token { seenTokens.insert(token) }
          let next = page.nextToken.flatMap { seenTokens.contains($0) ? nil : $0 }
          if page.prefixes.isEmpty, page.objects.isEmpty, let next {
            emptyPages += 1
            if emptyPages < Self.emptyPageLimit {
              token = next
              continue
            }
          }
          if !append { show(location) }
          prefixes.append(contentsOf: page.prefixes.filter { seenPrefixes.insert(Array($0.utf8)).inserted })
          objects.append(contentsOf: page.objects.filter { seenObjects.insert($0.id).inserted })
          nextToken = next
          isLoading = false
          return
        }
      } catch {
        guard !Task.isCancelled else { return }
        if !append { show(location) }
        failure = error as? S3Failure ?? S3Failure(category: .unknown, message: "S3 request failed.")
        isLoading = false
      }
    }
  }
}
