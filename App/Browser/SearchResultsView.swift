import OpenBucketCore
import SwiftUI

/// Matches anywhere below the searched folder, with the browser's selection, inspector, Quick Look,
/// download and context menu. Opening a match shows it in its folder.
struct SearchResultsView: View {
  let rows: [BrowserRow]
  let search: DeepSearch
  @Bindable var browser: BrowserController

  /// The user cancelled; the results are partial.
  @State private var stopped = false

  var body: some View {
    VStack(spacing: 0) {
      if let failure = search.failure {
        StatusBanner(message: failure.message, isWarning: true, actionTitle: "Try Again") {
          browser.searchAll()
        }
      } else {
        header
      }
      Divider()
      if rows.isEmpty && !search.isRunning {
        ContentUnavailableView.search(text: browser.searchText)
      } else {
        table
      }
    }
    .onChange(of: search.isRunning) { _, running in
      if running { stopped = false }
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      if search.isRunning {
        ProgressView().controlSize(.small)
      }
      Text(summary)
        .monospacedDigit()
        .lineLimit(1)
      if search.truncated {
        Label {
          Text("Showing the first \(matches) · stopped after checking \(countLabel(search.scanned, "item"))")
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .lineLimit(1)
      }
      Spacer(minLength: 8)
      if search.isRunning {
        Button("Cancel") {
          search.cancel()
          stopped = true
        }
      }
    }
    .font(.callout)
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }

  private var matches: String {
    "\(search.results.count.formatted()) \(search.results.count == 1 ? "match" : "matches")"
  }

  private var summary: String {
    let folder = "“\(search.location.displayName)”"
    if search.isRunning {
      return "Searching \(folder)… \(matches) · \(countLabel(search.scanned, "item")) checked"
    }
    if stopped {
      return "Stopped after checking \(countLabel(search.scanned, "item")) · \(matches) so far"
    }
    return "\(matches) in \(folder) and its subfolders"
  }

  private var table: some View {
    Table(of: BrowserRow.self, selection: $browser.selection, sortOrder: $browser.sortOrder) {
      TableColumn("Name", value: \.name) { row in
        BrowserNameCell(row: row)
      }
      .width(min: 160, ideal: 280)

      TableColumn("Folder") { row in
        let folder = folderPath(row)
        Text(folder)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(folder)
      }
      .width(min: 120, ideal: 220)

      TableColumn("Size", value: \.sortSize) { row in
        BrowserSizeCell(row: row)
      }
      .width(90)
      .alignment(.numeric)

      TableColumn("Modified", value: \.sortModified) { row in
        BrowserModifiedCell(row: row)
      }
      .width(min: 150, ideal: 170)

      TableColumn("Kind") { row in
        BrowserKindCell(row: row)
      }
      .width(min: 80, ideal: 120)
    } rows: {
      ForEach(rows) { row in
        TableRow(row)
          .draggable(browser.dragItem(row))
      }
    }
    .tableStyle(.inset)
    .alternatingRowBackgrounds(.disabled)
    .contextMenu(forSelectionType: BrowserRow.ID.self) { ids in
      BrowserItemMenu(ids: ids, browser: browser)
    } primaryAction: { ids in
      if ids.count == 1, let id = ids.first { browser.open(id) }
    }
    .onKeyPress(.space) {
      guard browser.quickLookTarget != nil || browser.previewURL != nil else { return .ignored }
      browser.toggleQuickLook()
      return .handled
    }
  }

  /// "photos/2024" for a match in photos/2024/ when searching photos/.
  private func folderPath(_ row: BrowserRow) -> String {
    let relative = relativeKey(BrowserRow.folder(of: row.fullKey), under: search.location.prefix) ?? ""
    return ([search.location.displayName] + relative.split(separator: "/").map(String.init))
      .joined(separator: "/")
  }
}
