import SwiftUI

struct ImagePanelView: View {
  @ObservedObject var viewModel: PreviewViewModel

  var body: some View {
    VStack(spacing: PreviewWindowLayout.rotateToolbarSpacing) {
      HStack(spacing: 12) {
        rotateButton(systemName: "rotate.left", help: "Rotate left") {
          viewModel.rotateLeft()
        }
        rotateButton(systemName: "rotate.right", help: "Rotate right") {
          viewModel.rotateRight()
        }
      }
      .frame(height: PreviewWindowLayout.rotateToolbarHeight)

      ImagePreviewView(image: viewModel.processedImage)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.clear)
  }

  private func rotateButton(
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
      }

      ToneCurveGridView(toneCurve: viewModel.toneCurve)
    }
    .padding(16)
    .frame(width: 320, height: 300)
    .background(Color.clear)
  }
}
