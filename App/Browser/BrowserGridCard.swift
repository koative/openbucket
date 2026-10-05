import AppKit
import OpenBucketCore
import SwiftUI

/// Icon view: click selects, ⌘-click toggles, ⇧-click extends, double-click or Return opens,
/// arrow keys move, Space toggles Quick Look, Edit ▸ Select All selects every loaded item.
struct BrowserGrid: View {
  let rows: [BrowserRow]
  let browser: BrowserController

  @FocusState private var isFocused: Bool
  @Environment(\.appearsActive) private var appearsActive
  @State private var columns = 1
  /// The folder card a Finder drag is over.
  @State private var dropTargetID: BrowserRow.ID?

  nonisolated private static let minimumWidth: CGFloat = 200
  nonisolated private static let spacing: CGFloat = 16

  var body: some View {
    let ids = rows.map(\.id)
    ScrollViewReader { proxy in
      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: Self.minimumWidth), spacing: Self.spacing)],
          spacing: Self.spacing
        ) {
          ForEach(rows) { row in
            BrowserGridCard(
              row: row, isSelected: browser.selection.contains(row.id),
              isEmphasized: isFocused && appearsActive,
              isDropTarget: dropTargetID == row.id
            )
            .id(row.id)
            .gesture(TapGesture(count: 2).onEnded { browser.open(row.id) })
            .simultaneousGesture(
              TapGesture().onEnded {
                isFocused = true
                let flags = NSEvent.modifierFlags
                browser.click(
                  row.id, in: ids, extend: flags.contains(.shift), toggle: flags.contains(.command))
              }
            )
            .accessibilityAction { browser.click(row.id, in: ids, extend: false, toggle: false) }
            .accessibilityAction(named: "Open") { browser.open(row.id) }
            .contextMenu { BrowserItemMenu(ids: browser.targets(for: row.id), browser: browser) }
            .draggable(containerItemID: row.id)
            .dropDestination(for: BrowserDrop.self, isEnabled: row.isFolder && browser.canModify) {
              drops, _ in
              if let folder = browser.location(of: row.id) { browser.accept(drops, into: folder) }
            }
            .onDropSessionUpdated { session in
              // A folder dragged over its own card isn't a target, as in Finder.
              let isOwnCard =
                session.localSession?.draggedItemIDs(for: BrowserRow.ID.self).contains(row.id) == true
              if row.isFolder && browser.canModify && session.phase.isOver && !isOwnCard {
                dropTargetID = row.id
              } else if dropTargetID == row.id {
                dropTargetID = nil
              }
            }
          }
        }
        // Dragging a selected card drags the whole selection: files also out to Finder, folders only to move.
        .dragContainer(for: S3FileDrag.self) { ids in browser.dragItems(ids) }
        .dragContainerSelection(Array(browser.selection))
        // Same arithmetic as `.adaptive`, so ↑/↓ move by exactly one visual row.
        .onGeometryChange(for: Int.self) {
          max(1, Int(($0.size.width + Self.spacing) / (Self.minimumWidth + Self.spacing)))
        } action: {
          columns = $0
        }
        .padding(16)

        LoadMoreFooter(model: browser.model)
      }
      .focusable(interactions: .edit)
      .focused($isFocused)
      .focusEffectDisabled()
      .onAppear { isFocused = true }
      .onMoveCommand { direction in
        let offset =
          switch direction {
          case .left: -1
          case .right: 1
          case .up: -columns
          case .down: columns
          @unknown default: 0
          }
        if let id = browser.moveSelection(by: offset, in: ids) { proxy.scrollTo(id) }
      }
      .onKeyPress(.return) {
        guard browser.selection.count == 1 else { return .ignored }
        browser.openSelection()
        return .handled
      }
      .onKeyPress(.space) {
        guard browser.quickLookTarget != nil || browser.previewURL != nil else { return .ignored }
        browser.toggleQuickLook()
        return .handled
      }
      .onCommand(#selector(NSText.selectAll(_:))) { browser.selectAll(ids) }
      // Top of the grid on navigation only; appended pages must not move the user's place.
      .onChange(of: browser.model.browser.location) {
        guard let first = ids.first else { return }
        withTransaction(\.disablesAnimations, true) { proxy.scrollTo(first, anchor: .top) }
      }
      .onChange(of: browser.revealedID) { _, id in
        if let id { proxy.scrollTo(id) }
      }
    }
  }
}

/// Finder icon-view look: a gray box behind the selected thumbnail and a highlighted name, accent while the grid
/// has focus in the active window (`isEmphasized`), gray otherwise.
struct BrowserGridCard: View {
  let row: BrowserRow
  let isSelected: Bool
  var isEmphasized = false
  var isDropTarget = false

  @State private var isHovered = false

  private static let radius: CGFloat = 12
  private static let inset: CGFloat = 4

  var body: some View {
    let box = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
    VStack(alignment: .leading, spacing: 4) {
      Color.clear
        .aspectRatio(4 / 3, contentMode: .fit)
        .overlay { BrowserArtwork(row: row) }
        // Concentric with the box: inner radius = outer radius − inset.
        .clipShape(.rect(cornerRadius: Self.radius - Self.inset, style: .continuous))
        .opacity(row.isDeleted ? 0.5 : 1)
        .overlay(alignment: .topLeading) {
          if row.isDeleted {
            Image(systemName: "trash.fill")
              .font(.caption)
              .padding(6)
              .background(.regularMaterial, in: .circle)
              .padding(6)
              .accessibilityHidden(true)
          }
        }
        .padding(Self.inset)
        .background(boxFill, in: box)
        .overlay {
          if isDropTarget { box.strokeBorder(Color.accentColor, lineWidth: 2) }
        }
      // The 4pt text inset lines the glyphs up with the artwork inside the box.
      VStack(alignment: .leading, spacing: 2) {
        Text(row.name)
          .font(.body.weight(.medium))
          .foregroundStyle(nameStyle)
          .lineLimit(1)
          .truncationMode(.middle)
          .padding(.horizontal, Self.inset)
          .padding(.vertical, 1)
          .background(nameHighlight, in: .rect(cornerRadius: 4))
        Text(
          [row.isDeleted ? "Deleted" : nil, row.kindLabel, row.sizeLabel].compactMap { $0 }
            .joined(separator: " · ")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, Self.inset)
      }
    }
    .contentShape(.rect)
    .onHover { isHovered = $0 }
    .help(row.fullKey)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var boxFill: Color {
    if isDropTarget { return Color.accentColor.opacity(0.2) }
    if isSelected { return Color(nsColor: .unemphasizedSelectedContentBackgroundColor) }
    return isHovered ? Color.primary.opacity(0.05) : .clear
  }

  private var nameHighlight: Color {
    guard isSelected else { return .clear }
    return Color(
      nsColor: isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor)
  }

  private var nameStyle: Color {
    // The emphasized highlight is the accent colour, so the name turns white like Finder's.
    if isSelected && isEmphasized { return .white }
    return row.isDeleted ? .secondary : .primary
  }
}

extension DropSession.Phase {
  /// The drag is over the destination (not leaving or already dropped).
  var isOver: Bool {
    switch self {
    case .entering, .active: true
    default: false
    }
  }
}
