import AppKit
import OpenBucketCore
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Thumbnail or SF Symbol for a row. Unclipped: the caller applies the one clip shape it needs.
struct BrowserArtwork: View {
  let row: BrowserRow
  var contentMode: ContentMode = .fill
  var symbolSize: CGFloat = 42
  var showsVideoBadge = true

  @AppStorage("showsPreviews") private var showsPreviews = true

  var body: some View {
    // Overlays keep the layout at the proposed size; an aspect-filled thumbnail would otherwise grow
    // the view and push the video badge outside the caller's clip.
    Color.secondary.opacity(0.08)
      .overlay {
        // Range reads have no version parameter, so versions use the full-download path only.
        let embedded = row.versionID == nil && Self.embedsThumbnail(row.fullKey)
        if showsPreviews, let object = row.object, embedded || row.hasThumbnail {
          BrowserThumbnail(
            object: object, versionID: row.versionID, readsPrefix: embedded, symbol: row.symbol,
            contentMode: contentMode, symbolSize: symbolSize)
        } else {
          symbolView
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if row.isVideo && showsVideoBadge {
          Image(systemName: "play.fill")
            .padding(8)
            .background(.regularMaterial, in: Circle())
            .padding(8)
            .accessibilityHidden(true)
        }
      }
  }

  private var symbolView: some View {
    Image(systemName: row.symbol)
      .font(.system(size: symbolSize, weight: .light))
      .foregroundStyle(row.isFolder ? Color.accentColor : Color.secondary)
  }

  /// Formats whose first bytes usually carry an EXIF thumbnail (JPEG, HEIF, TIFF, camera RAW).
  private static func embedsThumbnail(_ key: String) -> Bool {
    guard let type = UTType(filenameExtension: (key as NSString).pathExtension) else { return false }
    return [UTType.jpeg, .heic, .heif, .tiff, .rawImage].contains { type.conforms(to: $0) }
  }
}

private struct BrowserThumbnail: View {
  let object: ObjectSummary
  let versionID: String?
  /// Try the embedded thumbnail from the first `ImageMetadata.prefixLength` bytes before downloading.
  let readsPrefix: Bool
  let symbol: String
  let contentMode: ContentMode
  let symbolSize: CGFloat

  // Optional: AppKit-hosted copies of a row (e.g. NSTableView drag images) render outside the window's
  // environment; they show the symbol instead of crashing.
  @Environment(AppModel.self) private var model: AppModel?
  @State private var image: NSImage?
  @State private var loadedKey: String?

  @MainActor private static let cache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 96
    return cache
  }()
  /// Keys whose content gave no thumbnail (undecodable, or no embedded thumbnail in a large file); not
  /// retried until relaunch. Thrown errors (network, expired credentials) retry when the cell reappears.
  @MainActor private static var failedKeys = Set<String>()

  var body: some View {
    let source = model?.downloadSource()
    let key = source.map {
      "\($0.profile.id)|\($0.bucket)|\(object.key)|\(versionID ?? "")|\(object.eTag ?? "")|\(object.size)"
    }
    Group {
      if let key,
        let image = Self.cache.object(forKey: key as NSString) ?? (loadedKey == key ? self.image : nil)
      {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: contentMode)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .transition(.opacity)
      } else {
        Image(systemName: symbol)
          .font(.system(size: symbolSize, weight: .light))
          .foregroundStyle(.secondary)
      }
    }
    .animation(.easeOut(duration: 0.18), value: loadedKey)
    .task(id: key) {
      guard let key, let model, let source, Self.cache.object(forKey: key as NSString) == nil,
        !Self.failedKeys.contains(key)
      else { return }
      do {
        var thumbnail: NSImage?
        if readsPrefix {
          let data = try await model.repository.readObjectBytes(
            profile: source.profile, credentials: source.credentials, bucket: source.bucket,
            key: object.key, range: 0..<ImageMetadata.prefixLength)
          // Small EXIF thumbnails (often 160 px) look blurry in cards; files we can download get 520 px.
          if let embedded = await Self.embeddedThumbnail(data),
            object.size > BrowserRow.thumbnailLimit || max(embedded.width, embedded.height) >= 300
          {
            thumbnail = NSImage(cgImage: embedded, size: .zero)
          }
        }
        if thumbnail == nil, object.size <= BrowserRow.thumbnailLimit {
          let file = try await model.downloadToPrivateTemp(
            object, versionID: versionID, from: source, maximumBytes: BrowserRow.thumbnailLimit)
          defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
          let request = QLThumbnailGenerator.Request(
            fileAt: file, size: CGSize(width: 520, height: 520), scale: 1, representationTypes: .thumbnail)
          // A thrown error here means content Quick Look can't render.
          thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
        guard !Task.isCancelled else { return }
        guard let thumbnail else {
          Self.failedKeys.insert(key)
          return
        }
        Self.cache.setObject(thumbnail, forKey: key as NSString)
        image = thumbnail
        loadedKey = key
      } catch {
        // Not recorded in `failedKeys`: network and credential errors are worth another try.
      }
    }
  }

  @concurrent private nonisolated static func embeddedThumbnail(_ data: Data) async -> CGImage? {
    ImageMetadata.read(data).thumbnail
  }
}
