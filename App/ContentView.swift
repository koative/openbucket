import AppKit
import OpenBucketCore
import SwiftUI

struct ContentView: View {
  let model: AppModel
  @Bindable var browser: BrowserController

  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  /// Sidebar item clicked whose location hasn't loaded yet; keeps its row highlighted meanwhile.
  @State private var pendingItem: SidebarItem?
  @State private var pendingDelete: ConnectionProfile?
  @State private var deleteError: String?
  /// An external link to a bucket no connection knows, waiting for the user's go-ahead.
  @State private var linkToConfirm: ExternalLink?
  @State private var linkError: String?

  private struct ExternalLink {
    let text: String
    let location: S3Location
    let connection: String
  }

  private enum SidebarItem: Hashable {
    case profile(UUID)
    case bucket(String)
    case favorite(S3Location)
    case recent(S3Location)
  }

  /// Recent locations not already in Favorites.
  private var recentLocations: [S3Location] {
    Array(model.recents.filter { !model.isFavorite($0) }.prefix(5))
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List(selection: sidebarSelection) {
        Section("Connections") {
          ForEach(model.profiles) { profile in
            Label(profile.name, systemImage: "externaldrive.connected.to.line.below")
              .symbolVariant(profile.id == model.selectedProfileID ? .fill : .none)
              .tag(SidebarItem.profile(profile.id))
              .contextMenu {
                Button("Edit Connection…") { edit(profile) }
                Button("Delete Connection…", role: .destructive) { pendingDelete = profile }
              }
          }
        }

        if !model.favorites.isEmpty {
          Section("Favorites") {
            ForEach(model.favorites, id: \.self) { location in
              locationLabel(location)
                .tag(SidebarItem.favorite(location))
                .contextMenu {
                  Button("Remove from Favorites") { browser.toggleFavorite(location) }
                  Button("Copy S3 URI") { browser.copy([location.displayString]) }
                }
            }
          }
        }

        if !recentLocations.isEmpty {
          Section("Recent") {
            ForEach(recentLocations, id: \.self) { location in
              locationLabel(location)
                .tag(SidebarItem.recent(location))
            }
          }
        }

        if !model.buckets.isEmpty {
          Section("Buckets") {
            ForEach(model.buckets, id: \.self) { bucket in
              Label(bucket, systemImage: "shippingbox")
                .tag(SidebarItem.bucket(bucket))
            }
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
        HStack {
          Button {
            edit(nil)
          } label: {
            Label("Add Connection", systemImage: "plus")
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .help("Add Connection (⌘N)")
          Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
      }
      .navigationTitle("OpenBucket")
      .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 350)
    } detail: {
      ObjectBrowserView(
        model: model, browser: browser,
        showSidebar: columnVisibility == .detailOnly ? { columnVisibility = .all } : nil
      )
      .navigationTitle(model.browser.location?.displayName ?? model.selectedProfile?.name ?? "OpenBucket")
      .navigationSubtitle(model.browser.location == nil ? "" : model.selectedProfile?.name ?? "")
    }
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Button {
          browser.goBack()
        } label: {
          Label("Back", systemImage: "chevron.left")
        }
        .help("Back (⌘[)")
        .disabled(!browser.history.canGoBack)

        Button {
          browser.goForward()
        } label: {
          Label("Forward", systemImage: "chevron.right")
        }
        .help("Forward (⌘])")
        .disabled(!browser.history.canGoForward)
      }

      ToolbarItemGroup(placement: .primaryAction) {
        if let profile = model.selectedProfile {
          Button {
            browser.showsLocationSheet = true
          } label: {
            Label("Go to Location", systemImage: "arrow.forward.circle")
          }
          .help("Go to an s3:// location or S3 link (⇧⌘G)")

          if profile.allowsChanges {
            Button {
              browser.uploadFiles()
            } label: {
              Label("Upload Files", systemImage: "arrow.up.to.line")
            }
            .help(browser.modifyUnavailableReason ?? "Upload files or folders to this folder (⌘U)")
            .disabled(!browser.canModify || browser.isTransferring)
          }

          Button {
            browser.refresh()
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          .help("Refresh (⌘R)")

          Picker("View", selection: $browser.layout) {
            Label("Grid", systemImage: "square.grid.2x2").tag(BrowserLayout.grid)
            Label("List", systemImage: "list.bullet").tag(BrowserLayout.list)
          }
          .pickerStyle(.segmented)
          .help("View as grid (⌘1) or list (⌘2)")
          .disabled(browser.deepSearch != nil)
        }

        Button {
          browser.showsInspector.toggle()
        } label: {
          Label(browser.showsInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
        }
        .help(browser.showsInspector ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
      }
    }
    .navigationSplitViewStyle(.balanced)
    .sheet(item: $browser.editorTarget) { target in
      ConnectionEditor(model: model, existing: target.profile)
    }
    .sheet(isPresented: $browser.showsLocationSheet) {
      OpenLocationSheet(model: model)
    }
    .sheet(item: $browser.shareTarget) { target in
      ShareLinkView(object: target.object, versionID: target.versionID, model: model)
    }
    .modifier(ChangePresentations(browser: browser))
    .sheet(isPresented: $browser.showsAsOfSheet) {
      BrowseAsOfSheet(browser: browser)
    }
    .confirmationDialog(
      "Delete “\(pendingDelete?.name ?? "")”?",
      isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
      presenting: pendingDelete
    ) { profile in
      Button("Delete Connection", role: .destructive) {
        Task {
          do {
            try await model.delete(profile)
          } catch {
            deleteError = AppModel.failure(for: error).message
          }
        }
      }
    } message: { _ in
      Text("The connection and its Keychain credentials will be removed from this Mac.")
    }
    .alert(
      "Couldn't finish deleting the connection",
      isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }),
      presenting: deleteError
    ) { _ in
      Button("OK") {}
    } message: { message in
      Text(message)
    }
    .alert(
      "Couldn't update Favorites",
      isPresented: Binding(
        get: { browser.favoriteError != nil }, set: { if !$0 { browser.favoriteError = nil } }),
      presenting: browser.favoriteError
    ) { _ in
      Button("OK") {}
    } message: { message in
      Text(message)
    }
    .confirmationDialog(
      "Open \(linkToConfirm?.location.displayString ?? "") with “\(linkToConfirm?.connection ?? "")”?",
      isPresented: Binding(get: { linkToConfirm != nil }, set: { if !$0 { linkToConfirm = nil } }),
      presenting: linkToConfirm
    ) { link in
      Button("Open") { model.openLink(link.text) }
    } message: { _ in
      Text(
        "None of your connections lists this bucket. Opening it sends requests signed with this "
          + "connection’s credentials, which the bucket’s owner can see.")
    }
    .alert(
      "Couldn't open the link",
      isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } }),
      presenting: linkError
    ) { _ in
      Button("OK") {}
    } message: { message in
      Text(message)
    }
    .onOpenURL { url in
      // Opened URLs arrive percent-encoded; typed s3:// text is literal, so decode s3:// here only.
      let text = (url.scheme == "s3" ? url.absoluteString.removingPercentEncoding : nil) ?? url.absoluteString
      Task { await openExternalLink(text) }
    }
    .background(WindowReader { browser.window = $0 })
    .onAppear { FavoritesIndex.update(model.profiles) }
    .onChange(of: model.profiles) { FavoritesIndex.update(model.profiles) }
    .onChange(of: model.browser.location) { _, location in
      // A clicked favorite or recent stays highlighted once loaded; anything else follows the location.
      switch pendingItem {
      case .favorite(let clicked) where clicked == location, .recent(let clicked) where clicked == location:
        break
      default:
        pendingItem = nil
      }
    }
    .task { await model.loadProfiles() }
  }

  private func locationLabel(_ location: S3Location) -> some View {
    Label(location.displayName, systemImage: location.prefix.isEmpty ? "shippingbox" : "folder")
      .help(location.displayString)
  }

  /// The clicked item until its location loads; then the open favorite, bucket or recent location,
  /// otherwise the selected connection.
  private var sidebarSelection: Binding<SidebarItem?> {
    Binding {
      if let pendingItem { return pendingItem }
      if let location = model.browser.location {
        if model.isFavorite(location) { return .favorite(location) }
        if model.buckets.contains(location.bucket) { return .bucket(location.bucket) }
        if recentLocations.contains(location) { return .recent(location) }
      }
      return model.selectedProfileID.map(SidebarItem.profile)
    } set: { item in
      switch item {
      case .profile(let id):
        pendingItem = nil
        model.selectProfile(id)
      case .bucket(let bucket):
        guard let location = try? S3Location(bucket: bucket) else { return }
        pendingItem = item
        model.open(location)
      case .favorite(let location), .recent(let location):
        pendingItem = item
        model.open(location)
      case nil:
        break
      }
    }
  }

  private func edit(_ profile: ConnectionProfile?) {
    browser.editorTarget = EditorTarget(profile: profile)
  }

  /// Links from other apps can arrive before profiles load (cold launch). Any web page can send one, so a
  /// bucket no connection knows asks before requests signed with the user's credentials go out.
  private func openExternalLink(_ text: String) async {
    await model.loadProfilesIfNeeded()
    if let link = S3Location(link: text), !model.isKnownBucket(link.bucket),
      let profile = model.profile(forBucket: link.bucket)
    {
      linkToConfirm = ExternalLink(text: text, location: link, connection: profile.name)
    } else if !model.openLink(text) {
      linkError =
        S3Location(link: text) == nil
        ? "OpenBucket can open s3:// locations, S3 object URLs and AWS console links."
        : "Add a connection that can reach this bucket first."
    }
  }
}

