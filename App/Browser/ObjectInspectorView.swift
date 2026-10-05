import AVKit
import OpenBucketCore
import SwiftUI
import UniformTypeIdentifiers

/// Inspector content that follows the selection: none, one item, or several.
struct InspectorPane: View {
  let rows: [BrowserRow]
  let browser: BrowserController

  var body: some View {
    let selected = rows.filter { browser.selection.contains($0.id) }
    if selected.count == 1 {
      // A fresh view per item and version, so nothing (details, a playing video) lingers.
      ObjectInspectorView(row: selected[0], browser: browser)
        .id([AnyHashable(selected[0].id), AnyHashable(selected[0].versionID)])
    } else if selected.isEmpty {
      ContentUnavailableView(
        "No Selection", systemImage: "info.circle",
        description: Text("Select a file or folder to see its details."))
    } else {
      let files = selected.compactMap(\.object)
      ContentUnavailableView {
        Label(countLabel(selected.count, "item"), systemImage: "square.stack")
      } description: {
        if !files.isEmpty {
          Text(
            "\(countLabel(files.count, "file")) · \(files.reduce(Int64.zero) { $0 + $1.size }.formatted(.byteCount(style: .file)))"
          )
        }
      } actions: {
        Button("Download…") { browser.download(Set(selected.map(\.id))) }
          .buttonStyle(.borderedProminent)
          .disabled(files.isEmpty)
      }
    }
  }
}

struct ObjectInspectorView: View {
  let row: BrowserRow
  let browser: BrowserController

  @State private var player: AVPlayer?
  @State private var playerFailure: String?

