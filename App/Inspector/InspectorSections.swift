import AppKit
import OpenBucketCore
import SwiftUI

/// Get Info-style rows: trailing labels and wrapping values, aligned on the first baseline.
struct InspectorGrid<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
      content
    }
  }
}

/// One label and value row of an `InspectorGrid`.
struct InspectorField<Content: View>: View {
  let title: String
  let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    GridRow {
      Text(title)
        .font(.callout)
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.trailing)
      content
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// Selectable text with a Copy menu. Always plain text: keys, metadata and tags are untrusted.
struct InspectorValue: View {
  let text: String
  /// What Copy puts on the clipboard when `text` is a readable name for a raw API value.
  var copyText: String?
  var monospaced = false

  var body: some View {
    Text(text)
      .font(monospaced ? .callout.monospaced() : .callout)
      .textSelection(.enabled)
      .contextMenu { Button("Copy") { copyToPasteboard(copyText ?? text) } }
  }
}

/// Warning or error line: the icon carries the colour, so the text keeps its contrast.
struct InspectorProblem: View {
  let message: String

  init(_ message: String) { self.message = message }

  var body: some View {
    Label {
      Text(message)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
    }
  }
}

/// Small capsule label, e.g. "Latest" or "Deleted".
struct InspectorBadge: View {
  let title: String
  let tint: Color

  init(_ title: String, tint: Color = .secondary) {
    self.title = title
    self.tint = tint
  }

  var body: some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .foregroundStyle(tint)
      .background(tint.opacity(0.15), in: Capsule())
  }
}

func copyToPasteboard(_ text: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(text, forType: .string)
}

/// Details grid of one object version: the caller's rows, then HEAD fields, user metadata and tags.
struct ObjectDetailsGrid<Leading: View>: View {
  let key: String
  let versionID: String?
  let browser: BrowserController
  @ViewBuilder let leading: Leading

  @State private var details: ObjectDetails?
  @State private var failure: String?

  var body: some View {
    InspectorGrid {
      leading
      if let details {
        fields(details)
      } else if let failure {
        // Not a GridRow, so it spans both columns.
        InspectorProblem("Couldn't load more details. \(failure)")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.top, 4)
      } else {
        ProgressView("Loading details…")
          .controlSize(.small)
          .padding(.top, 4)
      }
    }
    // Bytes, so keys that differ only by Unicode normalization still reload.
    .task(id: [
      AnyHashable(Array(key.utf8)), AnyHashable(Array((versionID ?? "").utf8)), browser.changeGeneration,
    ]) {
      await load()
    }
  }

  private var model: AppModel { browser.model }

  private func load() async {
    details = nil
    failure = nil
    guard let source = model.downloadSource() else {
      failure = "Not connected."
      return
    }
    do {
      let loaded = try await model.repository.objectDetails(
        profile: source.profile, credentials: source.credentials, bucket: source.bucket, key: key,
        versionID: versionID)
      guard !Task.isCancelled else { return }
      details = loaded
    } catch {
      guard !Task.isCancelled else { return }
      failure = AppModel.failure(for: error).message
    }
  }

  @ViewBuilder private func fields(_ details: ObjectDetails) -> some View {
    let lock = details.objectLockMode.map { mode in
      let until = details.objectLockRetainUntil.map {
        " until \($0.formatted(date: .abbreviated, time: .shortened))"
      }
      return mode.capitalized + (until ?? "")
    }
    // `copy` is the raw API value behind a readable name.
    let rows: [(title: String, value: String?, copy: String?, monospaced: Bool)] = [
      ("Content type", details.contentType, nil, false),
      ("Cache control", details.cacheControl, nil, true),
      ("Encoding", details.contentEncoding, nil, false),
      ("Disposition", details.contentDisposition, nil, true),
      ("Storage class", details.storageClass.map(StorageClassName.display), details.storageClass, false),
      (
        "Encryption", details.serverSideEncryption.map(StorageClassName.encryption),
        details.serverSideEncryption,
        false
      ),
      ("KMS key", details.kmsKeyID, nil, true),
      ("Version ID", details.versionID, nil, true),
      ("Restore status", details.restore.map(Self.restoreStatus), nil, false),
      ("Object Lock", lock, nil, false),
      ("Legal hold", details.legalHold?.capitalized, nil, false),
      ("Replication", details.replicationStatus?.capitalized, nil, false),
    ]
    ForEach(rows.filter { $0.value?.isEmpty == false }, id: \.title) { row in
      InspectorField(row.title) {
        InspectorValue(text: row.value ?? "", copyText: row.copy, monospaced: row.monospaced)
      }
    }
    if !details.metadata.isEmpty {
      InspectorField("Metadata") { Self.pairs(details.metadata) }
    }
    // Nil tags couldn't be read, which the user can't act on here, so the row is left out.
    if let tags = details.tags, !tags.isEmpty {
      InspectorField("Tags") { Self.pairs(tags) }
    }
  }

  private static func pairs(_ pairs: [String: String]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(pairs.sorted { $0.key < $1.key }, id: \.key) { pair in
        VStack(alignment: .leading, spacing: 2) {
          Text(pair.key)
            .font(.callout.weight(.medium))
          Text(pair.value)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
        .contextMenu {
          Button("Copy Value") { copyToPasteboard(pair.value) }
          Button("Copy Name") { copyToPasteboard(pair.key) }
        }
      }
    }
  }

  /// `x-amz-restore`: `ongoing-request="false", expiry-date="Fri, 21 Dec 2012 00:00:00 GMT"`.
  private static func restoreStatus(_ header: String) -> String {
    if header.contains("ongoing-request=\"true\"") { return "Restore in progress" }
    if let start = header.range(of: "expiry-date=\"")?.upperBound,
      let end = header[start...].firstIndex(of: "\"")
    {
      return "Restored until \(header[start..<end])"
    }
    return header
  }
}

