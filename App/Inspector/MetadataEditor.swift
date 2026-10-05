import AppKit
import OpenBucketCore
import SwiftUI
import UniformTypeIdentifiers

/// Content headers, user metadata and tags of the current version of one object.
struct MetadataEditor: View {
  private struct Pair: Identifiable {
    let id = UUID()
    var name = ""
    var value = ""
  }

  @Environment(\.dismiss) private var dismiss
  let target: MetadataTarget
  let browser: BrowserController

  @State private var contentType: String
  @State private var cacheControl: String
  @State private var contentDisposition: String
  @State private var contentEncoding: String
  @State private var contentLanguage: String
  @State private var metadata: [Pair]
  @State private var tags: [Pair]
  @State private var failure: String?
  @State private var isSaving = false

  private static let maxTags = 10

  init(target: MetadataTarget, browser: BrowserController) {
    self.target = target
    self.browser = browser
    let headers = target.headers
    _contentType = State(initialValue: headers.contentType ?? "")
    _cacheControl = State(initialValue: headers.cacheControl ?? "")
    _contentDisposition = State(initialValue: headers.contentDisposition ?? "")
    _contentEncoding = State(initialValue: headers.contentEncoding ?? "")
    _contentLanguage = State(initialValue: headers.contentLanguage ?? "")
    _metadata = State(initialValue: Self.pairs(headers.metadata))
    _tags = State(initialValue: Self.pairs(target.tags ?? [:]))
  }

  private var name: String { (target.object.key as NSString).lastPathComponent }

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding([.horizontal, .top], 20)
      Form {
        Section("Content headers") {
          TextField("Content-Type", text: $contentType, prompt: Text("e.g. image/png"))
          TextField("Cache-Control", text: $cacheControl, prompt: Text("e.g. max-age=3600"))
          TextField("Content-Disposition", text: $contentDisposition, prompt: Text("e.g. attachment"))
          TextField("Content-Encoding", text: $contentEncoding, prompt: Text("e.g. gzip"))
          TextField("Content-Language", text: $contentLanguage, prompt: Text("e.g. en-US"))
        }

        Section {
          pairRows($metadata, problem: metadataProblem)
          Button("Add Metadata", systemImage: "plus") { metadata.append(Pair()) }
        } header: {
          Text("Metadata")
        } footer: {
          Text("Sent as x-amz-meta-name headers. Names are saved in lowercase.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        Section {
          if target.tags == nil {
            Text("Tags can't be read with this connection, so they're left as they are.")
              .foregroundStyle(.secondary)
          } else {
            pairRows($tags, problem: tagProblem)
            Button("Add Tag", systemImage: "plus") { tags.append(Pair()) }
              .disabled(tags.count >= Self.maxTags)
          }
        } header: {
          Text("Tags")
        } footer: {
          if target.tags != nil {
            Text("Up to \(Self.maxTags) tags. Names up to 128 characters, values up to 256.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        status
        Spacer(minLength: 12)
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") { Task { await save() } }
          .keyboardShortcut(.defaultAction)
          .disabled(isSaving || hasProblems)
      }
      .padding()
    }
    .frame(minWidth: 520, idealWidth: 560, minHeight: 560)
    .interactiveDismissDisabled(isSaving)
  }

  private var header: some View {
    HStack(spacing: 12) {
      let type = UTType(filenameExtension: (target.object.key as NSString).pathExtension) ?? .data
      Image(nsImage: NSWorkspace.shared.icon(for: type))
        .resizable()
        .frame(width: 40, height: 40)
      VStack(alignment: .leading, spacing: 3) {
        Text(name)
          .font(.headline)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(target.object.key)
        Text("Saving rewrites the file in place, so its modified date changes.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var status: some View {
    if isSaving {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Saving…")
      }
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
    } else if let failure {
      InspectorProblem(failure)
        .lineLimit(3)
        .help(failure)
    }
  }

  /// Name and value fields with a remove button, plus the row's problem underneath.
  private func pairRows(_ pairs: Binding<[Pair]>, problem: @escaping (Pair) -> String?) -> some View {
    ForEach(pairs) { $pair in
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          TextField("Name", text: $pair.name, prompt: Text("Name"))
            .labelsHidden()
            .frame(maxWidth: 180)
          TextField("Value", text: $pair.value, prompt: Text("Value"))
            .labelsHidden()
          Button("Remove", systemImage: "minus.circle.fill") {
            pairs.wrappedValue.removeAll { $0.id == pair.id }
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .help("Remove")
        }
        if let text = problem(pair) {
          InspectorProblem(text)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func metadataProblem(_ pair: Pair) -> String? {
    let name = Self.trim(pair.name).lowercased()
    if name.isEmpty { return pair.value.isEmpty ? nil : "Enter a name." }
    if !name.unicodeScalars.allSatisfy(Self.tokenCharacters.contains) {
      return "Use only letters a–z, digits, and - _ . in names."
    }
    if metadata.count(where: { Self.trim($0.name).lowercased() == name }) > 1 {
      return "This name is used twice."
    }
    return nil
  }

  private func tagProblem(_ pair: Pair) -> String? {
    let name = Self.trim(pair.name)
    if name.isEmpty { return pair.value.isEmpty ? nil : "Enter a name." }
    if name.count > 128 { return "Names can be up to 128 characters." }
    if pair.value.count > 256 { return "Values can be up to 256 characters." }
    if tags.count(where: { Self.trim($0.name) == name }) > 1 { return "This name is used twice." }
    return nil
  }

  private var hasProblems: Bool {
    metadata.contains { metadataProblem($0) != nil }
      || (target.tags != nil && tags.contains { tagProblem($0) != nil })
  }

  private func save() async {
    guard !hasProblems else { return }
    let headers = ObjectHeaders(
      contentType: Self.header(contentType), cacheControl: Self.header(cacheControl),
      contentDisposition: Self.header(contentDisposition), contentEncoding: Self.header(contentEncoding),
      contentLanguage: Self.header(contentLanguage),
      metadata: Self.dictionary(metadata, lowercased: true))
    let newTags = target.tags == nil ? nil : Self.dictionary(tags, lowercased: false)
    isSaving = true
    failure = await browser.saveMetadata(target, headers: headers, tags: newTags)
    isSaving = false
    if failure == nil { dismiss() }
  }

  /// HTTP token characters (RFC 9110), which are all a header name may hold.
  private static let tokenCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~")

  private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// Blank fields are omitted, so the object has no such header.
  private static func header(_ text: String) -> String? {
    let value = trim(text)
    return value.isEmpty ? nil : value
  }

  private static func pairs(_ dictionary: [String: String]) -> [Pair] {
    dictionary.sorted { $0.key < $1.key }.map { Pair(name: $0.key, value: $0.value) }
  }

  /// Rows without a name are blank rows the user never filled in.
  private static func dictionary(_ pairs: [Pair], lowercased: Bool) -> [String: String] {
    Dictionary(
      pairs.compactMap { pair in
        let name = trim(pair.name)
        return name.isEmpty ? nil : (lowercased ? name.lowercased() : name, pair.value)
      },
      uniquingKeysWith: { $1 })
  }
}
