import SwiftUI

struct ImagePreviewView: View {
  let image: CGImage?

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.opacity(0.2)

        if let image {
          Image(decorative: image, scale: 1.0, orientation: .up)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: geometry.size.width, height: geometry.size.height)
        } else {
          ProgressView()
            .controlSize(.large)
        }
      }
    }
  }
}