/// Reports the window hosting it, so AppKit panels can attach to that window.
private struct WindowReader: NSViewRepresentable {
  let onWindow: @MainActor (NSWindow) -> Void

  func makeNSView(context: Context) -> ReaderView { ReaderView(onWindow: onWindow) }

  func updateNSView(_ view: ReaderView, context: Context) {}

  final class ReaderView: NSView {
    let onWindow: @MainActor (NSWindow) -> Void

    init(onWindow: @escaping @MainActor (NSWindow) -> Void) {
      self.onWindow = onWindow
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { onWindow(window) }
    }
  }
}

private struct OpenLocationSheet: View {
  @Environment(\.dismiss) private var dismiss
  let model: AppModel

  @State private var text: String
  @State private var errorMessage: String?

  /// Starts with the current location; links are pasted explicitly (silent pasteboard reads prompt on macOS 26).
  init(model: AppModel) {
    self.model = model
    _text = State(initialValue: model.browser.location?.displayString ?? "s3://")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Go to Location")
        .font(.title2.weight(.semibold))
      TextField("s3://bucket/folder/ or an S3 link", text: $text)
        .font(.system(.body, design: .monospaced))
        .onChange(of: text) { errorMessage = nil }
      Text("Paste an s3:// location, an AWS console link or an S3 object URL.")
        .font(.callout)
        .foregroundStyle(.secondary)
      if let errorMessage {
        Label {
          Text(errorMessage)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
        .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Go") {
          if model.openLink(text) {
            dismiss()
          } else {
            errorMessage =
              S3Location(link: text) == nil
              ? "Enter a location such as s3://bucket/photos/, or paste an S3 or AWS console link."
              : "Add a connection that can reach this bucket first."
          }
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 460)
  }
}