  private var model: AppModel { browser.model }
  private var canPlay: Bool { row.object != nil && InlinePlayerView.canPlay(row.fullKey) }
  private var isImage: Bool {
    UTType(filenameExtension: (row.fullKey as NSString).pathExtension)?.conforms(to: .image) == true
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        artwork
          .frame(height: 180)
          .clipShape(.rect(cornerRadius: 12, style: .continuous))

        Text(row.name)
          .font(.title3.weight(.semibold))
          .lineLimit(2)
          .truncationMode(.middle)
          .textSelection(.enabled)
          .padding(.top, 16)

        HStack(spacing: 8) {
          Text([row.kindLabel, row.sizeLabel].compactMap { $0 }.joined(separator: " · "))
          if row.isDeleted { InspectorBadge("Deleted", tint: .red) }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.top, 4)

        if let object = row.object {
          actions(object)
            .padding(.top, 18)
        }

        Divider()
          .padding(.vertical, 20)

        HStack(alignment: .firstTextBaseline) {
          Text("Details")
            .font(.headline)
          Spacer()
          if browser.canModify, let object = row.object, row.versionID == nil, !row.isDeleted {
            Button("Edit…") { browser.requestEditMetadata(object) }
              .controlSize(.small)
              .help("Edit content headers, metadata and tags")
          }
        }
        .padding(.bottom, 10)

        if let object = row.object {
          ObjectDetailsGrid(key: object.key, versionID: row.versionID, browser: browser) {
            uriField
            InspectorField("Size") { Text(Self.sizeText(object.size)) }
            if let date = object.lastModified {
              InspectorField("Modified") { Text(date.formatted(date: .abbreviated, time: .shortened)) }
            }
            if let eTag = object.eTag {
              InspectorField("ETag") {
                InspectorValue(
                  text: eTag.trimmingCharacters(in: CharacterSet(charactersIn: "\"")), monospaced: true)
              }
            }
          }

          // ponytail: range reads have no version parameter, so photo info shows for current files only.
          if isImage, row.versionID == nil {
            PhotoInfoSection(key: object.key, model: model)
          }
          VersionsSection(key: object.key, browser: browser)
        } else {
          InspectorGrid { uriField }
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onDisappear(perform: stop)
  }

  @ViewBuilder private var uriField: some View {
    if let bucket = model.browser.location?.bucket {
      InspectorField("S3 URI") {
        InspectorValue(text: "s3://\(bucket)/\(row.fullKey)", monospaced: true)
      }
    }
  }

  /// "2.1 MB (2,097,152 bytes)"; small sizes are already exact.
  private static func sizeText(_ size: Int64) -> String {
    let rounded = size.formatted(.byteCount(style: .file))
    return size < 1000 ? rounded : "\(rounded) (\(size.formatted()) bytes)"
  }

  @ViewBuilder private var artwork: some View {
    if let player {
      InlinePlayerView(player: player)
    } else {
      BrowserArtwork(row: row, contentMode: .fit, symbolSize: 56, showsVideoBadge: !canPlay)
        .accessibilityLabel("Preview of \(row.name)")
        .overlay {
          if canPlay, let object = row.object {
            Button("Play", systemImage: "play.fill") { play(object) }
              .buttonStyle(.glass)
              .controlSize(.large)
          }
        }
    }
  }

  private func actions(_ object: ObjectSummary) -> some View {
    let tooLarge = object.size > BrowserRow.previewLimit
    return VStack(alignment: .leading, spacing: 10) {
      // Widest layout that fits: every action titled, then only Download titled, then icons only.
      // Icon buttons keep their labels for VoiceOver and help tags.
      ViewThatFits(in: .horizontal) {
        actionButtons(object, tooLarge: tooLarge, secondaryTitled: true, primaryTitled: true)
        actionButtons(object, tooLarge: tooLarge, secondaryTitled: false, primaryTitled: true)
        actionButtons(object, tooLarge: tooLarge, secondaryTitled: false, primaryTitled: false)
      }
      .controlSize(.large)
      if let playerFailure {
        InspectorProblem(playerFailure)
          .font(.callout)
      } else if tooLarge && !canPlay {
        Text(
          "Quick Look is available for files up to \(BrowserRow.previewLimit.formatted(.byteCount(style: .memory)))."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } else if let failure = browser.previewFailure, failure.id == row.id {
        InspectorProblem(failure.message)
          .font(.callout)
      }
    }
  }

  private func actionButtons(
    _ object: ObjectSummary, tooLarge: Bool, secondaryTitled: Bool, primaryTitled: Bool
  ) -> some View {
    // Titled buttons share the width; an icon button stays compact unless every button is an icon.
    let allIcons = !secondaryTitled && !primaryTitled
    return HStack(spacing: 10) {
      if browser.preparingPreview?.id == object.id {
        Button {
          browser.cancelPreview()
        } label: {
          Label {
            Text("Cancel")
          } icon: {
            ProgressView().controlSize(.small)
          }
        }
        .actionStyle(titled: secondaryTitled, stretches: secondaryTitled || allIcons)
        .help("Preparing Quick Look… Click to cancel.")
      } else if tooLarge && canPlay {
        // Streams instead of downloading, so media above the Quick Look limit still opens.
        Button("Play", systemImage: "play.fill") { play(object) }
          .actionStyle(titled: secondaryTitled, stretches: secondaryTitled || allIcons)
          .help("Play")
          .disabled(player != nil)
      } else {
        Button("Quick Look", systemImage: "eye") { browser.quickLook(object, versionID: row.versionID) }
          .actionStyle(titled: secondaryTitled, stretches: secondaryTitled || allIcons)
          .help("Quick Look (Space)")
          .disabled(tooLarge)
      }
      Button("Download…", systemImage: "arrow.down.to.line") {
        browser.download(object, versionID: row.versionID)
      }
      .actionStyle(titled: primaryTitled, stretches: true)
      .buttonStyle(.borderedProminent)
      .help("Download…")
      Button("Share Link…", systemImage: "square.and.arrow.up") {
        browser.shareTarget = ShareTarget(object: object, versionID: row.versionID)
      }
      .actionStyle(titled: false, stretches: allIcons)
      .help("Share Link…")
    }
    .buttonStyle(.bordered)
  }

  /// Streams through a 1-hour presigned GET URL; nothing is downloaded to disk.
  private func play(_ object: ObjectSummary) {
    playerFailure = nil
    guard let source = model.downloadSource() else { return }
    Task {
      do {
        let url = try await model.repository.presignedURL(
          profile: source.profile, credentials: source.credentials, bucket: source.bucket, key: object.key,
          versionID: row.versionID, expiresIn: .seconds(3600), downloadFileName: nil)
        player = AVPlayer(url: url)
        player?.play()
      } catch {
        playerFailure = AppModel.failure(for: error).message
      }
    }
  }

  private func stop() {
    player?.pause()
    player = nil
  }
}

extension View {
  /// Inspector action button: titled or icon-only, optionally filling its share of the row.
  @ViewBuilder fileprivate func actionStyle(titled: Bool, stretches: Bool) -> some View {
    Group {
      if titled { self.labelStyle(.titleAndIcon) } else { self.labelStyle(.iconOnly) }
    }
    .buttonSizing(stretches ? .flexible : .fitted)
  }
}