/// Dimensions, camera and exposure from the first bytes of an image (current version only).
struct PhotoInfoSection: View {
  let key: String
  let model: AppModel

  @Environment(\.openURL) private var openURL
  @State private var info: ImageMetadata.Info?

  var body: some View {
    // A stack, not a Group: a Group would hand the task to each child, and has none until info loads.
    VStack(alignment: .leading, spacing: 0) {
      if let info, !Self.fields(info).isEmpty {
        Divider()
          .padding(.vertical, 20)
        Text("Photo")
          .font(.headline)
          .padding(.bottom, 10)
        InspectorGrid {
          ForEach(Self.fields(info), id: \.title) { field in
            InspectorField(field.title) { InspectorValue(text: field.value) }
          }
          if let maps = Self.mapsURL(info) {
            GridRow {
              Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
              Button("Show in Maps", systemImage: "map") { openURL(maps) }
            }
          }
        }
      }
    }
    .task(id: Array(key.utf8)) {
      info = nil
      guard let source = model.downloadSource(),
        let data = try? await model.repository.readObjectBytes(
          profile: source.profile, credentials: source.credentials, bucket: source.bucket, key: key,
          range: 0..<ImageMetadata.prefixLength)
      else { return }
      let parsed = await Self.parse(data)
      guard !Task.isCancelled else { return }
      info = parsed
    }
  }

  @concurrent private nonisolated static func parse(_ data: Data) async -> ImageMetadata.Info? {
    ImageMetadata.read(data).info
  }

  private static func fields(_ info: ImageMetadata.Info) -> [(title: String, value: String)] {
    var fields: [(title: String, value: String)] = []
    if let width = info.pixelWidth, let height = info.pixelHeight {
      fields.append(("Dimensions", "\(width.formatted()) × \(height.formatted()) pixels"))
    }
    // Most cameras repeat the make in the model ("Canon" + "Canon EOS R5").
    let camera = [info.make, info.model].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
    if let model = camera.last {
      let make = camera.count == 2 ? camera[0] : ""
      fields.append(("Camera", model.hasPrefix(make) ? model : "\(make) \(model)"))
    }
    if let lens = info.lens { fields.append(("Lens", lens)) }
    if let date = info.dateTaken {
      fields.append(("Date taken", date.formatted(date: .abbreviated, time: .shortened)))
    }
    if let exposure = info.exposure { fields.append(("Exposure", exposure)) }
    return fields.filter { !$0.value.isEmpty }
  }

  /// Built from parsed numbers only, never from strings in the file.
  private static func mapsURL(_ info: ImageMetadata.Info) -> URL? {
    guard let latitude = info.latitude, let longitude = info.longitude, abs(latitude) <= 90,
      abs(longitude) <= 180
    else { return nil }
    return URL(string: String(format: "https://maps.apple.com/?ll=%.6f,%.6f", latitude, longitude))
  }
}

