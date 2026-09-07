import SwiftUI
import AppKit

struct ImagePreviewView: View {
  @ObservedObject var viewModel: PreviewViewModel
  let image: CGImage?
  /// Changes when the file changes so zoom resets.
  let resetID: URL

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
              guard !viewModel.isCropping, !viewModel.isColorAdjusting else { return }
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
                  crop: $viewModel.draftCrop
                )
              } else if viewModel.isColorAdjusting {
                ColorPickOverlayView(
                  imageSize: fittedImageSize(image: image, in: geometry.size),
                  containerSize: geometry.size,
                  isEyedropping: viewModel.isEyedropping
                ) { normalized in
                  viewModel.sampleHue(atNormalized: normalized)
                }
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
    }
    .onChange(of: resetID) { _, _ in
      viewModel.resetImageZoom()
    }
    .onChange(of: viewModel.isEyedropping) { _, eyedropping in
      EyedropperCursor.setActive(eyedropping)
    }
    .onChange(of: viewModel.isColorAdjusting) { _, adjusting in
      if !adjusting {
        EyedropperCursor.setActive(false)
      } else if viewModel.isEyedropping {
        EyedropperCursor.setActive(true)
      }
    }
    .onDisappear {
      EyedropperCursor.setActive(false)
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

/// Click-to-sample overlay for color adjust. Clicking outside the fitted image is ignored.
private struct ColorPickOverlayView: View {
  let imageSize: CGSize
  let containerSize: CGSize
  let isEyedropping: Bool
  let onPick: (CGPoint) -> Void

  private var imageOrigin: CGPoint {
    CGPoint(
      x: (containerSize.width - imageSize.width) / 2,
      y: (containerSize.height - imageSize.height) / 2
    )
  }

  private var imageFrame: CGRect {
    CGRect(origin: imageOrigin, size: imageSize)
  }

  var body: some View {
    Color.clear
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onEnded { value in
            let loc = value.location
            guard imageFrame.contains(loc), imageSize.width > 0, imageSize.height > 0 else { return }
            let nx = (loc.x - imageOrigin.x) / imageSize.width
            let ny = (loc.y - imageOrigin.y) / imageSize.height
            onPick(CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1)))
          }
      )
      .onHover { hovering in
        if hovering, isEyedropping {
          EyedropperCursor.setActive(true)
        } else if !isEyedropping {
          EyedropperCursor.setActive(false)
        }
      }
  }
}

/// Push/pop an eyedropper + crosshair cursor while color picking.
enum EyedropperCursor {
  private static var isPushed = false
  private static var cached: NSCursor?

  static func setActive(_ active: Bool) {
    DispatchQueue.main.async {
      if active {
        guard !isPushed else {
          cursor().set()
          return
        }
        cursor().push()
        isPushed = true
      } else if isPushed {
        NSCursor.pop()
        isPushed = false
      }
    }
  }

  private static func cursor() -> NSCursor {
    if let cached { return cached }
    let size = NSSize(width: 24, height: 24)
    let image = NSImage(size: size, flipped: false) { rect in
      // Crosshair
      NSColor.white.setStroke()
      let path = NSBezierPath()
      path.lineWidth = 1.5
      path.move(to: NSPoint(x: rect.midX, y: 2))
      path.line(to: NSPoint(x: rect.midX, y: rect.maxY - 2))
      path.move(to: NSPoint(x: 2, y: rect.midY))
      path.line(to: NSPoint(x: rect.maxX - 2, y: rect.midY))
      path.stroke()
      NSColor.black.withAlphaComponent(0.55).setStroke()
      let outline = NSBezierPath()
      outline.lineWidth = 0.75
      outline.move(to: NSPoint(x: rect.midX, y: 2))
      outline.line(to: NSPoint(x: rect.midX, y: rect.maxY - 2))
      outline.move(to: NSPoint(x: 2, y: rect.midY))
      outline.line(to: NSPoint(x: rect.maxX - 2, y: rect.midY))
      outline.stroke()

      // Eyedropper glyph (SF Symbol) in the lower-right.
      if let symbol = NSImage(
        systemSymbolName: "eyedropper",
        accessibilityDescription: nil
      ) {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let configured = symbol.withSymbolConfiguration(config) ?? symbol
        let drawRect = NSRect(x: rect.maxX - 13, y: 1, width: 12, height: 12)
        configured.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
      }
      return true
    }
    let made = NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    cached = made
    return made
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
        cropHandleView(handle)
          .position(handlePoint(handle))
          .gesture(resizeGesture(handle))
      }
    }
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private func cropHandleView(_ handle: CropHandle) -> some View {
    switch handle {
    case .topLeft, .topRight, .bottomLeft, .bottomRight:
      Circle()
        .fill(Color.white)
        .frame(width: handleSize, height: handleSize)
        .shadow(radius: 1)
    case .top, .bottom:
      Capsule()
        .fill(Color.white)
        .frame(width: 28, height: 8)
        .shadow(radius: 1)
    case .left, .right:
      Capsule()
        .fill(Color.white)
        .frame(width: 8, height: 28)
        .shadow(radius: 1)
    }
  }

  private func handlePoint(_ handle: CropHandle) -> CGPoint {
    switch handle {
    case .topLeft: return CGPoint(x: cropFrame.minX, y: cropFrame.minY)
    case .topRight: return CGPoint(x: cropFrame.maxX, y: cropFrame.minY)
    case .bottomLeft: return CGPoint(x: cropFrame.minX, y: cropFrame.maxY)
    case .bottomRight: return CGPoint(x: cropFrame.maxX, y: cropFrame.maxY)
    case .top: return CGPoint(x: cropFrame.midX, y: cropFrame.minY)
    case .bottom: return CGPoint(x: cropFrame.midX, y: cropFrame.maxY)
    case .left: return CGPoint(x: cropFrame.minX, y: cropFrame.midY)
    case .right: return CGPoint(x: cropFrame.maxX, y: cropFrame.midY)
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
        case .top:
          y += dy
          h -= dy
        case .bottom:
          h += dy
        case .left:
          x += dx
          w -= dx
        case .right:
          w += dx
        }

        let minSize = 0.05
        if w < minSize {
          switch handle {
          case .topLeft, .bottomLeft, .left:
            x = start.x + start.width - minSize
          default:
            break
          }
          w = minSize
        }
        if h < minSize {
          switch handle {
          case .topLeft, .topRight, .top:
            y = start.y + start.height - minSize
          default:
            break
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
  case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}
