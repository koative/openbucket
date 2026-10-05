import AppIntents
import OpenBucketCore
import OpenBucketS3
import SwiftUI

@main
struct OpenBucketApp: App {
  @State private var model: AppModel
  @State private var browser: BrowserController

  init() {
    let model = AppModel(
      repository: SotoS3Repository(),
      profileStore: ProfileStore(fileURL: Self.profilesURL),
      credentialStore: KeychainCredentialStore()
    )
    _model = State(initialValue: model)
    _browser = State(initialValue: BrowserController(model: model))
    AppDependencyManager.shared.add(dependency: model)
  }

  var body: some Scene {
    Window("OpenBucket", id: "main") {
      ContentView(model: model, browser: browser)
        .environment(model)
        // Sidebar + content + inspector side by side.
        .frame(minWidth: 960, minHeight: 560)
    }
    .commands { BrowserCommands(model: model, browser: browser) }

    WindowGroup("Storage Overview", id: "storage-overview", for: InsightTarget.self) { $target in
      if let target {
        StorageOverviewView(model: model, target: target)
          .environment(model)
      }
    }
    .defaultSize(width: 900, height: 640)
    // s3:// links go to the browser window, never to a new window here.
    .handlesExternalEvents(matching: [])

    WindowGroup("Compare with Local Folder", id: "backup-verify", for: InsightTarget.self) { $target in
      if let target {
        BackupVerifyView(model: model, target: target)
          .environment(model)
          // Below this the header and status toggles crowd each other.
          .frame(minWidth: 720, minHeight: 480)
      }
    }
    .defaultSize(width: 900, height: 640)
    .handlesExternalEvents(matching: [])
  }

  private static var profilesURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("OpenBucket", isDirectory: true)
      .appendingPathComponent("profiles.json")
  }
}
