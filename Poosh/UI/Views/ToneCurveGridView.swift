import SwiftUI

struct ToneCurveGridView: View {
  @ObservedObject var toneCurve: ToneCurve

  @State private var draggingPointID: UUID?

  private let gridInset: CGFloat = 24
  private let pointRadius: CGFloat = 6
  private let pointHitRadius: CGFloat = 14
  private let curveHitRadius: CGFloat = 22

  var body: some View {
    GeometryReader { geometry in
      let plotRect = plotFrame(in: geometry.size)

      ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.white.opacity(0.04))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(Color.white.opacity(0.15), lineWidth: 1)
          )

        Canvas { context, _ in
          drawGrid(in: plotRect, context: &context)
          drawIdentityLine(in: plotRect, context: &context)
          drawSpline(in: plotRect, context: &context)
          drawControlPoints(in: plotRect, context: &context)
        }
        .contentShape(Rectangle())
        .gesture(interactionGesture(in: plotRect))
        .simultaneousGesture(
          SpatialTapGesture(count: 2)
            .onEnded { event in
              handleDoubleTap(at: event.location, in: plotRect)
            }
        )
      }
    }
  }

  private func plotFrame(in size: CGSize) -> CGRect {
    CGRect(
      x: gridInset,
      y: gridInset,
      width: max(size.width - gridInset * 2, 1),
      height: max(size.height - gridInset * 2, 1)
    )
  }

  private func drawGrid(in rect: CGRect, context: inout GraphicsContext) {
    let divisions = 4
    var gridPath = Path()

    for division in 0...divisions {
      let t = CGFloat(division) / CGFloat(divisions)
      let x = rect.minX + rect.width * t
      let y = rect.maxY - rect.height * t
      gridPath.move(to: CGPoint(x: x, y: rect.minY))
      gridPath.addLine(to: CGPoint(x: x, y: rect.maxY))
      gridPath.move(to: CGPoint(x: rect.minX, y: y))
      gridPath.addLine(to: CGPoint(x: rect.maxX, y: y))
    }

    context.stroke(gridPath, with: .color(.white.opacity(0.12)), lineWidth: 1)
  }

  private func drawIdentityLine(in rect: CGRect, context: inout GraphicsContext) {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    context.stroke(path, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
  }

  private func drawSpline(in rect: CGRect, context: inout GraphicsContext) {
    let samples = toneCurve.sampleCurve(count: 128)
    guard let first = samples.first else { return }

    var path = Path()
    path.move(to: plotPoint(first, in: rect))
    for sample in samples.dropFirst() {
      path.addLine(to: plotPoint(sample, in: rect))
    }

    context.stroke(path, with: .color(.yellow.opacity(0.95)), lineWidth: 2)
  }

  private func drawControlPoints(in rect: CGRect, context: inout GraphicsContext) {
    for point in toneCurve.points {
      let center = plotPoint((point.x, point.y), in: rect)
      let diameter = pointRadius * 2
      let circle = CGRect(
        x: center.x - pointRadius,
        y: center.y - pointRadius,
        width: diameter,
        height: diameter
      )
      context.fill(Path(ellipseIn: circle), with: .color(.white))
      context.stroke(Path(ellipseIn: circle), with: .color(.black.opacity(0.6)), lineWidth: 1)
    }
  }

  private func interactionGesture(in rect: CGRect) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        if draggingPointID == nil {
          draggingPointID = pointID(at: value.startLocation, in: rect)
        }

        guard let id = draggingPointID else { return }
        let normalized = normalizedPoint(value.location, in: rect)
        toneCurve.updatePoint(id: id, x: normalized.x, y: normalized.y)
      }
      .onEnded { value in
        if draggingPointID == nil {
          _ = pointID(at: value.location, in: rect)
        }
        draggingPointID = nil
      }
  }

  private func pointID(at location: CGPoint, in rect: CGRect) -> UUID? {
    if let existing = nearestPointID(to: location, in: rect, radius: pointHitRadius) {
      return existing
    }

    guard let nearest = nearestPointOnCurve(at: location, in: rect) else { return nil }
    return toneCurve.insertPoint(at: nearest, minimumSeparation: 0.015)
  }

  private func handleDoubleTap(at location: CGPoint, in rect: CGRect) {
    guard let id = nearestPointID(to: location, in: rect, radius: pointHitRadius) else { return }
    toneCurve.removePoint(id: id)
  }

  private func nearestPointOnCurve(at location: CGPoint, in rect: CGRect) -> (x: Double, y: Double)? {
    let samples = toneCurve.sampleCurve(count: 200)
    guard samples.count >= 2 else { return nil }

    var best: (x: Double, y: Double)?
    var bestDistance = curveHitRadius * curveHitRadius

    for index in 0..<(samples.count - 1) {
      let start = plotPoint(samples[index], in: rect)
      let end = plotPoint(samples[index + 1], in: rect)
      let closest = closestPoint(onSegmentFrom: start, to: end, point: location)
      let dx = closest.x - location.x
      let dy = closest.y - location.y
      let distanceSquared = dx * dx + dy * dy
      if distanceSquared <= bestDistance {
        bestDistance = distanceSquared
        best = normalizedPoint(closest, in: rect)
      }
    }

    return best
  }

  private func closestPoint(onSegmentFrom start: CGPoint, to end: CGPoint, point: CGPoint) -> CGPoint {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return start }

    let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
    return CGPoint(x: start.x + t * dx, y: start.y + t * dy)
  }

  private func nearestPointID(to location: CGPoint, in rect: CGRect, radius: CGFloat) -> UUID? {
    let hitRadiusSquared = radius * radius
    var best: (UUID, CGFloat)?

    for point in toneCurve.points {
      let center = plotPoint((point.x, point.y), in: rect)
      let dx = center.x - location.x
      let dy = center.y - location.y
      let distanceSquared = dx * dx + dy * dy
      if distanceSquared <= hitRadiusSquared {
        if best == nil || distanceSquared < best!.1 {
          best = (point.id, distanceSquared)
        }
      }
    }

    return best?.0
  }

  private func plotPoint(_ point: (x: Double, y: Double), in rect: CGRect) -> CGPoint {
    CGPoint(
      x: rect.minX + rect.width * point.x,
      y: rect.maxY - rect.height * point.y
    )
  }

  private func normalizedPoint(_ location: CGPoint, in rect: CGRect) -> (x: Double, y: Double) {
    let x = Double((location.x - rect.minX) / rect.width)
    let y = Double((rect.maxY - location.y) / rect.height)
    return (min(max(x, 0), 1), min(max(y, 0), 1))
  }
}
