import SwiftUI

struct ImagePreviewView: View {
  let image: CGImage?
  /// Changes when the file changes so zoom resets.
  let resetID: URL

  @State private var scale: CGFloat = 1
  @State private var lastScale: CGFloat = 1
  @State private var offset: CGSize = .zero
  @State private var lastOffset: CGSize = .zero

  private let minScale: CGFloat = 1
  private let maxScale: CGFloat = 8

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.opacity(0.2)

        if let image {
          Image(decorative: image, scale: 1.0, orientation: .up)
            .resizable()
            .interpolation(scale > 1.01 ? .high : .medium)
            .aspectRatio(contentMode: .fit)
            .scaleEffect(scale)
            .offset(offset)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(magnificationGesture)
            .gesture(scale > 1.01 ? dragGesture : nil)
            .onTapGesture(count: 2) {
              withAnimation(.easeInOut(duration: 0.2)) {
                resetZoom()
              }
            }
            .transition(.identity)
        }
        // No ProgressView spinner — empty fill while waiting avoids flicker on arrow swaps.
      }
      .clipped()
    }
    .onChange(of: resetID) { _, _ in
      resetZoom()
    }
  }

  private var magnificationGesture: some Gesture {
    MagnificationGesture()
      .onChanged { value in
        let next = lastScale * value
        scale = min(max(next, minScale), maxScale)
      }
      .onEnded { _ in
        lastScale = scale
        if scale <= 1.01 {
          withAnimation(.easeOut(duration: 0.15)) {
            resetZoom()
          }
        }
      }
  }

  private var dragGesture: some Gesture {
    DragGesture()
      .onChanged { value in
        offset = CGSize(
          width: lastOffset.width + value.translation.width,
          height: lastOffset.height + value.translation.height
        )
      }
      .onEnded { _ in
        lastOffset = offset
      }
  }

  private func resetZoom() {
    scale = 1
    lastScale = 1
    offset = .zero
    lastOffset = .zero
  }
}
