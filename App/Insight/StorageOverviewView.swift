import OpenBucketCore
import SwiftUI
import UniformTypeIdentifiers

/// Sizes below a folder: a treemap (or table) of its children, storage classes and the largest files.
struct StorageOverviewView: View {
  let model: AppModel
  let target: InsightTarget

  @Environment(\.openWindow) private var openWindow
  @State private var source: AppModel.DownloadSource?
  @State private var sourceFailure: S3Failure?
  /// Drill-down path, outermost first; the last scan is shown. Earlier ones keep their totals for going back.
  @State private var scans: [StorageScan] = []
  /// Scans stopped before they finished, so their totals are partial. Held strongly so identity is stable.
  @State private var stopped: [StorageScan] = []
  @State private var mode = Mode.treemap
  @State private var selectedFiles: Set<ObjectSummary.ID> = []

  private enum Mode: Hashable {
    case treemap, list
  }

  private var location: S3Location { target.location }

  var body: some View {
    Group {
      if let scan = scans.last {
        overview(scan)
      } else if let sourceFailure {
        ContentUnavailableView {
          Label("Couldn't connect", systemImage: "externaldrive.badge.xmark")
        } description: {
          Text(sourceFailure.message)
        } actions: {
          Button("Try Again") { Task { await connectAndScan() } }
            .buttonStyle(.glassProminent)
        }
      } else {
        ProgressView("Connecting…").frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .navigationTitle("Storage Overview")
    .navigationSubtitle(scans.last?.location.displayString ?? location.displayString)
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Button {
          goBack(to: scans.count - 2)
        } label: {
          Label("Back", systemImage: "chevron.left")
        }
        .help("Back to the enclosing folder")
        .disabled(scans.count < 2)
      }
      ToolbarItem(placement: .primaryAction) {
        Picker("View", selection: $mode) {
          Label("Treemap", systemImage: "square.grid.3x1.below.line.grid.1x2").tag(Mode.treemap)
          Label("List", systemImage: "list.bullet").tag(Mode.list)
        }
        .pickerStyle(.segmented)
        .help("Show as treemap or list")
      }
      ToolbarItem(placement: .primaryAction) {
        if let scan = scans.last, scan.isRunning {
          Button {
            stop(scan)
          } label: {
            Label("Stop", systemImage: "xmark")
          }
          .help("Stop scanning and keep the totals listed so far")
          .keyboardShortcut(".", modifiers: .command)
        } else {
          Button {
            if let scan = scans.last { rescan(scan) }
          } label: {
            Label("Rescan", systemImage: "arrow.clockwise")
          }
          .help("Scan this folder again")
          .disabled(scans.isEmpty)
        }
      }
    }
    .task {
      if scans.isEmpty { await connectAndScan() }
    }
    .onDisappear {
      for scan in scans where scan.isRunning {
        stop(scan)
      }
    }
  }

  @ViewBuilder
  private func overview(_ scan: StorageScan) -> some View {
    VStack(spacing: 0) {
      if scans.count > 1 || scan.summary.objectCount > 0 {
        header(scan)
        Divider()
      }
      if scan.summary.objectCount == 0 {
        if let failure = scan.failure {
          ContentUnavailableView {
            Label("Couldn't scan this folder", systemImage: "exclamationmark.triangle")
          } description: {
            VStack(spacing: 8) {
              Text(failure.message)
              if let detail = failure.technicalDetail {
                Text(detail).font(.caption.monospaced()).textSelection(.enabled)
              }
            }
          } actions: {
            Button("Try Again") { rescan(scan) }
              .buttonStyle(.glassProminent)
          }
        } else if scan.isRunning {
          ProgressView("Scanning…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if stopped.contains(where: { $0 === scan }) {
          ContentUnavailableView {
            Label("Scan stopped", systemImage: "stop.circle")
          } description: {
            Text("No files were listed before the scan stopped.")
          } actions: {
            Button("Scan Again") { rescan(scan) }
          }
        } else {
          ContentUnavailableView(
            "This folder is empty", systemImage: "folder",
            description: Text("There are no files here."))
        }
      } else {
        HSplitView {
          Group {
            switch mode {
            case .treemap:
              TreemapView(nodes: scan.summary.children, total: scan.summary.totalBytes) { open($0, in: scan) }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            case .list:
              ChildrenTable(nodes: scan.summary.children, total: scan.summary.totalBytes) {
                open($0, in: scan)
              }
            }
          }
          .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
          sidebar(scan.summary)
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 440)
        }
      }
    }
  }

