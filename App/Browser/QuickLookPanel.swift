import AppKit
import Quartz

/// Shows one file in the shared Quick Look panel. SwiftUI's `.quickLookPreview` trapped inside its own
/// panel observer when opening, so the browser drives `QLPreviewPanel` directly.
@MainActor
final class QuickLookPanel: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
  private var url: URL?
  private var onClose: (() -> Void)?

  /// Shows `url`, replacing what the panel shows; `onClose` runs once when the panel closes.
  func show(_ url: URL, onClose: @escaping () -> Void) {
    self.url = url
    self.onClose = onClose
    guard let panel = QLPreviewPanel.shared() else { return }
    panel.dataSource = self
    panel.delegate = self
    panel.reloadData()
    panel.makeKeyAndOrderFront(nil)
  }

  func close() {
    guard url != nil else { return }
    QLPreviewPanel.shared()?.close()
  }

  nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    MainActor.assumeIsolated { url == nil ? 0 : 1 }
  }

  nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
    MainActor.assumeIsolated { url as NSURL? }
  }

  nonisolated func windowWillClose(_ notification: Notification) {
    MainActor.assumeIsolated {
      url = nil
      let onClose = onClose
      self.onClose = nil
      onClose?()
    }
  }
}
