import AppKit
import OpenBucketCore
import SwiftUI
import UniformTypeIdentifiers

/// Compares a local folder with an S3 folder and lists every difference; on request, copies new and changed
/// files one way (Update S3 or Update Mac) without deleting anything.
struct BackupVerifyView: View {
  let model: AppModel
  let target: InsightTarget

  @State private var source: AppModel.DownloadSource?
  @State private var sourceFailure: S3Failure?
  @State private var localFolder: URL?
  @State private var verification: BackupVerification?
  /// True after the user cancelled the current run, so partial results aren't presented as complete.
  @State private var cancelled = false
  @State private var hiddenStatuses: Set<Status> = []
  @State private var sortOrder = [KeyPathComparator(\Entry.relativePath, comparator: .localizedStandard)]
  @State private var exportFailure: String?
  @State private var isDropTargeted = false
  @State private var sync: FolderSync?
  @State private var syncRequest: SyncRequest?

  private typealias Status = BackupVerification.Status
  private typealias Entry = BackupVerification.Entry
  private var location: S3Location { target.location }
  private var isRunning: Bool { verification?.isRunning == true || sync?.isRunning == true }

  var body: some View {
    Group {
      if source == nil {
        if let sourceFailure {
          ContentUnavailableView {
            Label("Couldn't connect", systemImage: "externaldrive.badge.xmark")
          } description: {
            Text(sourceFailure.message)
          } actions: {
            Button("Try Again") { Task { await resolveSource() } }
              .buttonStyle(.glassProminent)
          }
        } else {
          ProgressView("Connecting…")
        }
      } else if let verification {
        session(verification)
      } else {
        setup
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay {
      if isDropTargeted {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(.tint, lineWidth: 3)
          .padding(4)
          .allowsHitTesting(false)
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard !isRunning, urls.count == 1, let url = urls.first,
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
      else { return false }
      select(url)
      return true
    } isTargeted: {
      isDropTargeted = $0 && !isRunning
    }
    .navigationTitle("Compare with Local Folder")
    .navigationSubtitle(location.displayString)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Export CSV…", systemImage: "square.and.arrow.up") { exportCSV() }
          .help("Export all results as a CSV file (⇧⌘E)")
          .keyboardShortcut("e", modifiers: [.command, .shift])
          .disabled(verification?.entries.isEmpty ?? true || isRunning)
      }
    }
    .task {
      if source == nil { await resolveSource() }
    }
    .task(id: sync.map { ObjectIdentifier($0) }) {
      // Compare again once a sync ends so the table shows the new state; closing the window cancels this.
      guard let task = sync?.task else { return }
      await task.value
      if !Task.isCancelled { start() }
    }
    .confirmationDialog(
      syncRequest?.title ?? "",
      isPresented: Binding(get: { syncRequest != nil }, set: { if !$0 { syncRequest = nil } }),
      titleVisibility: .visible, presenting: syncRequest
    ) { request in
      Button(request.plan.direction == .toS3 ? "Upload" : "Download") { runSync(request.plan) }
        .keyboardShortcut(.defaultAction)
      Button("Cancel", role: .cancel) {}
    } message: { request in
      Text(request.message)
    }
    .onDisappear {
      verification?.cancel()
      sync?.cancel()
    }
  }

  // MARK: Setup

  /// Before the first run: both sides of the comparison, with Compare as the one primary action.
  private var setup: some View {
    VStack(spacing: 20) {
      HStack(spacing: 12) {
        GroupBox("On this Mac") {
          VStack(spacing: 12) {
            folderSummary(
              systemImage: "folder",
              name: localFolder?.lastPathComponent ?? "No folder chosen",
              detail: localFolder?.path(percentEncoded: false)
                ?? "Choose the local copy of this folder, or drop it on this window.",
              isPlaceholder: localFolder == nil
            )
            chooseFolderButton(localFolder == nil ? "Choose Folder…" : "Change Folder…")
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(8)
        }
        Image(systemName: "arrow.left.arrow.right")
          .font(.title2)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        GroupBox("In S3") {
          folderSummary(
            systemImage: "externaldrive.connected.to.line.below",
            name: location.prefix.split(separator: "/").last.map(String.init) ?? location.bucket,
            detail: location.displayString,
            isPlaceholder: false
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(8)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      Button("Compare", action: start)
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(localFolder == nil)
      Text("Files are matched by path and compared by size and checksum. Nothing is changed on either side.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: 620)
    .padding(32)
  }

  private func folderSummary(systemImage: String, name: String, detail: String, isPlaceholder: Bool)
    -> some View
  {
    VStack(spacing: 4) {
      Image(systemName: systemImage)
        .font(.largeTitle)
        .foregroundStyle(.secondary)
        .padding(.bottom, 4)
        .accessibilityHidden(true)
      Text(name)
        .font(.headline)
        .foregroundStyle(isPlaceholder ? .secondary : .primary)
        .lineLimit(1)
        .truncationMode(.middle)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .truncationMode(.middle)
        .help(detail)
    }
  }

  private func chooseFolderButton(_ title: String) -> some View {
    Button(title, action: chooseFolder)
      .keyboardShortcut("o", modifiers: .command)
      .help("Choose the folder on this Mac to compare (⌘O)")
      .disabled(isRunning)
  }

  // MARK: Session

  private func session(_ verification: BackupVerification) -> some View {
    VStack(spacing: 0) {
      header(verification)
      Divider()
      if let failure = verification.failure {
        banner(failure.message, action: "Try Again", perform: start)
      }
      if let exportFailure {
        banner(exportFailure, action: "Dismiss") { self.exportFailure = nil }
      }
      if verification.entries.isEmpty, !verification.isRunning {
        if verification.failure == nil {
          ContentUnavailableView {
            Label(
              cancelled ? "Cancelled" : "No files to compare",
              systemImage: cancelled ? "stop.circle" : "folder")
          } description: {
            Text(cancelled ? "No files were compared." : "Both folders are empty.")
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          Spacer()
        }
      } else {
        summary(verification)
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
        if verification.entries.isEmpty {
          Spacer()
        } else {
          table(verification)
        }
      }
    }
  }

  /// Both sides on one line, so the results never lose what was compared with what.
  private func header(_ verification: BackupVerification) -> some View {
    HStack(spacing: 8) {
      place(verification.localFolder.path(percentEncoded: false), systemImage: "folder")
      Image(systemName: "arrow.left.arrow.right")
        .foregroundStyle(.secondary)
        .accessibilityLabel("compared with")
      place(location.displayString, systemImage: "externaldrive.connected.to.line.below")
      Spacer(minLength: 12)
      chooseFolderButton("Choose Folder…")
      if verification.isRunning {
        Button("Cancel") {
          cancelled = true
          verification.cancel()
        }
        .keyboardShortcut(.cancelAction)
      } else if let sync, sync.isRunning {
        Button("Cancel") { sync.cancel() }
          .keyboardShortcut(.cancelAction)
      } else {
        Button("Compare Again", action: start)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private func place(_ path: String, systemImage: String) -> some View {
    Label {
      Text(path).lineLimit(1).truncationMode(.middle)
    } icon: {
      Image(systemName: systemImage).foregroundStyle(.secondary)
    }
    .help(path)
  }

  private func summary(_ verification: BackupVerification) -> some View {
    let counts = Dictionary(verification.entries.map { ($0.status, 1) }, uniquingKeysWith: +)
    let present = Status.order.filter { counts[$0] != nil }
    let caveats = present.compactMap(\.caveat)
    return VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        if let sync, sync.isRunning {
          syncProgress(sync)
        } else {
          progress(verification, counts: counts)
          if isComplete(verification) {
            Spacer(minLength: 12)
            syncButtons(verification)
          }
        }
      }
      if let sync, sync.isFinished {
        syncResult(sync)
      }
      if !present.isEmpty {
        HStack(spacing: 6) {
          ForEach(present, id: \.self) { status in
            Toggle(isOn: shown(status)) {
              Label {
                HStack(spacing: 4) {
                  Text(status.title)
                  Text((counts[status] ?? 0).formatted())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
              } icon: {
                Image(systemName: status.symbol).foregroundStyle(status.color)
              }
            }
            .toggleStyle(.button)
            .help("\(status.explanation) Click to show or hide these files.")
          }
        }
      }
      if !caveats.isEmpty {
        Text(caveats.joined(separator: " "))
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func progress(_ verification: BackupVerification, counts: [Status: Int]) -> some View {
    let checked = verification.checkedFiles
    let total = verification.totalFiles
    if verification.isRunning {
      if total == 0 {
        ProgressView { Text("Listing files…") }
          .progressViewStyle(.linear)
      } else {
        ProgressView(value: Double(checked), total: Double(total)) {
          Text("Comparing files…")
        } currentValueLabel: {
          Text(verbatim: "\(checked.formatted()) of \(countLabel(total, "file"))").monospacedDigit()
        }
      }
    } else if cancelled || verification.failure != nil {
      let verb = cancelled ? "Cancelled" : "Stopped"
      Label {
        Text(
          verbatim: total == 0
            ? "\(verb) while listing files."
            : "\(verb) after \(checked.formatted()) of \(countLabel(total, "file")). These results are incomplete."
        )
        .monospacedDigit()
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      }
    } else {
      verdict(checked: checked, counts: counts)
    }
  }

  /// One sentence that answers "is my copy complete and intact?"; the status toggles carry the detail.
  private func verdict(checked: Int, counts: [Status: Int]) -> some View {
    let mismatched = [Status.different, .sizeMismatch, .missingInS3].reduce(0) { $0 + (counts[$1] ?? 0) }
    let unproven = (counts[.unverified] ?? 0) + (counts[.unreadable] ?? 0)
    let (headline, symbol, color): (String, String, Color) =
      if mismatched > 0 {
        (
          mismatched == 1 ? "1 file doesn't match S3" : "\(countLabel(mismatched, "file")) don't match S3",
          "xmark.circle.fill", .red
        )
      } else if unproven > 0 {
        (
          "No differences found, but \(countLabel(unproven, "file")) couldn't be verified",
          "questionmark.circle.fill", .orange
        )
      } else if counts[.identical] == nil {
        ("No files on this Mac to compare", "info.circle.fill", .secondary)
      } else {
        ("All files on this Mac match S3", "checkmark.circle.fill", .green)
      }
    return Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(headline).font(.headline)
        Text(
          "\(countLabel(checked, "file")) compared."
            + (sync == nil ? " Nothing was changed on either side." : "")
        )
        .foregroundStyle(.secondary)
      }
      .monospacedDigit()
    } icon: {
      Image(systemName: symbol).foregroundStyle(color).font(.headline)
    }
  }

  private func table(_ verification: BackupVerification) -> some View {
    let rows = verification.entries.filter { !hiddenStatuses.contains($0.status) }.sorted(using: sortOrder)
    return Table(rows, sortOrder: $sortOrder) {
      TableColumn("Path", value: \.relativePath) { entry in
        Text(entry.relativePath)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(entry.relativePath)
      }
      TableColumn("Local Size", value: \.localSortSize) { entry in
        sizeCell(entry.localSize, highlighted: entry.status == .sizeMismatch)
      }
      .width(min: 70, ideal: 90)
      TableColumn("S3 Size", value: \.remoteSortSize) { entry in
        sizeCell(entry.remoteSize, highlighted: entry.status == .sizeMismatch)
      }
      .width(min: 70, ideal: 90)
      TableColumn("Status", value: \.status.rank) { entry in
        Label {
          Text(entry.status.title)
        } icon: {
          Image(systemName: entry.status.symbol).foregroundStyle(entry.status.color)
        }
        .help(entry.status.explanation)
      }
      .width(min: 120, ideal: 150)
    }
    .tableStyle(.inset)
    .alternatingRowBackgrounds(.disabled)
    .overlay {
      if rows.isEmpty {
        ContentUnavailableView {
          Label("No files shown", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
          Text("Every status in this comparison is hidden.")
        } actions: {
          Button("Show All") { hiddenStatuses = [] }
        }
      }
    }
  }

  /// Sizes stay secondary, except where they are the difference.
  private func sizeCell(_ bytes: Int64?, highlighted: Bool) -> some View {
    Text(bytes?.formatted(.byteCount(style: .file)) ?? "—")
      .monospacedDigit()
      .foregroundStyle(highlighted ? .primary : .secondary)
      .frame(maxWidth: .infinity, alignment: .trailing)
  }

  private func banner(_ message: String, action: String, perform: @escaping () -> Void) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Label {
          Text(message)
        } icon: {
          Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
        }
        Spacer(minLength: 8)
        Button(action, action: perform)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      Divider()
    }
  }

  // MARK: Sync

  /// Sync works from the results, so it is offered only after a comparison that finished.
  private func isComplete(_ verification: BackupVerification) -> Bool {
    !verification.isRunning && verification.failure == nil && !cancelled
      && verification.checkedFiles == verification.totalFiles
  }

  /// One button per direction that has something to copy.
  @ViewBuilder
  private func syncButtons(_ verification: BackupVerification) -> some View {
    let plans = [FolderSync.Direction.toS3, .toMac].map {
      FolderSync.plan(
        $0, entries: verification.entries, location: location, localFolder: verification.localFolder)
    }
    let canWrite = source?.profile.allowsChanges == true
    if !plans[0].items.isEmpty {
      Button("Update S3…") { requestSync(plans[0]) }
        .disabled(!canWrite)
        .help(
          canWrite
            ? "Upload new and changed files from this Mac to S3. Nothing is deleted."
            : "This connection is read-only. Edit the connection and turn on Allow changes to update S3.")
    }
    if !plans[1].items.isEmpty {
      Button("Update Mac…") { requestSync(plans[1]) }
        .help("Download new and changed files from S3 to this Mac. Nothing is deleted.")
    }
  }

  private func syncProgress(_ sync: FolderSync) -> some View {
    let progress = sync.progress
    let fraction =
      progress.totalBytes > 0
      ? Double(progress.receivedBytes) / Double(progress.totalBytes)
      : Double(progress.completedFiles) / Double(max(progress.totalFiles, 1))
    let files = "\(progress.completedFiles.formatted()) of \(countLabel(progress.totalFiles, "file"))"
    let bytes =
      "\(progress.receivedBytes.formatted(.byteCount(style: .file))) of "
      + progress.totalBytes.formatted(.byteCount(style: .file))
    return ProgressView(value: fraction) {
      Text(sync.plan.direction == .toS3 ? "Uploading to S3…" : "Downloading to this Mac…")
    } currentValueLabel: {
      Text(verbatim: "\(files) · \(bytes)").monospacedDigit()
    }
  }

  private func syncResult(_ sync: FolderSync) -> some View {
    let verb = sync.plan.direction == .toS3 ? "Uploaded" : "Downloaded"
    let done =
      sync.wasCancelled
      ? "\(verb) \(sync.transferredFiles.formatted()) of \(countLabel(sync.plan.items.count, "file")) "
        + "before you cancelled"
      : "\(verb) \(countLabel(sync.transferredFiles, "file"))"
    let failed = sync.failedPaths.count
    let warns = failed > 0 || sync.wasCancelled
    return HStack(spacing: 10) {
      Label {
        Text(verbatim: failed > 0 ? "\(done) · \(failed.formatted()) failed" : done).monospacedDigit()
      } icon: {
        Image(systemName: warns ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
          .foregroundStyle(warns ? Color.orange : .green)
      }
      if failed > 0 {
        Button("Copy Failed Paths") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(sync.failedPaths.joined(separator: "\n"), forType: .string)
        }
        .help(sync.failedPaths.prefix(10).joined(separator: "\n") + (failed > 10 ? "\n…" : ""))
      }
    }
  }

  /// Update S3 reads the bucket's versioning first when it would replace files, to word the warning.
  private func requestSync(_ plan: FolderSync.Plan) {
    guard let source else { return }
    guard plan.direction == .toS3, plan.changedFiles > 0 else {
      syncRequest = SyncRequest(plan: plan, versioning: nil)
      return
    }
    Task {
      let versioning = try? await model.repository.bucketVersioning(
        profile: source.profile, credentials: source.credentials, bucket: source.bucket)
      syncRequest = SyncRequest(plan: plan, versioning: versioning)
    }
  }

  private func runSync(_ plan: FolderSync.Plan) {
    guard let source, !isRunning else { return }
    let sync = FolderSync(plan: plan, repository: model.repository, source: source)
    self.sync = sync
    sync.start()
  }

  // MARK: Actions

  /// Resolves the window's own connection once, independent of the main window's selection.
  private func resolveSource() async {
    sourceFailure = nil
    do {
      source = try await model.downloadSource(for: target)
    } catch {
      sourceFailure = AppModel.failure(for: error)
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    panel.message = "Choose the folder on this Mac to compare with \(location.displayString)."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    select(url)
  }

  /// A new folder discards the previous results; the user starts the comparison explicitly.
  private func select(_ url: URL) {
    verification?.cancel()
    verification = nil
    sync = nil
    cancelled = false
    localFolder = url
  }

  private func start() {
    guard let source, let localFolder else { return }
    if verification?.localFolder != localFolder {
      verification = BackupVerification(
        repository: model.repository, source: source, location: location, localFolder: localFolder)
    }
    cancelled = false
    verification?.start()
  }

  private func exportCSV() {
    guard let verification else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.nameFieldStringValue = "\(verification.localFolder.lastPathComponent) comparison.csv"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try Data(verification.csv().utf8).write(to: url, options: .atomic)
    } catch {
      exportFailure = "The CSV file couldn't be saved. Choose another location and try again."
    }
  }

  private func shown(_ status: Status) -> Binding<Bool> {
    Binding {
      !hiddenStatuses.contains(status)
    } set: { isShown in
      if isShown { hiddenStatuses.remove(status) } else { hiddenStatuses.insert(status) }
    }
  }
}

// MARK: Presentation

extension BackupVerification.Status {
  /// Problems first, so the summary leads with what needs attention and sorting by status groups them.
  fileprivate static let order: [Self] = [
    .different, .sizeMismatch, .missingInS3, .unreadable, .unverified, .onlyInS3, .identical,
  ]

  fileprivate var rank: Int { Self.order.firstIndex(of: self) ?? 0 }

  fileprivate var title: String {
    switch self {
    case .identical: "Identical"
    case .different: "Different"
    case .sizeMismatch: "Size differs"
    case .missingInS3: "Missing in S3"
    case .onlyInS3: "Only in S3"
    case .unverified: "Unverified"
    case .unreadable: "Unreadable"
    }
  }

  fileprivate var symbol: String {
    switch self {
    case .identical: "checkmark.circle.fill"
    case .different: "xmark.circle.fill"
    case .sizeMismatch: "arrow.left.and.right.circle.fill"
    case .missingInS3: "minus.circle.fill"
    case .onlyInS3: "plus.circle.fill"
    case .unverified: "questionmark.circle.fill"
    case .unreadable: "exclamationmark.triangle.fill"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .identical: .green
    case .different, .sizeMismatch, .missingInS3: .red
    case .unverified, .unreadable: .orange
    case .onlyInS3: .secondary
    }
  }

  fileprivate var explanation: String {
    switch self {
    case .identical: "The file on this Mac has the same size and checksum as the S3 object."
    case .different:
      "Same size, but the checksum differs. Objects stored with SSE-KMS or SSE-C always show as different, "
        + "because their ETags aren't checksums."
    case .sizeMismatch: "The file on this Mac and the S3 object have different sizes."
    case .missingInS3: "The file is on this Mac but not in S3."
    case .onlyInS3: "The object is in S3 but not on this Mac."
    case .unverified: "The sizes match, but a multipart or encrypted ETag can't prove the content."
    case .unreadable: "The file on this Mac couldn't be opened, so it wasn't compared."
    }
  }

  /// The statuses whose meaning isn't obvious from the name, explained under the summary when they occur.
  fileprivate var caveat: String? {
    switch self {
    case .different:
      "Different can also mean the object is stored with SSE-KMS or SSE-C, whose ETags aren't checksums."
    case .unverified:
      "Unverified files have matching sizes, but a multipart or encrypted ETag can't prove their content."
    case .unreadable: "Unreadable files couldn't be opened on this Mac, so they weren't compared."
    default: nil
    }
  }
}

extension BackupVerification.Entry {
  /// Sort keys for the optional sizes: a missing side sorts before an empty file.
  fileprivate var localSortSize: Int64 { localSize ?? -1 }
  fileprivate var remoteSortSize: Int64 { remoteSize ?? -1 }
}

/// A sync waiting for confirmation, worded from its plan.
private struct SyncRequest {
  let plan: FolderSync.Plan
  /// Read only for an Update S3 that replaces files; nil when unknown.
  let versioning: BucketVersioning?

  var title: String {
    let files = Self.list([(plan.newFiles, "new"), (plan.changedFiles, "changed")], "file") ?? ""
    return plan.direction == .toS3 ? "Upload \(files) to S3?" : "Download \(files) to this Mac?"
  }

  var message: String {
    var sentences: [String] = []
    let changed = plan.changedFiles
    if changed > 0 {
      switch (plan.direction, versioning) {
      case (.toMac, _):
        let verb = changed == 1 ? "goes" : "go"
        sentences.append("\(countLabel(changed, "replaced file")) \(verb) to the Trash.")
      case (.toS3, .enabled):
        sentences.append("S3 keeps the previous version of each replaced file.")
      case (.toS3, nil):
        sentences.append("Replaced files in S3 can't be recovered unless this bucket keeps old versions.")
      case (.toS3, _):
        sentences.append(
          "Replaced files in S3 can't be recovered because this bucket doesn't keep old versions.")
      }
    }
    let kept = plan.targetOnly
    let side = plan.direction == .toS3 ? "only in S3" : "only on this Mac"
    sentences.append(
      kept == 0
        ? "Nothing is deleted."
        : "Nothing is deleted: \(countLabel(kept, "file")) \(side) \(kept == 1 ? "stays" : "stay").")
    let alone = [(Status.identical, "identical"), (.unverified, "unverified"), (.unreadable, "unreadable")]
    if let list = Self.list(alone.map { (plan.leftAlone[$0] ?? 0, $1) }, "file") {
      let total = plan.leftAlone.values.reduce(0, +)
      sentences.append("\(list) \(total == 1 ? "is" : "are") left alone.")
    }
    return sentences.joined(separator: " ")
  }

  private typealias Status = BackupVerification.Status

  /// "3 new and 1 changed file": the non-zero counts as a list, the noun agreeing with the last; nil when
  /// every count is zero.
  private static func list(_ counts: [(Int, String)], _ noun: String) -> String? {
    let present = counts.filter { $0.0 > 0 }
    guard let last = present.last else { return nil }
    return present.map { "\($0.0.formatted()) \($0.1)" }.formatted(.list(type: .and))
      + " " + (last.0 == 1 ? noun : noun + "s")
  }
}