  /// Breadcrumb when drilled in, the totals with the scan state, and a notice when the totals are partial.
  /// The full location is the window subtitle, so it isn't repeated here.
  private func header(_ scan: StorageScan) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if scans.count > 1 {
        breadcrumb
      }
      if scan.summary.objectCount > 0 {
        HStack(spacing: 8) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(scan.summary.totalBytes.formatted(.byteCount(style: .file)))
              .font(.title3.weight(.semibold))
            Text(verbatim: "in \(countLabel(scan.summary.objectCount, "object"))")
              .foregroundStyle(.secondary)
          }
          .monospacedDigit()
          .accessibilityElement(children: .combine)
          Spacer(minLength: 12)
          if scan.isRunning {
            ProgressView()
              .controlSize(.small)
              .accessibilityHidden(true)
            Text("Scanning…")
              .foregroundStyle(.secondary)
          }
        }
        partialNotice(scan)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  @ViewBuilder
  private func partialNotice(_ scan: StorageScan) -> some View {
    if let failure = scan.failure {
      notice(
        "\(failure.message) Totals cover only the objects listed.", symbol: "exclamationmark.octagon.fill"
      )
      .help(failure.technicalDetail ?? failure.message)
    } else if scan.truncated {
      notice(
        "Stopped after \(countLabel(scan.scannedObjects, "object")), the scan limit. Totals cover only those.",
        symbol: "exclamationmark.triangle.fill")
    } else if !scan.isRunning, stopped.contains(where: { $0 === scan }) {
      notice(
        "Scan stopped. Totals cover only the objects listed so far.", symbol: "exclamationmark.triangle.fill")
    }
  }

  private func notice(_ text: String, symbol: String) -> some View {
    Label {
      Text(verbatim: text).foregroundStyle(.secondary)
    } icon: {
      Image(systemName: symbol).symbolRenderingMode(.multicolor)
    }
    .font(.callout)
  }

  private var breadcrumb: some View {
    HStack(spacing: 2) {
      ForEach(scans.indices, id: \.self) { index in
        let name = Self.crumbName(scans[index].location)
        if index < scans.count - 1 {
          Button(name) { goBack(to: index) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(scans[index].location.displayString)
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        } else {
          Text(name).fontWeight(.semibold)
        }
      }
    }
    .font(.callout)
    .lineLimit(1)
    .truncationMode(.middle)
  }

  private func sidebar(_ summary: StorageSummary) -> some View {
    List(selection: $selectedFiles) {
      Section("Storage classes") {
        storageClasses(summary)
      }
      Section("Largest files") {
        ForEach(summary.largest) { object in
          largestFileRow(object, prefix: summary.prefix)
            .tag(object.id)
        }
      }
    }
    .listStyle(.inset)
    .scrollContentBackground(.hidden)
    .contextMenu(forSelectionType: ObjectSummary.ID.self) { ids in
      if ids.count == 1 {
        Button("Reveal in Browser") { reveal(ids) }
      }
    } primaryAction: { ids in
      reveal(ids)
    }
  }

  /// A stacked bar and one row per class. With a single class the bar would only say 100%, so it's left out,
  /// along with the swatch that would key into it.
  @ViewBuilder
  private func storageClasses(_ summary: StorageSummary) -> some View {
    let classes = summary.storageClasses
    let several = classes.count > 1
    if several {
      GeometryReader { proxy in
        let width = proxy.size.width - CGFloat(classes.count - 1) * 2
        HStack(spacing: 2) {
          ForEach(classes, id: \.name) { item in
            storageClassColor(item.name)
              .frame(width: max(2, width * CGFloat(item.bytes) / CGFloat(max(summary.totalBytes, 1))))
          }
        }
      }
      .frame(height: 8)
      .clipShape(.capsule)
      .padding(.vertical, 4)
      .listRowSeparator(.hidden)
      .accessibilityHidden(true)
    }
    ForEach(classes, id: \.name) { item in
      HStack(spacing: 8) {
        if several {
          Circle()
            .fill(storageClassColor(item.name))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(StorageClassName.display(item.name))
            .lineLimit(1)
          Text(countLabel(item.objectCount, "object"))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        VStack(alignment: .trailing, spacing: 2) {
          Text(item.bytes.formatted(.byteCount(style: .file)))
          if several {
            Text(share(item.bytes, of: summary.totalBytes))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .monospacedDigit()
      }
      .help(item.name)
      .accessibilityElement(children: .combine)
    }
  }

  private func largestFileRow(_ object: ObjectSummary, prefix: String) -> some View {
    let path = relativeKey(object.key, under: prefix) ?? object.key
    let slash = path.lastIndex(of: "/")
    let name = slash.map { String(path[path.index(after: $0)...]) } ?? path
    let folder = slash.map { String(path[..<$0]) } ?? ""
    let kind = TileKind(name: name, isFolder: false)
    return HStack(spacing: 8) {
      Image(systemName: kind.symbol)
        .foregroundStyle(kind.color)
        .frame(width: 16)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(name)
          .lineLimit(1)
          .truncationMode(.middle)
        // Files directly in the scanned folder have no folder to name.
        if !folder.isEmpty {
          Text(folder)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 8)
      Text(object.size.formatted(.byteCount(style: .file)))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .help(object.key)
    .accessibilityElement(children: .combine)
  }

  // MARK: Actions

  /// Resolves the window's own connection once, independent of the main window's selection, then scans.
  private func connectAndScan() async {
    sourceFailure = nil
    do {
      source = try await model.downloadSource(for: target)
      startScan(location)
    } catch {
      sourceFailure = AppModel.failure(for: error)
    }
  }

  /// Scans `folder` with the window's connection, pushed onto the drill-down path.
  private func startScan(_ folder: S3Location) {
    guard let source else { return }
    let scan = StorageScan(repository: model.repository, source: source, location: folder)
    scans.append(scan)
    scan.start()
  }

  private func rescan(_ scan: StorageScan) {
    scan.cancel()
    scans.removeLast()
    startScan(scan.location)
  }

  private func stop(_ scan: StorageScan) {
    scan.cancel()
    stopped.append(scan)
  }

  private func open(_ node: StorageSummary.Node, in scan: StorageScan) {
    guard node.isFolder,
      let folder = try? S3Location(
        bucket: scan.location.bucket, prefix: scan.location.prefix + node.name + "/")
    else { return }
    startScan(folder)
  }

  private func goBack(to index: Int) {
    guard scans.indices.contains(index) else { return }
    for scan in scans[(index + 1)...] { scan.cancel() }
    scans.removeSubrange((index + 1)...)
  }

  private func reveal(_ ids: Set<ObjectSummary.ID>) {
    guard ids.count == 1, let object = scans.last?.summary.largest.first(where: { $0.id == ids.first }),
      model.openLink("s3://\(location.bucket)/\(object.key)", inProfile: target.profileID)
    else { return }
    openWindow(id: "main")
  }

  /// Last folder name of `location`, or the bucket at its root.
  private static func crumbName(_ location: S3Location) -> String {
    var prefix = location.prefix
    if prefix.hasSuffix("/") { prefix.removeLast() }
    guard !prefix.isEmpty else { return location.bucket }
    return prefix.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? prefix
  }
}

/// "71%", "0.4%": `bytes` as a share of `total`.
private func share(_ bytes: Int64, of total: Int64) -> String {
  (total > 0 ? Double(bytes) / Double(total) : 0).formatted(.percent.precision(.fractionLength(0...1)))
}

/// Hot classes in blues, colder archive tiers toward purple and brown.
private func storageClassColor(_ name: String) -> Color {
  switch name {
  case "STANDARD": .blue
  case "EXPRESS_ONEZONE": .green
  case "REDUCED_REDUNDANCY": .orange
  case "INTELLIGENT_TIERING": .teal
  case "STANDARD_IA": .cyan
  case "ONEZONE_IA": .mint
  case "GLACIER_IR": .indigo
  case "GLACIER": .purple
  case "DEEP_ARCHIVE": .brown
  default: .gray
  }
}

/// Squarified treemap of a folder's children; clicking a folder tile opens it.
private struct TreemapView: View {
  let nodes: [StorageSummary.Node]
  let total: Int64
  let open: (StorageSummary.Node) -> Void
  @State private var hovered: StorageSummary.Node.ID?

  // ponytail: largest 300 tiles plus one "more" tile; smaller ones would be sub-pixel anyway and the
  // list view shows every child.
  private static let tileLimit = 300

  var body: some View {
    let shown = Array(nodes.prefix(Self.tileLimit))
    let restBytes = nodes.dropFirst(Self.tileLimit).reduce(Int64(0)) { $0 + $1.bytes }
    VStack(alignment: .leading, spacing: 10) {
      GeometryReader { proxy in
        let rects = Treemap.layout(
          shown.map { Double($0.bytes) } + [Double(restBytes)], in: CGRect(origin: .zero, size: proxy.size))
        ZStack(alignment: .topLeading) {
          ForEach(Array(shown.enumerated()), id: \.element.id) { index, node in
            tile(node, in: rects[index])
          }
          moreTile(count: nodes.count - shown.count, bytes: restBytes, in: rects[shown.count])
        }
      }
      HStack(spacing: 16) {
        legend(shown)
        Spacer(minLength: 0)
        if let node = shown.first(where: { $0.id == hovered }) {
          Text(verbatim: "\(node.name) · \(detail(node))")
            .lineLimit(1)
            .truncationMode(.middle)
            .monospacedDigit()
            .accessibilityHidden(true)
        }
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .frame(height: 16)
    }
  }

  /// Kinds present with their share of the folder; drops the shares when the row gets too narrow.
  private func legend(_ shown: [StorageSummary.Node]) -> some View {
    let bytes = Dictionary(shown.map { (TileKind($0), $0.bytes) }, uniquingKeysWith: +)
    let kinds = TileKind.allCases.filter { bytes[$0] != nil }
    return ViewThatFits(in: .horizontal) {
      legendRow(kinds, bytes: bytes, withShares: true)
      legendRow(kinds, bytes: bytes, withShares: false)
    }
  }

  private func legendRow(_ kinds: [TileKind], bytes: [TileKind: Int64], withShares: Bool) -> some View {
    HStack(spacing: 12) {
      ForEach(kinds, id: \.self) { kind in
        HStack(spacing: 5) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(kind.color)
            .frame(width: 9, height: 9)
          Text(kind.title)
          if withShares {
            Text(share(bytes[kind] ?? 0, of: total))
              .monospacedDigit()
              .foregroundStyle(.tertiary)
          }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
      }
    }
  }

  private func detail(_ node: StorageSummary.Node) -> String {
    "\(node.bytes.formatted(.byteCount(style: .file))) · \(share(node.bytes, of: total)) of total"
  }

  @ViewBuilder
  private func tile(_ node: StorageSummary.Node, in rect: CGRect) -> some View {
    let frame = rect.insetBy(dx: 1, dy: 1)
    if frame.width >= 2, frame.height >= 2 {
      let kind = TileKind(node)
      let size = node.bytes.formatted(.byteCount(style: .file))
      let objects = countLabel(node.objectCount, "object")
      let percent = share(node.bytes, of: total)
      let label = TileLabel(
        name: node.name, detail: "\(size) · \(percent)", count: node.isFolder ? objects : nil, kind: kind,
        size: frame.size, highlighted: hovered == node.id
      )
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        [node.name, kind.singular, size, "\(percent) of total", objects].joined(separator: ", "))
      Group {
        if node.isFolder {
          Button {
            open(node)
          } label: {
            label
          }
          .buttonStyle(.plain)
          .focusEffectDisabled()
          .pointerStyle(.link)
          .accessibilityHint("Opens the folder")
        } else {
          label
        }
      }
      .help(
        [node.name, "\(size) · \(percent) of total · \(objects)", node.isFolder ? "Click to open" : nil]
          .compactMap { $0 }.joined(separator: "\n")
      )
      .onHover { inside in
        if inside {
          hovered = node.id
        } else if hovered == node.id {
          hovered = nil
        }
      }
      .offset(x: frame.minX, y: frame.minY)
    }
  }

  @ViewBuilder
  private func moreTile(count: Int, bytes: Int64, in rect: CGRect) -> some View {
    let frame = rect.insetBy(dx: 1, dy: 1)
    if count > 0, frame.width >= 2, frame.height >= 2 {
      let size = bytes.formatted(.byteCount(style: .file))
      TileLabel(
        name: "\(count.formatted()) more", detail: "\(size) · \(share(bytes, of: total))", count: nil,
        kind: nil,
        size: frame.size, highlighted: false
      )
      .help("\(countLabel(count, "smaller item")) · \(size). Switch to List to see them.")
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(countLabel(count, "smaller item")), \(size)")
      .offset(x: frame.minX, y: frame.minY)
    }
  }
}

/// One treemap tile: a tinted fill keyed to the kind, then as much label as fits (symbol, name, size and
/// share, object count), so small tiles stay clean instead of showing clipped text.
private struct TileLabel: View {
  let name: String
  let detail: String
  /// Object count, shown for folders on tall tiles.
  let count: String?
  /// Nil for the "more" tile, drawn neutral so it doesn't read as "Other files".
  let kind: TileKind?
  let size: CGSize
  let highlighted: Bool
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.isFocused) private var isFocused

  var body: some View {
    let roomy = size.width >= 120 && size.height >= 52
    let shape = RoundedRectangle(cornerRadius: min(5, min(size.width, size.height) / 3), style: .continuous)
    // Dark mode needs a denser tint to separate tiles from the window; light mode a paler one so text stays
    // dark-on-light. Either way the label uses the primary color for contrast.
    let base = colorScheme == .dark ? 0.5 : 0.26
    let fill = kind.map { $0.color.opacity(highlighted ? base + 0.18 : base) } ?? Color.primary.opacity(0.1)
    let edge = kind?.color ?? Color.secondary
    VStack(alignment: .leading, spacing: 2) {
      if size.width >= 36, size.height >= 18 {
        HStack(spacing: 4) {
          if size.width >= 64, let kind {
            Image(systemName: kind.symbol)
              .imageScale(.small)
          }
          Text(name)
            .font(roomy ? .callout.weight(.semibold) : .caption.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
          if kind == .folder, size.width >= 72, size.height >= 36 {
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
              .opacity(highlighted ? 1 : 0.55)
          }
        }
      }
      if size.width >= 48, size.height >= (roomy ? 46 : 32) {
        Text(detail)
          .font(roomy ? .caption : .caption2)
          .monospacedDigit()
          .lineLimit(1)
          .opacity(0.8)
      }
      if let count, roomy, size.height >= 72 {
        Text(count)
          .font(.caption)
          .monospacedDigit()
          .lineLimit(1)
          .opacity(0.8)
      }
    }
    .foregroundStyle(.primary)
    .padding(.horizontal, roomy ? 8 : 4)
    .padding(.vertical, roomy ? 6 : 3)
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .background(fill, in: shape)
    .overlay {
      if isFocused {
        shape.strokeBorder(Color.accentColor, lineWidth: 2)
      } else {
        shape.strokeBorder(edge.opacity(highlighted ? 0.9 : 0.3), lineWidth: highlighted ? 1.5 : 0.5)
      }
    }
    .clipShape(shape)
    .contentShape(shape)
    .animation(.easeOut(duration: 0.12), value: highlighted)
  }
}

private enum TileKind: CaseIterable {
  case folder, image, video, audio, archive, document, other

  init(_ node: StorageSummary.Node) {
    self.init(name: node.name, isFolder: node.isFolder)
  }

  init(name: String, isFolder: Bool) {
    guard !isFolder else {
      self = .folder
      return
    }
    let type = UTType(filenameExtension: (name as NSString).pathExtension)
    self =
      switch type {
      case let type? where type.conforms(to: .image): .image
      case let type? where type.conforms(to: .movie): .video
      case let type? where type.conforms(to: .audio): .audio
      case let type? where type.conforms(to: .archive): .archive
      case let type?
      where [.text, .pdf, .presentation, .spreadsheet].contains(where: { type.conforms(to: $0) }):
        .document
      default: .other
      }
  }

  var title: String {
    switch self {
    case .folder: "Folders"
    case .image: "Images"
    case .video: "Videos"
    case .audio: "Audio"
    case .archive: "Archives"
    case .document: "Documents"
    case .other: "Other files"
    }
  }

  /// VoiceOver's name for one tile.
  var singular: String {
    switch self {
    case .folder: "Folder"
    case .image: "Image"
    case .video: "Video"
    case .audio: "Audio"
    case .archive: "Archive"
    case .document: "Document"
    case .other: "File"
    }
  }

  var symbol: String {
    switch self {
    case .folder: "folder.fill"
    case .image: "photo"
    case .video: "film"
    case .audio: "waveform"
    case .archive: "archivebox"
    case .document: "doc.text"
    case .other: "doc"
    }
  }

  var color: Color {
    switch self {
    case .folder: .blue
    case .image: .purple
    case .video: .pink
    case .audio: .orange
    case .archive: .brown
    case .document: .green
    case .other: .gray
    }
  }
}

/// The accessible alternative to the treemap: every child with its size, object count and share.
private struct ChildrenTable: View {
  let nodes: [StorageSummary.Node]
  let total: Int64
  let open: (StorageSummary.Node) -> Void
  @State private var selection: Set<StorageSummary.Node.ID> = []

  var body: some View {
    Table(nodes, selection: $selection) {
      TableColumn("Name") { node in
        let kind = TileKind(node)
        Label {
          Text(node.name)
        } icon: {
          Image(systemName: kind.symbol).foregroundStyle(kind.color)
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .help(node.name)
      }
      TableColumn("Size") { node in
        Text(node.bytes.formatted(.byteCount(style: .file)))
          .monospacedDigit()
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      .width(min: 70, ideal: 90)
      TableColumn("Objects") { node in
        Text(node.objectCount.formatted())
          .monospacedDigit()
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      .width(min: 60, ideal: 80)
      TableColumn("Share") { node in
        Text(share(node.bytes, of: total))
          .monospacedDigit()
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      .width(min: 50, ideal: 64)
    }
    .contextMenu(forSelectionType: StorageSummary.Node.ID.self) { ids in
      if let node = folder(ids) {
        Button("Open") { open(node) }
      }
    } primaryAction: { ids in
      if let node = folder(ids) { open(node) }
    }
  }

  private func folder(_ ids: Set<StorageSummary.Node.ID>) -> StorageSummary.Node? {
    guard ids.count == 1 else { return nil }
    return nodes.first { $0.id == ids.first && $0.isFolder }
  }
}
