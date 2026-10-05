import AppKit
import OpenBucketCore
import SwiftUI

struct ObjectBrowserView: View {
  let model: AppModel
  @Bindable var browser: BrowserController
  /// Nil while the sidebar is already visible.
  let showSidebar: (() -> Void)?
  @FocusState private var isSearchFocused: Bool
  @State private var quickLook = QuickLookPanel()
  /// A Finder drag is over the content area (and not over a folder that takes it instead). The app's own
  /// items dropped here stay where they are, so they don't highlight it.
  @State private var isDropTargeted = false

  var body: some View {
    // Built once per render and shared by the grid, the list and the inspector.
    let rows = browser.rows()
    VStack(spacing: 0) {
      if let location = model.browser.location {
        locationBar(location, rows: rows)
        Divider()
        HistoryBanner(browser: browser, deletedCount: isFiltering ? nil : rows.count(where: { $0.isDeleted }))
      }
      // Every state fills the space below the location bar, so the bar stays at the top.
      content(rows)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: BrowserDrop.self, isEnabled: browser.canModify) { drops, _ in
          if let location = model.browser.location { browser.accept(drops, into: location) }
        }
        .dropConfiguration { BrowserController.dropConfiguration($0) }
        .onDropSessionUpdated {
          isDropTargeted = browser.canModify && $0.phase.isOver && $0.localSession == nil
        }
        .overlay {
          if isDropTargeted {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(Color.accentColor, lineWidth: 3)
              .padding(4)
              .allowsHitTesting(false)
          }
        }
    }
    .safeAreaInset(edge: .bottom) { TransfersBar(browser: browser) }
    .inspector(isPresented: $browser.showsInspector) {
      InspectorPane(rows: rows, browser: browser)
        .inspectorColumnWidth(min: 260, ideal: 320, max: 440)
    }
    .onChange(of: browser.previewURL) { _, url in
      if let url {
        quickLook.show(url) { [browser] in if browser.previewURL == url { browser.previewURL = nil } }
      } else {
        quickLook.close()
      }
    }
    .searchable(
      text: $browser.searchText, placement: .toolbar,
      prompt: Text(model.browser.location.map { "Search \($0.displayName)" } ?? "Search")
    )
    .searchFocused($isSearchFocused)
    .onChange(of: browser.searchFocusRequest) { isSearchFocused = true }
    .onChange(of: isSearchFocused) { browser.isSearchFocused = isSearchFocused }
    .onSubmit(of: .search) { browser.searchAll() }
    .task(id: browser.searchText) {
      // Filtering only sees loaded pages, so a folder with more pages searches all of it after a pause.
      // History modes only filter their rows: the search lists current objects.
      guard browser.historyMode == nil, browser.deepSearch != nil || model.browser.nextToken != nil else {
        return
      }
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      browser.searchAll()
    }
    .onChange(of: ListingState(location: model.browser.location, isLoading: model.browser.isLoading)) {
      old, new in
      if old.location != new.location { browser.locationChanged(to: new.location) }
      if !new.isLoading { browser.revealPendingSelection() }
    }
    .onChange(of: rows.map(\.id)) { _, ids in browser.pruneSelection(to: ids) }
    // A finished transfer's result belongs to the connection it ran in.
    .onChange(of: model.selectedProfileID) { browser.clearFinishedTransfers() }
  }

  private var isFiltering: Bool {
    !browser.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private struct ListingState: Equatable {
    let location: S3Location?
    let isLoading: Bool
  }

  @ViewBuilder
  private func content(_ rows: [BrowserRow]) -> some View {
    let failure = model.connectionFailure ?? model.browser.failure
    if let failure, rows.isEmpty {
      failureView(failure)
    } else if model.browser.location == nil && (model.isConnecting || model.browser.isLoading) {
      ProgressView("Connecting…")
    } else if model.selectedProfile == nil {
      ContentUnavailableView {
        Label("Welcome to OpenBucket", systemImage: "externaldrive.connected.to.line.below")
      } description: {
        Text("Add an S3 connection to browse your files.")
      } actions: {
        Button("Add Connection…") { browser.editorTarget = EditorTarget(profile: nil) }
          .buttonStyle(.borderedProminent)
      }
    } else if model.browser.location == nil {
      ContentUnavailableView {
        Label(
          model.buckets.isEmpty ? "No buckets available" : "Choose a bucket", systemImage: "shippingbox")
      } description: {
        Text(
          model.buckets.isEmpty
            ? "Enter a known bucket in connection settings if listing all buckets is restricted."
            : "Select a bucket in the sidebar to browse its files."
        )
      } actions: {
        if model.buckets.isEmpty {
          Button("Edit Connection…") { browser.editorTarget = EditorTarget(profile: model.selectedProfile) }
            .buttonStyle(.borderedProminent)
        } else if let showSidebar {
          Button("Show Sidebar", action: showSidebar)
            .buttonStyle(.borderedProminent)
        }
      }
    } else if let search = browser.deepSearch {
      PreviewStatus(browser: browser)
      SearchResultsView(rows: rows, search: search, browser: browser)
    } else {
      if let failure {
        StatusBanner(message: failure.message, isWarning: true, actionTitle: "Try Again") {
          model.browser.nextToken == nil ? browser.refresh() : model.loadNextPage()
        }
      }
      PreviewStatus(browser: browser)
      FilterBar(rowCount: rows.count, browser: browser)
      if rows.isEmpty && !browser.searchText.isEmpty {
        ContentUnavailableView.search(text: browser.searchText)
      } else if rows.isEmpty && browser.folderHistory?.isRunning == true {
        ProgressView("Loading previous versions…")
      } else if rows.isEmpty && model.browser.nextToken != nil {
        // S3 can return long runs of empty pages (e.g. delete markers); let the user keep going.
        ContentUnavailableView {
          Label("Nothing listed yet", systemImage: "folder")
        } description: {
          Text("S3 returned only empty pages so far. More results may follow.")
        } actions: {
          Button("Continue Listing") { model.loadNextPage() }
            .buttonStyle(.borderedProminent)
            .disabled(model.browser.isLoading)
        }
      } else if rows.isEmpty {
        ContentUnavailableView("This folder is empty", systemImage: "folder")
      } else if browser.layout == .grid {
        BrowserGrid(rows: rows, browser: browser)
      } else {
        ObjectTableView(rows: rows, browser: browser)
      }
    }
  }

  private func locationBar(_ location: S3Location, rows: [BrowserRow]) -> some View {
    let isFavorite = model.isFavorite(location)
    return HStack(spacing: 8) {
      Button {
        browser.goToEnclosingFolder()
      } label: {
        Label("Enclosing Folder", systemImage: "chevron.up")
      }
      .labelStyle(.iconOnly)
      .help("Enclosing Folder (⌘↑)")
      .disabled(location.prefix.isEmpty)
      LocationPath(location: location, browser: browser)
      Spacer(minLength: 8)
      // Search results and the filter bar show their own counts; a failed listing has nothing to count.
      if browser.deepSearch == nil && !isFiltering && model.connectionFailure == nil
        && model.browser.failure == nil
      {
        Text(countSummary(rows))
          .font(.callout)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .fixedSize()
      }
      if model.isConnecting || model.browser.isLoading {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Loading")
      }
      Button {
        browser.toggleFavorite(location)
      } label: {
        Label(
          isFavorite ? "Remove from Favorites" : "Add to Favorites",
          systemImage: isFavorite ? "star.fill" : "star")
      }
      .labelStyle(.iconOnly)
      .help(isFavorite ? "Remove from Favorites (⌃⌘T)" : "Add to Favorites (⌃⌘T)")
      Menu {
        FolderMenuItems(location: location, browser: browser)
      } label: {
        Label("Folder Actions", systemImage: "ellipsis.circle")
      }
      .labelStyle(.iconOnly)
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Folder actions")
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }

  /// "3 folders · 12 files", or Finder's "2 of 15 selected". `rows` already leaves out the folder's own marker.
  private func countSummary(_ rows: [BrowserRow]) -> String {
    var parts: [String]
    if browser.selection.isEmpty {
      let folders = rows.count(where: { $0.isFolder })
      parts = folders > 0 ? [countLabel(folders, "folder")] : []
      parts.append(countLabel(rows.count - folders, "file"))
    } else {
      parts = ["\(browser.selection.count.formatted()) of \(rows.count.formatted()) selected"]
    }
    if model.browser.nextToken != nil { parts.append("more available") }
    return parts.joined(separator: " · ")
  }

  private func failureView(_ failure: S3Failure) -> some View {
    ContentUnavailableView {
      Label(Self.title(for: failure.category), systemImage: "exclamationmark.triangle")
    } description: {
      VStack(spacing: 8) {
        Text(failure.message)
        if let detail = failure.technicalDetail {
          Text(detail)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
      }
    } actions: {
      HStack {
        Button("Try Again") { browser.refresh() }
          .buttonStyle(.borderedProminent)
        if Self.editableCategories.contains(failure.category), let profile = model.selectedProfile {
          Button("Edit Connection…") { browser.editorTarget = EditorTarget(profile: profile) }
        }
        if browser.enclosingLocation != nil {
          Button("Go to Enclosing Folder") { browser.goToEnclosingFolder() }
        }
      }
    }
  }

  private static let editableCategories: [S3Failure.Category] = [
    .authentication, .authorization, .missingCredentials, .regionOrEndpoint, .network, .tls, .timeout,
    .notFound,
  ]

  private static func title(for category: S3Failure.Category) -> String {
    switch category {
    case .authentication: "Credentials rejected"
    case .authorization: "Access denied"
    case .network, .tls, .timeout: "Can't reach the endpoint"
    case .notFound: "Not found"
    case .service: "Service unavailable"
    case .missingCredentials: "Credentials missing"
    case .regionOrEndpoint: "Check bucket and endpoint"
    default: "Something went wrong"
    }
  }
}

/// Context menu for grid cards, table rows and search results; `ids` is the clicked item or the selection
/// containing it.
struct BrowserItemMenu: View {
  let ids: Set<BrowserRow.ID>
  let browser: BrowserController

  var body: some View {
    let files = browser.fileRows(for: ids)
    let folder = ids.count == 1 ? ids.first.flatMap(browser.location(of:)) : nil
    if let folder, let id = ids.first {
      Button("Open") { browser.open(id) }
      FolderMenuItems(location: folder, browser: browser)
      Divider()
      ChangeMenuItems(ids: ids, browser: browser)
    } else {
      if files.count == 1, let file = files.first, let object = file.object, ids.count == 1 {
        if browser.deepSearch != nil {
          Button("Show in Enclosing Folder") { browser.open(file.id) }
        }
        if object.size <= BrowserRow.previewLimit {
          Button("Quick Look") { browser.quickLook(object, versionID: file.versionID) }
        }
      }
      if !files.isEmpty {
        Button("Download…") { browser.download(ids) }
        if files.count == 1 {
          Button("Share Link…") { browser.share(files[0].id) }
        }
        Button("Get Info") { browser.showInfo(ids) }
      }
      if !ids.isEmpty {
        Divider()
        ChangeMenuItems(ids: ids, browser: browser)
        Divider()
        Button("Copy S3 URI") { browser.copyURIs(ids) }
        if !ids.contains(where: \.isFolder) {
          Button("Copy Key") { browser.copyKeys(ids) }
        }
      }
    }
  }
}

/// Rename, Move To and Delete, or Restore for deleted files; disabled with the reason while changes aren't
/// possible.
private struct ChangeMenuItems: View {
  let ids: Set<BrowserRow.ID>
  let browser: BrowserController

  var body: some View {
    let reason = browser.modifyUnavailableReason ?? ""
    if browser.fileRows(for: ids).contains(where: \.isDeleted) {
      // canModify is off in Show Deleted Files, so Restore only needs a connection that allows changes.
      let readOnly = browser.model.selectedProfile?.allowsChanges != true
      Button("Restore") { browser.restore(ids) }
        .disabled(readOnly)
        .help(readOnly ? reason : "")
    } else {
      let unavailable = !browser.canModify
      Button("Rename…") { if let id = ids.first { browser.requestRename(id) } }
        .disabled(unavailable || ids.count != 1)
        .help(reason)
      Button("Move To…") { browser.requestMove(ids) }
        .disabled(unavailable)
        .help(reason)
      Button("Delete…", role: .destructive) { browser.requestDelete(ids) }
        .disabled(unavailable)
        .help(reason)
    }
  }
}

/// Folder actions shared by folder context menus and the location bar.
struct FolderMenuItems: View {
  let location: S3Location
  let browser: BrowserController

  @Environment(\.openWindow) private var openWindow

  var body: some View {
    let inHistory = browser.historyMode != nil
    Button("Upload Files Here…") { browser.uploadFiles(into: location) }
      .disabled(!browser.canModify)
      .help(browser.modifyUnavailableReason ?? "")
    Button("New Folder") { browser.requestNewFolder(in: location) }
      .disabled(!browser.canModify)
      .help(browser.modifyUnavailableReason ?? "")
    Divider()
    Button("Download…") { browser.downloadFolder(location) }
      .disabled(inHistory)
      .help(
        inHistory ? "Folder downloads get current files only. Choose Show Current Files to download." : "")
    if let profileID = browser.model.selectedProfileID {
      let target = InsightTarget(profileID: profileID, location: location)
      Button("Storage Overview…") { openWindow(id: "storage-overview", value: target) }
      Button("Compare with Local Folder…") { openWindow(id: "backup-verify", value: target) }
    }
    Divider()
    Button(browser.model.isFavorite(location) ? "Remove from Favorites" : "Add to Favorites") {
      browser.toggleFavorite(location)
    }
    Button("Copy S3 URI") { browser.copy([location.displayString]) }
  }
}

/// The location bar's path. Every enclosing folder is a button; narrow windows fold the middle into a menu.
private struct LocationPath: View {
  let location: S3Location
  let browser: BrowserController

  /// Ancestor the current drag is over; dropping there moves items up (or uploads Finder files there).
  @State private var dropTarget: S3Location?

  var body: some View {
    // `parent` cuts at "/" scalars, so each ancestor is a byte-exact prefix of this location.
    let path = Array(sequence(first: location, next: \.parent).reversed())
    ViewThatFits(in: .horizontal) {
      crumbs(path, folding: 0..<0)
      if path.count > 3 { crumbs(path, folding: 1..<path.count - 2) }
      crumbs(path, folding: 0..<path.count - 1)
    }
  }

  private func crumbs(_ path: [S3Location], folding folded: Range<Int>) -> some View {
    HStack(spacing: 4) {
      ForEach(path.indices, id: \.self) { index in
        if index == folded.lowerBound || !folded.contains(index) {
          if index > 0 {
            Image(systemName: "chevron.right")
              .imageScale(.small)
              .foregroundStyle(.tertiary)
              .accessibilityHidden(true)
          }
          if folded.contains(index) {
            Menu {
              ForEach(path[folded], id: \.self) { folder in
                Button(folder.displayName, systemImage: folder.prefix.isEmpty ? "shippingbox" : "folder") {
                  browser.model.open(folder)
                }
              }
            } label: {
              Label("Enclosing Folders", systemImage: "ellipsis")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
          } else {
            segment(path[index], isCurrent: index == path.count - 1)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func segment(_ folder: S3Location, isCurrent: Bool) -> some View {
    let label = HStack(spacing: 4) {
      if folder.prefix.isEmpty {
        Image(systemName: "shippingbox")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      Text(folder.displayName)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    // Room for the drop highlight, on every segment so they stay evenly spaced.
    .padding(.horizontal, 3)
    Group {
      if isCurrent {
        label.fontWeight(.semibold)
      } else {
        Button {
          browser.model.open(folder)
        } label: {
          label.foregroundStyle(.secondary)
            .background(
              dropTarget == folder ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 4))
        }
        .dropDestination(for: BrowserDrop.self, isEnabled: browser.canModify) { drops, _ in
          browser.accept(drops, into: folder)
        }
        .dropConfiguration { BrowserController.dropConfiguration($0) }
        .onDropSessionUpdated { session in
          if browser.canModify && session.phase.isOver {
            dropTarget = folder
          } else if dropTarget == folder {
            dropTarget = nil
          }
        }
      }
    }
    .help(folder.displayString)
    .contextMenu { FolderMenuItems(location: folder, browser: browser) }
  }
}

/// While filtering: how many loaded items match, and a way to search the whole folder.
private struct FilterBar: View {
  let rowCount: Int
  let browser: BrowserController

  var body: some View {
    if !browser.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let location = browser.model.browser.location
    {
      HStack(spacing: 10) {
        Text("\(rowCount.formatted()) \(rowCount == 1 ? "match" : "matches") among loaded items")
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 8)
        if browser.historyMode == nil {
          Button("Search All of “\(location.displayName)”") { browser.searchAll() }
            .help("Search every file below this folder (Return)")
        }
      }
      .font(.callout)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
  }
}

/// Under the location bar while browsing previous versions, or why that stopped.
private struct HistoryBanner: View {
  let browser: BrowserController
  /// Deleted rows on screen; nil while filtering, when they'd count only the matches.
  let deletedCount: Int?

  var body: some View {
    if let mode = browser.historyMode {
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          Image(systemName: mode == .deleted ? "trash" : "clock.arrow.circlepath")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text(title(mode))
            .lineLimit(1)
          if let history = browser.folderHistory {
            if history.isRunning {
              ProgressView()
              Text("Loading versions…").foregroundStyle(.secondary)
            } else if history.truncated {
              Label {
                Text("Showing the first \(countLabel(history.versions.count, "version"))")
                  .foregroundStyle(.secondary)
              } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
              }
              .lineLimit(1)
            }
          }
          Spacer(minLength: 8)
          if case .asOf = mode {
            Button("Change Date…") { browser.showsAsOfSheet = true }
          }
          Button("Show Current Files") { browser.exitHistory() }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.fill.quinary)
        Divider()
      }
    } else if let failure = browser.historyFailure {
      StatusBanner(message: failure.message, isWarning: true, actionTitle: "Dismiss") {
        browser.dismissHistoryFailure()
      }
    }
  }

  private func title(_ mode: HistoryMode) -> String {
    switch mode {
    case .deleted:
      guard let deletedCount, browser.folderHistory?.isRunning == false else {
        return "Showing deleted files"
      }
      return deletedCount == 0 ? "No deleted files in this folder" : countLabel(deletedCount, "deleted file")
    case .asOf(let date):
      return "Showing this folder as of \(date.formatted(date: .abbreviated, time: .shortened))"
    }
  }
}

/// Grid footer: shows progress and requests the next page when it scrolls into view.
struct LoadMoreFooter: View {
  let model: AppModel

  var body: some View {
    if let token = model.browser.nextToken, model.browser.failure == nil {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Loading more…").foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.bottom, 20)
      .id(token)
      .onAppear { model.loadNextPage() }
    }
  }
}

/// List overlay while the next page loads; the table itself triggers loading from its last row.
struct LoadingMoreIndicator: View {
  let model: AppModel

  var body: some View {
    if model.browser.isLoading, model.browser.nextToken != nil {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Loading more…")
      }
      .font(.callout)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .glassEffect(.regular, in: .capsule)
      .padding(.bottom, 12)
    }
  }
}

struct StatusBanner: View {
  let message: String
  let isWarning: Bool
  let actionTitle: String
  let action: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      if isWarning {
        Label {
          Text(message)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
      } else {
        ProgressView().controlSize(.small)
        Text(message).lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 8)
      Button(actionTitle, action: action)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }
}

/// Quick Look progress and errors in the content area; the inspector shows them itself when open.
private struct PreviewStatus: View {
  let browser: BrowserController

  var body: some View {
    if !browser.showsInspector {
      if let object = browser.preparingPreview {
        StatusBanner(
          message: "Preparing Quick Look for \((object.key as NSString).lastPathComponent)…",
          isWarning: false, actionTitle: "Cancel"
        ) { browser.cancelPreview() }
      } else if let failure = browser.previewFailure {
        StatusBanner(message: failure.message, isWarning: true, actionTitle: "Dismiss") {
          browser.dismissPreviewFailure()
        }
      }
    }
  }
}

/// Floating bottom bar: selection summary, then transfers. One transfer shows its progress and result inline;
/// several show a summary that opens the list.
private struct TransfersBar: View {
  let browser: BrowserController
  @State private var showsList = false

  var body: some View {
    // The inspector already offers a single item's actions.
    let selection = browser.selection
    if !browser.transfers.isEmpty || selection.count > 1 || (!selection.isEmpty && !browser.showsInspector) {
      GlassEffectContainer(spacing: 8) {
        HStack(spacing: 12) { content }
          .buttonStyle(.glass)
          .padding(10)
          .frame(maxWidth: .infinity)
          .glassEffect(.regular, in: .rect(cornerRadius: 16))
          .padding(.horizontal, 16)
          .padding(.bottom, 8)
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    let transfers = browser.transfers
    if transfers.isEmpty {
      selectionSummary
    } else if transfers.count == 1 {
      TransferRow(transfer: transfers[0], browser: browser)
    } else {
      summary(transfers)
    }
  }

  /// "3 transfers · 2 running" with their combined progress, or how they ended.
  @ViewBuilder
  private func summary(_ transfers: [Transfer]) -> some View {
    let running = transfers.filter(\.isRunning)
    let all = countLabel(transfers.count, "transfer")
    if running.isEmpty {
      let failed = transfers.count { $0.result?.succeeded == false }
      Label {
        Text(failed == 0 ? "\(all) finished" : "\(all) finished · \(failed.formatted()) failed")
      } icon: {
        Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .foregroundStyle(failed == 0 ? Color.green : Color.orange)
      }
      .font(.callout)
    } else {
      TransferProgressBar(progress: Self.combined(running))
        .accessibilityLabel("Transfers")
      Text("\(all) · \(running.count.formatted()) running")
        .font(.callout)
        .monospacedDigit()
        .lineLimit(1)
    }
    Spacer(minLength: 8)
    Button("Show All", systemImage: "chevron.up") { showsList.toggle() }
      .popover(isPresented: $showsList, arrowEdge: .top) { TransfersList(browser: browser) }
      // Closed with the summary, so it doesn't reopen by itself when several transfers run again.
      .onDisappear { showsList = false }
  }

  /// Running transfers as one: their files and bytes added up.
  private static func combined(_ transfers: [Transfer]) -> BatchDownloadProgress {
    BatchDownloadProgress(
      completedFiles: transfers.reduce(0) { $0 + $1.progress.completedFiles },
      totalFiles: transfers.reduce(0) { $0 + $1.progress.totalFiles },
      receivedBytes: transfers.reduce(0) { $0 + $1.progress.receivedBytes },
      totalBytes: transfers.reduce(0) { $0 + $1.progress.totalBytes })
  }

  @ViewBuilder
  private var selectionSummary: some View {
    let files = browser.objects(for: browser.selection)
    let bytes = files.reduce(Int64.zero) { $0 + $1.size }.formatted(.byteCount(style: .file))
    let count = browser.selection.count
    Text(
      files.isEmpty
        ? "\(countLabel(count, "folder")) selected"
        : "\(countLabel(count, files.count == count ? "file" : "item")) selected · \(bytes)"
    )
    .font(.callout)
    .lineLimit(1)
    Spacer(minLength: 8)
    Button("Deselect All") { browser.selection = [] }
    Button("Download…", systemImage: "arrow.down.to.line") { browser.downloadSelection() }
      .buttonStyle(.glassProminent)
      .disabled(!browser.canDownloadSelection)
  }
}

/// Every transfer, oldest first, each with its own Cancel or result actions.
private struct TransfersList: View {
  let browser: BrowserController

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(spacing: 0) {
          ForEach(browser.transfers) { transfer in
            if transfer.id != browser.transfers.first?.id { Divider() }
            HStack(spacing: 12) { TransferRow(transfer: transfer, browser: browser) }
              .padding(.vertical, 8)
          }
        }
        .padding(.horizontal, 16)
      }
      .frame(maxHeight: 320)
      .fixedSize(horizontal: false, vertical: true)
      Divider()
      HStack {
        Spacer()
        Button("Clear Finished") { browser.clearFinishedTransfers() }
          .disabled(browser.transfers.allSatisfy(\.isRunning))
      }
      .padding(12)
    }
    .frame(width: 520)
    // The bar's glass buttons don't belong on the popover's own surface.
    .buttonStyle(.automatic)
    .controlSize(.small)
  }
}

/// One transfer's progress and Cancel, then its result with Copy Failed Keys, Show in Finder and Dismiss.
private struct TransferRow: View {
  let transfer: Transfer
  let browser: BrowserController

  var body: some View {
    if let result = transfer.result {
      Label {
        Text(result.message).lineLimit(1).truncationMode(.middle)
      } icon: {
        Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .foregroundStyle(result.succeeded ? Color.green : Color.orange)
      }
      .font(.callout)
      Spacer(minLength: 8)
      if !result.failedKeys.isEmpty {
        Button("Copy Failed Keys") { browser.copy(result.failedKeys) }
      }
      if let reveal = result.reveal {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([reveal]) }
      }
      Button("Dismiss") { browser.dismissTransfer(transfer.id) }
    } else {
      TransferProgressBar(progress: transfer.progress)
        .accessibilityLabel(Self.verb(transfer.kind))
      Text(Self.describe(transfer.kind, transfer.progress, name: transfer.name))
        .font(.callout)
        .monospacedDigit()
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      Button("Cancel") { browser.cancelTransfer(transfer.id) }
    }
  }

  private static func verb(_ kind: TransferKind) -> String {
    switch kind {
    case .download: "Downloading"
    case .upload: "Uploading"
    case .move: "Moving"
    case .copy: "Copying"
    case .restore: "Restoring"
    case .delete: "Deleting"
    }
  }

  /// "Downloading photo.jpg · 1 MB of 3 MB", "Uploading 1 MB of 3 MB · 2 of 5 files", "Deleting 3 of 40 files",
  /// "Moving photos · Listing files…".
  private static func describe(_ kind: TransferKind, _ progress: BatchDownloadProgress, name: String?)
    -> String
  {
    let action = verb(kind)
    guard progress.totalFiles > 0 else {
      return name.map { "\(action) \($0) · Listing files…" } ?? "Listing files…"
    }
    let bytes =
      progress.totalBytes > 0
      ? "\(progress.receivedBytes.formatted(.byteCount(style: .file))) of \(progress.totalBytes.formatted(.byteCount(style: .file)))"
      : nil
    let files = "\(progress.completedFiles.formatted()) of \(countLabel(progress.totalFiles, "file"))"
    let details = [name, bytes, progress.totalFiles > 1 ? files : nil].compactMap { $0 }
    return details.isEmpty ? "\(action)…" : "\(action) \(details.joined(separator: " · "))"
  }
}

private struct TransferProgressBar: View {
  let progress: BatchDownloadProgress

  var body: some View {
    Group {
      if progress.totalFiles == 0 {
        ProgressView()  // Listing a folder before the transfer starts.
      } else if progress.totalBytes > 0 {
        ProgressView(value: Double(progress.receivedBytes), total: Double(progress.totalBytes))
      } else {
        // Deletes and empty files move no bytes.
        ProgressView(value: Double(progress.completedFiles), total: Double(progress.totalFiles))
      }
    }
    .progressViewStyle(.linear)
    .frame(width: 140)
  }
}
