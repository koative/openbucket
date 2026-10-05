import AppKit
import OpenBucketCore
import SwiftUI

/// The sheets and dialogs of write actions, presented while their controller state is set.
struct ChangePresentations: ViewModifier {
  @Bindable var browser: BrowserController

  func body(content: Content) -> some View {
    content
      .sheet(item: $browser.metadataTarget) { target in
        MetadataEditor(target: target, browser: browser)
      }
      .sheet(isPresented: newFolderPresented) {
        NewFolderSheet(browser: browser)
      }
      .sheet(item: $browser.renameTarget) { target in
        RenameSheet(target: target, browser: browser)
      }
      .sheet(item: $browser.moveTarget) { target in
        MoveSheet(target: target, browser: browser)
      }
      // Its buttons answer the prompt; the controller clears `conflict` itself, then shows the next queued one.
      .sheet(item: Binding(get: { browser.conflict }, set: { _ in })) { prompt in
        ConflictSheet(prompt: prompt, browser: browser)
          .id(prompt.id)
      }
      .confirmationDialog(
        browser.deleteConfirmation?.title ?? "",
        isPresented: Binding(
          get: { browser.deleteConfirmation != nil }, set: { if !$0 { browser.deleteConfirmation = nil } }),
        presenting: browser.deleteConfirmation
      ) { confirmation in
        Button("Delete", role: .destructive) { browser.confirmDelete(confirmation) }
      } message: { confirmation in
        Text(
          confirmation.versioning == .enabled
            ? "You can restore deleted files from Show Deleted Files." : "This can't be undone.")
      }
  }

  private var newFolderPresented: Binding<Bool> {
    let browser = browser
    return Binding(get: { browser.newFolderParent != nil }, set: { if !$0 { browser.newFolderParent = nil } })
  }
}

/// New Folder, Rename and Move To: one field, checked as it's typed, and an action whose failure shows inline
/// so the user can fix the text and try again.
struct TextEntrySheet: View {
  @Environment(\.dismiss) private var dismiss
  let title: String
  let message: String?
  let label: String
  /// Shown before the field, e.g. the bucket in front of a folder path.
  var fieldPrefix: String?
  let actionTitle: String
  let initial: String
  let validate: @MainActor (String) -> String?
  let submit: @MainActor (String) async -> String?

  @State private var text: String
  @State private var selection: TextSelection?
  @State private var failure: String?
  @State private var isWorking = false
  @FocusState private var isFocused: Bool
  private let initialSelection: Range<String.Index>?

  init(
    title: String, message: String? = nil, label: String, fieldPrefix: String? = nil, actionTitle: String,
    initial: String = "", selecting: Range<String.Index>? = nil,
    validate: @escaping @MainActor (String) -> String?,
    submit: @escaping @MainActor (String) async -> String?
  ) {
    self.title = title
    self.message = message
    self.label = label
    self.fieldPrefix = fieldPrefix
    self.actionTitle = actionTitle
    self.initial = initial
    self.validate = validate
    self.submit = submit
    initialSelection = selecting
    _text = State(initialValue: initial)
  }

  var body: some View {
    let problem = validate(text)
    VStack(alignment: .leading, spacing: 16) {
      Text(title)
        .font(.title2.weight(.semibold))
      if let message {
        Text(message)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 4) {
        if let fieldPrefix {
          Text(fieldPrefix)
            .font(.body.monospaced())
            .foregroundStyle(.secondary)
        }
        TextField(label, text: $text, selection: $selection, prompt: Text(label))
          .font(fieldPrefix == nil ? .body : .body.monospaced())
          .labelsHidden()
          .focused($isFocused)
          .disabled(isWorking)
          .onChange(of: text) { failure = nil }
      }
      // The untouched or emptied field isn't a mistake yet; the disabled button says enough.
      if let note = failure ?? (text.isEmpty || text == initial ? nil : problem) {
        Label {
          Text(note)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
        .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        if isWorking {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Working")
        }
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(actionTitle) { run() }
          .keyboardShortcut(.defaultAction)
          .disabled(problem != nil || text == initial || isWorking)
      }
    }
    .padding(24)
    .frame(width: 460)
    .task {
      isFocused = true
      // Focusing selects everything; select the name's stem once that has happened.
      await Task.yield()
      if let initialSelection { selection = TextSelection(range: initialSelection) }
    }
  }

  private func run() {
    isWorking = true
    Task {
      let result = await submit(text)
      isWorking = false
      if let result { failure = result } else { dismiss() }
    }
  }
}

/// File ▸ New Folder.
struct NewFolderSheet: View {
  let browser: BrowserController
  /// Kept after `newFolderParent` clears, so the sheet doesn't lose its folder while it animates away.
  @State private var parent: S3Location?

