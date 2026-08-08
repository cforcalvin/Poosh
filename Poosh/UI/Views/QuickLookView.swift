import SwiftUI

struct ImagePanelView: View {
  @ObservedObject var viewModel: PreviewViewModel

  var body: some View {
    ZStack {
      // Outer frame / padding / toolbar gaps — not the image itself.
      WindowDragRepresentable()

      VStack(spacing: viewModel.showsRotateControls ? PreviewWindowLayout.rotateToolbarSpacing : 0) {
        if viewModel.showsRotateControls {
          HStack(spacing: 12) {
            toolbarButton(systemName: "rotate.left", help: "Rotate left") {
              viewModel.rotateLeft()
            }
            .disabled(viewModel.isCropping)

            toolbarButton(systemName: "rotate.right", help: "Rotate right") {
              viewModel.rotateRight()
            }
            .disabled(viewModel.isCropping)

            Spacer(minLength: 0)

            toolbarButton(systemName: "crop", help: "Crop") {
              if viewModel.isCropping {
                viewModel.cancelCropping()
              } else {
                viewModel.beginCropping()
              }
            }
          }
          .frame(height: PreviewWindowLayout.rotateToolbarHeight)
        }

        Group {
          switch viewModel.contentMode {
          case .avMedia:
            MediaPlayerRepresentable(url: viewModel.sourceURL)
              .frame(minWidth: 640, minHeight: 360)
          case .pdf:
            PDFPreviewRepresentable(url: viewModel.sourceURL)
              .frame(minWidth: 700, minHeight: 500)
          case .quickLook:
            QLPreviewRepresentable(url: viewModel.sourceURL)
              .frame(minWidth: 640, minHeight: 480)
          case .editableImage:
            ImagePreviewView(
              viewModel: viewModel,
              image: viewModel.processedImage,
              resetID: viewModel.sourceURL
            )
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .padding(16)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func toolbarButton(
    systemName: String,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white.opacity(0.9))
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
  }
}

struct CurvePanelView: View {
  @ObservedObject var viewModel: PreviewViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Tone Curve")
          .font(.headline)
          .foregroundStyle(.white.opacity(0.9))

        Spacer()

        Button {
          viewModel.resetCurve()
        } label: {
          Image(systemName: "arrow.counterclockwise")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help("Reset curve")
        .disabled(viewModel.isCropping)
      }

      ToneCurveGridView(toneCurve: viewModel.toneCurve)
        .allowsHitTesting(!viewModel.isCropping)
        .opacity(viewModel.isCropping ? 0.45 : 1)
    }
    .padding(16)
    .frame(width: 320, height: 300)
    .background(Color.clear)
  }
}
