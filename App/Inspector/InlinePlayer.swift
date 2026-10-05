import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// AVPlayerView with inline controls and a full-screen toggle. Pauses and drops the player when removed.
struct InlinePlayerView: NSViewRepresentable {
  let player: AVPlayer

  /// Audio and video AVFoundation can stream, by file extension.
  static func canPlay(_ key: String) -> Bool {
    guard let type = UTType(filenameExtension: (key as NSString).pathExtension) else { return false }
    return type.conforms(to: .audiovisualContent) && AVURLAsset.audiovisualContentTypes.contains(type)
  }

  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.controlsStyle = .inline
    view.showsFullScreenToggleButton = true
    view.player = player
    return view
  }

  func updateNSView(_ view: AVPlayerView, context: Context) {
    if view.player !== player { view.player = player }
  }

  static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
    view.player?.pause()
    view.player = nil
  }
}