  init(browser: BrowserController) {
    self.browser = browser
    _parent = State(initialValue: browser.newFolderParent)
  }

  var body: some View {
    TextEntrySheet(
      title: "New Folder", message: parent.map { "In “\($0.displayName)”" }, label: "Folder name",
      actionTitle: "Create", validate: { browser.validateName($0) },
      submit: { name in
        guard let parent else { return nil }
        return await browser.createFolder(named: name, in: parent)
      })
  }
}

/// Edit ▸ Rename…: the name is prefilled with its stem selected, like Finder.
struct RenameSheet: View {
  let target: RenameTarget
  let browser: BrowserController

  var body: some View {
    TextEntrySheet(
      title: target.isFolder ? "Rename Folder" : "Rename File", label: "Name", actionTitle: "Rename",
      initial: target.name, selecting: Self.stem(of: target.name, isFolder: target.isFolder),
      validate: { browser.validateName($0) },
      submit: { name in await browser.rename(target, to: name) })
  }

  /// "photo" in "photo.jpg"; the whole name for folders and dotfiles.
  private static func stem(of name: String, isFolder: Bool) -> Range<String.Index> {
    guard !isFolder, let dot = name.lastIndex(of: "."), dot != name.startIndex else {
      return name.startIndex..<name.endIndex
    }
    return name.startIndex..<dot
  }
}

/// Edit ▸ Move To…: a folder path in the same bucket, prefilled with the current folder.
struct MoveSheet: View {
  let target: MoveTarget
  let browser: BrowserController
  /// Kept so the sheet doesn't change while it animates away after a move.
  @State private var location: S3Location?

  init(target: MoveTarget, browser: BrowserController) {
    self.target = target
    self.browser = browser
    _location = State(initialValue: browser.model.browser.location)
  }

  var body: some View {
    let bucket = location?.bucket ?? ""
    TextEntrySheet(
      title: target.names.count == 1
        ? "Move “\(target.names[0])”" : "Move \(countLabel(target.names.count, "item"))",
      message: "Enter a folder in this bucket. Leave it empty to move to the top level.",
      label: "Folder path", fieldPrefix: "s3://\(bucket)/", actionTitle: "Move",
      initial: location?.prefix ?? "", validate: problem
    ) { path in
      guard let destination = try? S3Location(bucket: bucket, prefix: Self.prefix(path)) else {
        return "Open a bucket before moving files."
      }
      return await browser.move(target, to: destination)
    }
  }

  private func problem(_ path: String) -> String? {
    let prefix = Self.prefix(path)
    if prefix == location?.prefix { return "The items are already in this folder." }
    if target.ids.contains(where: { $0.isFolder && prefix.hasPrefix($0.keyString) }) {
      return "A folder can't be moved into itself."
    }
    return nil
  }

  /// "photos/2026" → "photos/2026/"; "" stays the bucket's top level.
  private static func prefix(_ path: String) -> String {
    var prefix = path.trimmingCharacters(in: .whitespaces)
    while prefix.hasPrefix("/") { prefix.removeFirst() }
    if !prefix.isEmpty && !prefix.hasSuffix("/") { prefix += "/" }
    return prefix
  }
}

/// Finder-style prompt while an upload or move waits for an answer; Cancel stops that transfer.
struct ConflictSheet: View {
  let prompt: ConflictPrompt
  let browser: BrowserController

  @State private var appliesToAll = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 16) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .frame(width: 56, height: 56)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 6) {
          Text("“\(prompt.name)” already exists in this folder.")
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
          Text("Replace overwrites it, Keep Both adds a numbered copy, Skip leaves it as it is.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(prompt.key)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
      }
      if prompt.remaining > 0 {
        Toggle("Apply to all \(countLabel(prompt.remaining + 1, "conflict"))", isOn: $appliesToAll)
      }
      HStack {
        Button("Cancel") { browser.cancelTransfer(prompt.transferID) }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Skip") { resolve(.skip) }
        Button("Replace", role: .destructive) { resolve(.replace) }
        Button("Keep Both") { resolve(.keepBoth) }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 460)
    .interactiveDismissDisabled()
  }

  private func resolve(_ choice: ConflictChoice) {
    browser.resolveConflict(choice, applyToAll: appliesToAll)
  }
}
