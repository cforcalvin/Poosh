import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Streams video/audio via AVPlayer so large media files start immediately
/// (unlike ``QLPreviewView``, which often blocks while preparing a full preview).
final class MediaPlayerHostView: NSView {
  private let playerView = AVPlayerView()
  private var player: AVPlayer?
  private var currentURL: URL?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    playerView.controlsStyle = .inline
    playerView.showsFullScreenToggleButton = true
    playerView.autoresizingMask = [.width, .height]
    playerView.frame = bounds
    addSubview(playerView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  func setMediaURL(_ url: URL) {
    let standardized = url.standardizedFileURL
    guard currentURL?.standardizedFileURL != standardized else { return }
    currentURL = url

    player?.pause()
    let item = AVPlayerItem(url: url)
    let newPlayer = AVPlayer(playerItem: item)
    newPlayer.automaticallyWaitsToMinimizeStalling = true
    player = newPlayer
    playerView.player = newPlayer
    newPlayer.play()
  }

  func teardown() {
    player?.pause()
    playerView.player = nil
    player = nil
    currentURL = nil
  }

  deinit {
    player?.pause()
  }
}

struct MediaPlayerRepresentable: NSViewRepresentable {
  let url: URL

  func makeNSView(context: Context) -> MediaPlayerHostView {
    let host = MediaPlayerHostView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
    host.setMediaURL(url)
    return host
  }

  func updateNSView(_ nsView: MediaPlayerHostView, context: Context) {
    nsView.setMediaURL(url)
  }

  static func dismantleNSView(_ nsView: MediaPlayerHostView, coordinator: ()) {
    nsView.teardown()
  }

  @available(macOS 13.0, *)
  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: MediaPlayerHostView,
    context: Context
  ) -> CGSize? {
    proposal.replacingUnspecifiedDimensions(by: CGSize(width: 960, height: 540))
  }
}
