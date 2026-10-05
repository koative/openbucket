import AppKit
import OpenBucketCore
import SwiftUI

/// Menu-bar commands; each mirrors a toolbar, context-menu or keyboard action in the browser.
struct BrowserCommands: Commands {
  let model: AppModel
  @Bindable var browser: BrowserController

  @AppStorage("showsPreviews") private var showsPreviews = true
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    // Text-editing shortcuts like ⌘↑/⌘↓ must reach the fields of an open sheet.
    let browsing = model.browser.location != nil && !browser.isSheetPresented
    let folder = browsing ? browser.folderTarget : nil
    let insight = folder.flatMap { folder in
      model.selectedProfileID.map { InsightTarget(profileID: $0, location: folder) }
    }
    // …and ⌘↑/⌘↓ must reach the toolbar search field while it's being edited.
    let navigating = browsing && !browser.isSearchFocused
    let changesUnavailable = !browsing || !browser.canModify
    let _ = MenuBarRefresh.schedule()

    CommandGroup(replacing: .newItem) {
      Button("New Connection…") { browser.editorTarget = EditorTarget(profile: nil) }
        .keyboardShortcut("n")
        .disabled(browser.isSheetPresented)
      Button("Edit Connection…") { browser.editorTarget = EditorTarget(profile: model.selectedProfile) }
        .disabled(model.selectedProfile == nil || browser.isSheetPresented)
      Button("Go to Location…") { browser.showsLocationSheet = true }
        .keyboardShortcut("g", modifiers: [.command, .shift])
        .disabled(model.selectedProfile == nil || browser.isSheetPresented)
      Divider()
      Button("Download…") { browser.downloadSelection() }
        .disabled(!browsing || !browser.canDownloadSelection)
      Button("Share Link…") {
        if let row = browser.quickLookTarget { browser.share(row.id) }
      }
      .disabled(!browsing || browser.quickLookTarget == nil)
      Divider()
      Button("Upload Files…") { browser.uploadFiles() }
        .keyboardShortcut("u")
        .disabled(changesUnavailable)
      Button("New Folder") { browser.requestNewFolder() }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(changesUnavailable)
      Divider()
      Button("Storage Overview…") {
        if let insight { openWindow(id: "storage-overview", value: insight) }
      }
      .disabled(insight == nil)
      Button("Compare with Local Folder…") {
        if let insight { openWindow(id: "backup-verify", value: insight) }
      }
      .disabled(insight == nil)
    }

    CommandGroup(after: .pasteboard) {
      Divider()
      Button("Rename…") { if let id = browser.selection.first { browser.requestRename(id) } }
        .disabled(changesUnavailable || browser.selection.count != 1)
      Button("Move To…") { browser.requestMove(browser.selection) }
        .disabled(changesUnavailable || browser.selection.isEmpty)
      // ⌘⌫ must still delete text while the search field is being edited.
      Button("Delete…") { browser.requestDelete(browser.selection) }
        .keyboardShortcut(.delete)
        .disabled(changesUnavailable || !navigating || browser.selection.isEmpty)
      Button("Restore") { browser.restore(browser.selection) }
        .disabled(!browsing || !browser.canRestoreSelection)
      Divider()
      // `.searchable` adds no Find item on macOS, so ⌘F needs its own command.
      Button("Find…") { browser.focusSearch() }
        .keyboardShortcut("f")
        .disabled(!browsing)
    }

    CommandGroup(before: .toolbar) {
      // Search results are always a list.
      Toggle("as Grid", isOn: layoutBinding(.grid))
        .keyboardShortcut("1")
        .disabled(browser.deepSearch != nil)
      Toggle("as List", isOn: layoutBinding(.list))
        .keyboardShortcut("2")
        .disabled(browser.deepSearch != nil)
      Divider()
      Menu("Sort By") {
        Picker("Sort By", selection: $browser.sortKey) {
          Text("Name").tag(\BrowserRow.name as PartialKeyPath<BrowserRow>)
          Text("Size").tag(\BrowserRow.sortSize as PartialKeyPath<BrowserRow>)
          Text("Modified").tag(\BrowserRow.sortModified as PartialKeyPath<BrowserRow>)
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        Toggle("Ascending", isOn: $browser.sortsAscending)
      }
      Divider()
      Button(browser.showsInspector ? "Hide Inspector" : "Show Inspector") { browser.showsInspector.toggle() }
        .keyboardShortcut("i", modifiers: [.command, .option])
      Toggle("Show Previews", isOn: $showsPreviews)
      Divider()
      Toggle(
        "Show Deleted Files",
        isOn: Binding(
          get: { browser.historyMode == .deleted }, set: { browser.historyMode = $0 ? .deleted : nil })
      )
      .keyboardShortcut(".", modifiers: [.command, .shift])
      .disabled(!browsing)
      Button("Browse As Of…") { browser.showsAsOfSheet = true }
        .disabled(!browsing)
      Divider()
      Button("Refresh") { browser.refresh() }
        .keyboardShortcut("r")
        .disabled(model.selectedProfile == nil)
      Divider()
    }

    CommandMenu("Go") {
      Button("Back") { browser.goBack() }
        .keyboardShortcut("[")
        .disabled(!browser.history.canGoBack || browser.isSheetPresented)
      Button("Forward") { browser.goForward() }
        .keyboardShortcut("]")
        .disabled(!browser.history.canGoForward || browser.isSheetPresented)
      Button("Enclosing Folder") { browser.goToEnclosingFolder() }
        .keyboardShortcut(.upArrow)
        .disabled(!navigating || browser.enclosingLocation == nil)
      Button(folder.map { model.isFavorite($0) } == true ? "Remove from Favorites" : "Add to Favorites") {
        if let folder { browser.toggleFavorite(folder) }
      }
      .keyboardShortcut("t", modifiers: [.command, .control])
      .disabled(folder == nil)
      Divider()
      Button("Open") { browser.openSelection() }
        .keyboardShortcut(.downArrow)
        .disabled(!navigating || browser.selection.count != 1)
      Button("Quick Look") { browser.toggleQuickLook() }
        .keyboardShortcut("y")
        .disabled(!browsing || (browser.quickLookTarget == nil && browser.previewURL == nil))
    }
  }

  private func layoutBinding(_ layout: BrowserLayout) -> Binding<Bool> {
    let browser = browser
    return Binding(get: { browser.layout == layout }, set: { if $0 { browser.layout = layout } })
  }
}

/// SwiftUI applies Commands changes to the menu bar only when a menu opens, so a shortcut whose item became
/// enabled since then does nothing (⌘U right after opening a folder). Running the menus' own update after
/// every Commands evaluation keeps key equivalents in step with the state.
@MainActor private enum MenuBarRefresh {
  private static var scheduled = false

  static func schedule() {
    guard !scheduled else { return }
    scheduled = true
    DispatchQueue.main.async {
      scheduled = false
      for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
        menu.delegate?.menuNeedsUpdate?(menu)
      }
    }
  }
}
