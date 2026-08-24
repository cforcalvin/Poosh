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
            if viewModel.isCropping {
              Spacer(minLength: 0)

              HStack(spacing: 14) {
                Text(String(format: "%+.0f°", viewModel.straightenDegrees))
                  .font(.system(size: 13, weight: .semibold).monospacedDigit())
                  .foregroundStyle(Color.white.opacity(0.9))
                  .frame(width: 44, alignment: .trailing)

                Slider(
                  value: Binding(
                    get: { viewModel.straightenDegrees },
                    set: { viewModel.setStraightenDegrees($0) }
                  ),
                  in: -45...45
                )
                .frame(width: 180)
                .help("Straighten")

                Button("Cancel") {
                  viewModel.cancelCropping()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)

                Button("Apply") {
                  viewModel.applyDraftCrop()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
              }
              .controlSize(.regular)

              Spacer(minLength: 0)
            } else {
              toolbarButton(systemName: "rotate.left", help: "Rotate left") {
                viewModel.rotateLeft()
              }

              toolbarButton(systemName: "rotate.right", help: "Rotate right") {
                viewModel.rotateRight()
              }

              Spacer(minLength: 0)

              toolbarButton(
                systemName: "circle.lefthalf.filled",
                help: viewModel.isBlackAndWhite ? "Color (B)" : "Black & White (B)",
                isActive: viewModel.isBlackAndWhite
              ) {
                viewModel.toggleBlackAndWhite()
              }

              toolbarButton(systemName: "crop", help: "Crop (C)") {
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
    isActive: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(isActive ? Color.accentColor : Color.white.opacity(0.9))
        .frame(width: 36, height: 36)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isActive ? Color.white.opacity(0.18) : Color.clear)
        )
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
