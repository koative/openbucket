import AppKit
import CoreImage.CIFilterBuiltins
import OpenBucketCore
import SwiftUI
import UniformTypeIdentifiers

/// Presigned GET link for one object (or version), with copy, share and a QR code. Signed locally.
struct ShareLinkView: View {
  /// What the link is signed for; a change signs a new link.
  private struct Request: Hashable {
    var expiry = ShareLinkExpiry.day
    var downloads = true
    var attempt = 0
  }

  private struct Link {
    let url: URL
    let expires: Date
    /// Nil when the URL is too long for a QR code (e.g. long session tokens).
    let qr: CGImage?
    let request: Request
  }

  @Environment(\.dismiss) private var dismiss
  let object: ObjectSummary
  let versionID: String?
  let model: AppModel

  @State private var request = Request()
  @State private var link: Link?
  @State private var failure: String?
  @State private var copied = false
  @State private var showsQR = false
  @State private var showsFullLink = false

  init(object: ObjectSummary, versionID: String?, model: AppModel) {
    self.object = object
    self.versionID = versionID
    self.model = model
  }

  private var name: String { (object.key as NSString).lastPathComponent }

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding([.horizontal, .top], 20)
      if let source = model.downloadSource() {
        form(source)
      } else {
        ContentUnavailableView(
          "Not connected", systemImage: "link.badge.plus",
          description: Text("Open the bucket again to create a link.")
        )
        .padding(.vertical, 24)
      }
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding([.horizontal, .bottom], 20)
    }
    .frame(width: 460)
    .task(id: request) { await generate() }
    .task(id: copied) {
      guard copied else { return }
      try? await Task.sleep(for: .seconds(2))
      copied = false
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      let type = UTType(filenameExtension: (object.key as NSString).pathExtension) ?? .data
      Image(nsImage: NSWorkspace.shared.icon(for: type))
        .resizable()
        .frame(width: 40, height: 40)
      VStack(alignment: .leading, spacing: 3) {
        Text(name)
          .font(.headline)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(object.key)
        HStack(spacing: 6) {
          Text(object.size.formatted(.byteCount(style: .file)))
            .foregroundStyle(.secondary)
          if versionID != nil {
            InspectorBadge(
              object.lastModified.map { "Version from \($0.formatted(date: .abbreviated, time: .shortened))" }
                ?? "Earlier version")
          }
        }
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }

  private func form(_ source: AppModel.DownloadSource) -> some View {
    let lifetime = request.expiry.lifetime(signedWith: source.credentials)
    // The shown link only while it matches the settings; a new one is being signed otherwise.
    let ready = link?.request == request ? link : nil
    return Form {
      Section {
        Picker(selection: $request.expiry) {
          ForEach(ShareLinkExpiry.allCases, id: \.self) { Text($0.title).tag($0) }
        } label: {
          Text("Link expires")
          if let expires = ready?.expires ?? lifetime.map({ Date.now + $0.seconds }) {
            Text("Until \(expires.formatted(date: .abbreviated, time: .shortened))")
          }
        }
        Picker("When opened", selection: $request.downloads) {
          Text("Downloads the file").tag(true)
          Text("Opens in the browser").tag(false)
        }
      }

      Section {
        if let failure {
          HStack {
            // Red marks the error; the text stays primary so it keeps body contrast.
            Label {
              Text(failure)
            } icon: {
              Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Spacer()
            Button("Try Again") { request.attempt += 1 }
          }
        } else {
          VStack(alignment: .leading, spacing: 12) {
            // Settings change only the signature, so the last link's readable part stays right while signing.
            linkField(link?.url)
            actions(ready)
            if showsQR, let qr = link?.qr {
              Image(qr, scale: 1, label: Text("QR code for the link"))
                .interpolation(.none)
                .resizable()
                .frame(width: 152, height: 152)
                .padding(8)
                .background(.white, in: .rect(cornerRadius: 8))
                .frame(maxWidth: .infinity)
            }
          }
        }
      } footer: {
        VStack(alignment: .leading, spacing: 6) {
          Label("Anyone with the link can download this file until it expires.", systemImage: "info.circle")
          if let warning = lifetime?.warning {
            Label {
              Text(warning)
            } icon: {
              Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
            }
          }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
    .fixedSize(horizontal: false, vertical: true)
  }

  /// `host/bucket/key` of the link, never the signature; the full link on request.
  private func linkField(_ url: URL?) -> some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: "link")
        .foregroundStyle(.secondary)
      if let url {
        if showsFullLink {
          ScrollView {
            Text(url.absoluteString)
              .font(.callout.monospaced())
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .scrollDisabled(false)
          .frame(maxHeight: 96)
        } else {
          Text(Self.readablePart(of: url))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        ProgressView().controlSize(.small)
        Text("Creating link…").foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.quinary, in: .rect(cornerRadius: 8, style: .continuous))
    .help(url?.absoluteString ?? "")
    .contextMenu {
      if url != nil {
        Button(showsFullLink ? "Hide Full Link" : "Show Full Link") { showsFullLink.toggle() }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Link")
    .accessibilityValue(url.map(Self.readablePart) ?? "Creating link")
    .accessibilityAction(named: showsFullLink ? "Hide Full Link" : "Show Full Link") {
      showsFullLink.toggle()
    }
  }

  /// `ready` is the link for the current settings; the last link keeps the row's layout while signing.
  private func actions(_ ready: Link?) -> some View {
    HStack {
      if link?.qr != nil {
        Toggle("QR Code", systemImage: "qrcode", isOn: $showsQR.animation(.easeOut(duration: 0.2)))
          .toggleStyle(.button)
          .disabled(ready == nil)
      }
      Spacer()
      if let url = link?.url {
        ShareLink(item: url, subject: Text(name)) { Label("Share…", systemImage: "square.and.arrow.up") }
          .disabled(ready == nil)
      } else {
        Button("Share…", systemImage: "square.and.arrow.up") {}
          .disabled(true)
      }
      Button {
        if let url = ready?.url { copy(url) }
      } label: {
        // Both labels reserve their width so the button doesn't resize when it flips.
        ZStack {
          Label("Copied", systemImage: "checkmark").opacity(copied ? 1 : 0)
          Label("Copy Link", systemImage: "doc.on.doc").opacity(copied ? 0 : 1)
        }
      }
      .accessibilityLabel("Copy Link")
      .keyboardShortcut(.defaultAction)
      .disabled(ready == nil)
    }
  }

  private func copy(_ url: URL) {
    copyToPasteboard(url.absoluteString)
    copied = true
    AccessibilityNotification.Announcement("Link copied").post()
  }

  private func generate() async {
    copied = false
    failure = nil
    guard let source = model.downloadSource() else { return }
    let request = request
    let now = Date.now
    guard let lifetime = request.expiry.lifetime(signedWith: source.credentials, now: now) else {
      link = nil
      failure = "This connection’s temporary credentials have expired. Refresh and try again."
      return
    }
    do {
      let url = try await model.repository.presignedURL(
        profile: source.profile, credentials: source.credentials, bucket: source.bucket, key: object.key,
        versionID: versionID, expiresIn: .seconds(lifetime.seconds),
        downloadFileName: request.downloads ? PreviewFileName.from(objectKey: object.key) : nil)
      guard !Task.isCancelled else { return }
      link = Link(
        url: url, expires: now + lifetime.seconds, qr: Self.qrCode(url.absoluteString), request: request)
    } catch {
      guard !Task.isCancelled else { return }
      link = nil
      failure = AppModel.failure(for: error).message
    }
  }

  /// `host[:port]/path`: the bucket and key without the scheme or the signature query.
  private static func readablePart(of url: URL) -> String {
    (url.host(percentEncoded: false) ?? "") + (url.port.map { ":\($0)" } ?? "")
      + url.path(percentEncoded: false)
  }

  /// Nil when the text is too long for a QR code.
  private static func qrCode(_ text: String) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "L"
    guard let image = filter.outputImage else { return nil }
    return CIContext().createCGImage(image, from: image.extent)
  }
}
