import SwiftUI
import AppKit

struct ImagePreviewView: View {
  @ObservedObject var viewModel: PreviewViewModel
  let image: CGImage?
  /// Changes when the file changes so zoom resets.
  let resetID: URL

  /// Normalized crop rect while editing (top-left origin). Starts full-frame.
  @State private var draftCrop = EditRecipe.CropRect.full

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.opacity(0.2)

        if let image {
          Image(decorative: image, scale: 1.0, orientation: .up)
            .resizable()
            .interpolation(viewModel.imageScale > 1.01 ? .high : .medium)
            .aspectRatio(contentMode: .fit)
            .scaleEffect(viewModel.imageScale)
            .offset(viewModel.imageOffset)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
              guard !viewModel.isCropping else { return }
              withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.resetImageZoom()
              }
            }
            .transition(.identity)
            .overlay {
              if viewModel.isCropping {
                CropOverlayView(
                  imageSize: fittedImageSize(image: image, in: geometry.size),
                  containerSize: geometry.size,
                  crop: $draftCrop
                )
              }
            }
            .onAppear {
              viewModel.updatePreviewLayout(viewport: geometry.size)
            }
            .onChange(of: geometry.size) { _, newSize in
              viewModel.updatePreviewLayout(viewport: newSize)
            }
        }
      }
      // Claim the whole preview so clicks never fall through to window-drag chrome.
      .contentShape(Rectangle())
      .clipped()
      .overlay(alignment: .bottom) {
        if viewModel.isCropping {
          HStack(spacing: 16) {
            Button("Cancel") {
              viewModel.cancelCropping()
            }
            .keyboardShortcut(.cancelAction)

            Button("Apply") {
              viewModel.applyCrop(draftCrop)
              viewModel.resetImageZoom()
            }
            .keyboardShortcut(.defaultAction)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .padding(.bottom, 12)
        }
      }
    }
    .onChange(of: resetID) { _, _ in
      viewModel.resetImageZoom()
    }
    .onChange(of: viewModel.isCropping) { _, isCropping in
      if isCropping {
        viewModel.resetImageZoom()
        if let existing = viewModel.cropRect, !existing.isIdentity {
          draftCrop = existing.clamped()
        } else {
          draftCrop = .full
        }
      }
    }
  }

  private func fittedImageSize(image: CGImage, in container: CGSize) -> CGSize {
    let iw = CGFloat(image.width)
    let ih = CGFloat(image.height)
    guard iw > 0, ih > 0, container.width > 0, container.height > 0 else { return container }
    let scale = min(container.width / iw, container.height / ih)
    return CGSize(width: iw * scale, height: ih * scale)
  }
}

/// Freeform crop rectangle over the fitted image bounds.
private struct CropOverlayView: View {
  let imageSize: CGSize
  let containerSize: CGSize
  @Binding var crop: EditRecipe.CropRect

  @State private var dragStartCrop: EditRecipe.CropRect?

  private let handleSize: CGFloat = 14

  private var imageOrigin: CGPoint {
    CGPoint(
      x: (containerSize.width - imageSize.width) / 2,
      y: (containerSize.height - imageSize.height) / 2
    )
  }

  private var cropFrame: CGRect {
    CGRect(
      x: imageOrigin.x + crop.x * imageSize.width,
      y: imageOrigin.y + crop.y * imageSize.height,
      width: crop.width * imageSize.width,
      height: crop.height * imageSize.height
    )
  }

  var body: some View {
    ZStack {
      Path { path in
        path.addRect(CGRect(origin: .zero, size: containerSize))
        path.addRect(cropFrame)
      }
      .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
      .allowsHitTesting(false)

      Color.clear
        .contentShape(Rectangle())
        .gesture(moveGesture)

      Rectangle()
        .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.5)
        .frame(width: cropFrame.width, height: cropFrame.height)
        .position(x: cropFrame.midX, y: cropFrame.midY)
        .allowsHitTesting(false)

      ForEach(CropHandle.allCases, id: \.self) { handle in
        Circle()
          .fill(Color.white)
          .frame(width: handleSize, height: handleSize)
          .shadow(radius: 1)
          .position(handlePoint(handle))
          .gesture(resizeGesture(handle))
      }
    }
    .contentShape(Rectangle())
  }

  private func handlePoint(_ handle: CropHandle) -> CGPoint {
    switch handle {
    case .topLeft: return CGPoint(x: cropFrame.minX, y: cropFrame.minY)
    case .topRight: return CGPoint(x: cropFrame.maxX, y: cropFrame.minY)
    case .bottomLeft: return CGPoint(x: cropFrame.minX, y: cropFrame.maxY)
    case .bottomRight: return CGPoint(x: cropFrame.maxX, y: cropFrame.maxY)
    }
  }

  private var moveGesture: some Gesture {
    DragGesture()
      .onChanged { value in
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        if dragStartCrop == nil { dragStartCrop = crop }
        guard let start = dragStartCrop else { return }
        let dx = value.translation.width / imageSize.width
        let dy = value.translation.height / imageSize.height
        var next = start
        next.x = start.x + dx
        next.y = start.y + dy
        next.x = min(max(next.x, 0), 1 - next.width)
        next.y = min(max(next.y, 0), 1 - next.height)
        crop = next
      }
      .onEnded { _ in
        crop = crop.clamped()
        dragStartCrop = nil
      }
  }

  private func resizeGesture(_ handle: CropHandle) -> some Gesture {
    DragGesture()
      .onChanged { value in
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        if dragStartCrop == nil { dragStartCrop = crop }
        guard let start = dragStartCrop else { return }
        let dx = value.translation.width / imageSize.width
        let dy = value.translation.height / imageSize.height
        var x = start.x
        var y = start.y
        var w = start.width
        var h = start.height

        switch handle {
        case .topLeft:
          x += dx
          y += dy
          w -= dx
          h -= dy
        case .topRight:
          y += dy
          w += dx
          h -= dy
        case .bottomLeft:
          x += dx
          w -= dx
          h += dy
        case .bottomRight:
          w += dx
          h += dy
        }

        let minSize = 0.05
        if w < minSize {
          if handle == .topLeft || handle == .bottomLeft {
            x = start.x + start.width - minSize
          }
          w = minSize
        }
        if h < minSize {
          if handle == .topLeft || handle == .topRight {
            y = start.y + start.height - minSize
          }
          h = minSize
        }

        crop = EditRecipe.CropRect(x: x, y: y, width: w, height: h).clamped()
      }
      .onEnded { _ in
        crop = crop.clamped()
        dragStartCrop = nil
      }
  }
}

private enum CropHandle: CaseIterable {
  case topLeft, topRight, bottomLeft, bottomRight
}
