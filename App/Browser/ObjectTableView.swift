import OpenBucketCore
import SwiftUI

/// List view: native multi-selection, double-click/Return opens, Space toggles Quick Look.
struct ObjectTableView: View {
  let rows: [BrowserRow]
  @Bindable var browser: BrowserController

  var body: some View {
    let lastID = rows.last?.id
    ScrollViewReader { proxy in
      Table(of: BrowserRow.self, selection: $browser.selection, sortOrder: $browser.sortOrder) {
        TableColumn("Name", value: \.name) { row in
          BrowserNameCell(row: row)
            .onAppear { if row.id == lastID { browser.model.loadNextPage() } }
        }
        .width(min: 160, ideal: 320)

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
          // While changes are allowed every row takes drops, so a drop on a file row lands in the current folder
          // instead of depending on the table passing it to the list behind it.
          if browser.canModify {
            TableRow(row)
              .draggable(browser.dragItem(row))
              .dropDestination(for: BrowserDrop.self) { drops in
                if let folder = browser.location(of: row.id) ?? browser.model.browser.location {
                  browser.accept(drops, into: folder)
                }
              }
          } else {
            TableRow(row)
              .draggable(browser.dragItem(row))
          }
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
      .overlay(alignment: .bottom) {
        LoadingMoreIndicator(model: browser.model)
      }
      .onChange(of: browser.revealedID) { _, id in
        if let id { proxy.scrollTo(id) }
      }
    }
  }
}

/// Name column: artwork and name; deleted files are dimmed and marked with a trailing trash symbol.
struct BrowserNameCell: View {
  let row: BrowserRow

  var body: some View {
    HStack(spacing: 6) {
      BrowserArtwork(row: row, symbolSize: 14, showsVideoBadge: false)
        .frame(width: 18, height: 18)
        .clipShape(.rect(cornerRadius: 4, style: .continuous))
        .opacity(row.isDeleted ? 0.5 : 1)
      Text(row.name)
        .foregroundStyle(row.isDeleted ? .secondary : .primary)
        .lineLimit(1)
        .truncationMode(.middle)
      if row.isDeleted {
        Image(systemName: "trash")
          .foregroundStyle(.secondary)
          .accessibilityLabel("Deleted")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .help(row.fullKey)
    .accessibilityElement(children: .combine)
  }
}

struct BrowserSizeCell: View {
  let row: BrowserRow

  var body: some View {
    Text(row.sizeLabel ?? "—")
      .monospacedDigit()
      .foregroundStyle(.secondary)
  }
}

struct BrowserKindCell: View {
  let row: BrowserRow

  var body: some View {
    Text(row.kindLabel)
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }
}

struct BrowserModifiedCell: View {
  let row: BrowserRow

  var body: some View {
    Group {
      if let date = row.object?.lastModified {
        Text(date, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
      } else {
        Text("—")
      }
    }
    .foregroundStyle(.secondary)
  }
}