/// Every version of one key, loaded on request.
struct VersionsSection: View {
  let key: String
  let browser: BrowserController

  @State private var history: ObjectHistory?

  // ponytail: newest 1,000 versions, page further on demand if someone needs more.
  private static let limit = 1000

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Divider()
        .padding(.vertical, 20)
      Text("Versions")
        .font(.headline)
        .padding(.bottom, 10)
      if let history {
        content(history)
      } else {
        Button("Show Versions") { load() }
          .disabled(browser.model.downloadSource() == nil)
          .padding(.vertical, 6)
      }
    }
    .onDisappear { history?.cancel() }
    // A restore or other write adds versions; reload only lists the user already opened.
    .onChange(of: browser.changeGeneration) { history?.start() }
  }

  private func load() {
    guard let source = browser.model.downloadSource() else { return }
    let history = ObjectHistory(
      repository: browser.model.repository, source: source, key: key, limit: Self.limit)
    self.history = history
    history.start()
  }

  @ViewBuilder private func content(_ history: ObjectHistory) -> some View {
    ForEach(Array(history.versions.enumerated()), id: \.element.id) { index, version in
      if index > 0 { Divider() }
      versionRow(version)
    }
    if history.isRunning {
      HStack {
        ProgressView("Loading versions…")
          .controlSize(.small)
        Spacer()
        Button("Cancel") { history.cancel() }
      }
      .padding(.vertical, 8)
    } else if let failure = history.failure {
      if failure.category == .unsupportedOperation {
        Text("This storage provider doesn't support versions.")
          .foregroundStyle(.secondary)
          .padding(.vertical, 6)
      } else {
        InspectorProblem(failure.message)
          .font(.callout)
          .padding(.vertical, 6)
        Button("Try Again") { history.start() }
      }
    } else if history.truncated {
      Text("Showing the newest \(Self.limit.formatted()) versions.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 8)
    } else if history.versions.isEmpty {
      Text("No versions found.")
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }
  }

  private func versionRow(_ version: ObjectVersion) -> some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 3) {
        if let date = version.lastModified {
          Text(date.formatted(date: .abbreviated, time: .standard))
        } else {
          Text("Unknown date")
        }
        HStack(spacing: 6) {
          if !version.isDeleteMarker {
            Text(version.size.formatted(.byteCount(style: .file)))
              .foregroundStyle(.secondary)
          }
          if version.isLatest { InspectorBadge("Latest", tint: .accentColor) }
          if version.isDeleteMarker { InspectorBadge("Deleted", tint: .red) }
        }
        .font(.callout)
      }
      Spacer(minLength: 0)
      if browser.canModify, Self.canRestore(version) {
        Button("Restore") { browser.restore(version) }
          .controlSize(.small)
          .disabled(browser.isTransferring)
          .help("Make this version the current one; newer versions are kept.")
      }
      if !version.isDeleteMarker {
        Menu {
          actions(version)
        } label: {
          Label("Version Actions", systemImage: "ellipsis.circle")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Actions for this version")
      }
    }
    .padding(.vertical, 8)
    .contextMenu {
      if !version.isDeleteMarker { actions(version) }
    }
  }

  /// Restoring copies the version onto its key, so the latest version and delete markers have nothing to restore.
  private static func canRestore(_ version: ObjectVersion) -> Bool {
    !version.isLatest && !version.isDeleteMarker
  }

  @ViewBuilder private func actions(_ version: ObjectVersion) -> some View {
    if Self.canRestore(version) {
      Button("Restore") { browser.restore(version) }
        .disabled(!browser.canModify || browser.isTransferring)
        .help(
          browser.modifyUnavailableReason ?? "Make this version the current one; newer versions are kept.")
      Divider()
    }
    Button("Quick Look") { browser.quickLook(version.summary, versionID: version.versionID) }
      .disabled(version.size > BrowserRow.previewLimit)
    Button("Download…") { browser.download(version.summary, versionID: version.versionID) }
      .disabled(browser.isTransferring)
    Button("Share Link…") {
      browser.shareTarget = ShareTarget(object: version.summary, versionID: version.versionID)
    }
    Divider()
    Button("Copy Version ID") { copyToPasteboard(version.versionID) }
  }
}
