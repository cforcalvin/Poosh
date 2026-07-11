import Foundation

struct CurvePoint: Identifiable, Equatable {
  let id: UUID
  var x: Double
  var y: Double

  init(id: UUID = UUID(), x: Double, y: Double) {
    self.id = id
    self.x = x
    self.y = y
  }
}

final class ToneCurve: ObservableObject {
  static let minPointGap: Double = 0.001

  @Published var points: [CurvePoint]

  init(points: [CurvePoint] = [
    CurvePoint(x: 0, y: 0),
    CurvePoint(x: 1, y: 1),
  ]) {
    self.points = Self.enforceOrdering(points)
  }

  func reset() {
    points = [
      CurvePoint(x: 0, y: 0),
      CurvePoint(x: 1, y: 1),
    ]
  }

  var sortedPoints: [CurvePoint] {
    points.sorted { $0.x < $1.x }
  }

  func evaluate(_ input: Double) -> Double {
    let sorted = sortedPoints
    guard sorted.count >= 2 else { return min(max(input, 0), 1) }

    let clampedInput = min(max(input, 0), 1)
    if clampedInput <= sorted[0].x { return sorted[0].y }
    if clampedInput >= sorted[sorted.count - 1].x { return sorted[sorted.count - 1].y }

    guard let segmentIndex = sorted.firstIndex(where: { clampedInput <= $0.x }),
          segmentIndex > 0 else {
      return clampedInput
    }

    let p0 = sorted[segmentIndex - 1]
    let p1 = sorted[segmentIndex]
    return Self.hermiteEvaluate(
      x: clampedInput,
      x0: p0.x, y0: p0.y,
      x1: p1.x, y1: p1.y,
      m0: Self.tangent(at: segmentIndex - 1, points: sorted),
      m1: Self.tangent(at: segmentIndex, points: sorted)
    )
  }

  func generateLUT(size: Int = 256) -> [Float] {
    guard size > 1 else { return [0, 1] }
    return (0..<size).map { index in
      let input = Double(index) / Double(size - 1)
      return Float(evaluate(input))
    }
  }

  func sampleCurve(count: Int = 128) -> [(x: Double, y: Double)] {
    let sorted = sortedPoints
    guard sorted.count >= 2 else { return [(0, 0), (1, 1)] }

    let samplesPerSegment = max(4, count / (sorted.count - 1))
    var samples: [(x: Double, y: Double)] = []

    for index in 0..<(sorted.count - 1) {
      let p0 = sorted[index]
      let p1 = sorted[index + 1]
      let m0 = Self.tangent(at: index, points: sorted)
      let m1 = Self.tangent(at: index + 1, points: sorted)

      let segmentSamples = index == sorted.count - 2 ? samplesPerSegment : samplesPerSegment - 1
      for step in 0...segmentSamples {
        let t = Double(step) / Double(samplesPerSegment)
        let x = p0.x + t * (p1.x - p0.x)
        let y = Self.hermiteEvaluate(
          x: x, x0: p0.x, y0: p0.y, x1: p1.x, y1: p1.y, m0: m0, m1: m1
        )
        samples.append((x, y))
      }
    }

    return samples
  }

  func nearestPointOnCurve(to location: (x: Double, y: Double), sampleCount: Int = 200) -> (x: Double, y: Double)? {
    let samples = sampleCurve(count: sampleCount)
    guard !samples.isEmpty else { return nil }

    var best = samples[0]
    var bestDistance = Double.greatestFiniteMagnitude
    for sample in samples {
      let dx = sample.x - location.x
      let dy = sample.y - location.y
      let distance = dx * dx + dy * dy
      if distance < bestDistance {
        bestDistance = distance
        best = sample
      }
    }
    return best
  }

  @discardableResult
  func insertPoint(at location: (x: Double, y: Double), minimumSeparation: Double = 0.02) -> UUID? {
    for point in points {
      let dx = point.x - location.x
      let dy = point.y - location.y
      if (dx * dx + dy * dy) < minimumSeparation * minimumSeparation { return nil }
    }

    let newPoint = CurvePoint(x: location.x, y: location.y)
    var updated = points
    updated.append(newPoint)
    points = Self.enforceOrdering(updated)
    return newPoint.id
  }

  func updatePoint(id: UUID, x: Double, y: Double) {
    guard let index = points.firstIndex(where: { $0.id == id }) else { return }

    let sorted = sortedPoints
    guard let sortedIndex = sorted.firstIndex(where: { $0.id == id }) else { return }

    let minX: Double
    let maxX: Double
    if sortedIndex == 0 {
      minX = 0
      maxX = sorted.count > 1 ? sorted[1].x - Self.minPointGap : 1
    } else if sortedIndex == sorted.count - 1 {
      minX = sorted[sorted.count - 2].x + Self.minPointGap
      maxX = 1
    } else {
      minX = sorted[sortedIndex - 1].x + Self.minPointGap
      maxX = sorted[sortedIndex + 1].x - Self.minPointGap
    }

    points[index].x = min(max(x, minX), maxX)
    points[index].y = min(max(y, 0), 1)
    points = Self.enforceOrdering(points)
  }

  func removePoint(id: UUID) {
    guard points.count > 2 else { return }
    let sorted = sortedPoints
    guard let sortedIndex = sorted.firstIndex(where: { $0.id == id }),
          sortedIndex > 0,
          sortedIndex < sorted.count - 1 else { return }
    points.removeAll { $0.id == id }
  }

  // MARK: - Spline math

  private static func hermiteEvaluate(
    x: Double,
    x0: Double, y0: Double,
    x1: Double, y1: Double,
    m0: Double, m1: Double
  ) -> Double {
    let span = x1 - x0
    guard span > 0 else { return y0 }
    let t = (x - x0) / span
    let t2 = t * t
    let t3 = t2 * t
    let h00 = 2 * t3 - 3 * t2 + 1
    let h10 = t3 - 2 * t2 + t
    let h01 = -2 * t3 + 3 * t2
    let h11 = t3 - t2
    return h00 * y0 + h10 * span * m0 + h01 * y1 + h11 * span * m1
  }

  private static func tangent(at index: Int, points: [CurvePoint]) -> Double {
    guard points.count >= 2 else { return 1 }
    let count = points.count

    if index == 0 {
      let delta = (points[1].y - points[0].y) / max(points[1].x - points[0].x, minPointGap)
      return delta
    }
    if index == count - 1 {
      let delta = (points[count - 1].y - points[count - 2].y) /
        max(points[count - 1].x - points[count - 2].x, minPointGap)
      return delta
    }

    let deltaLeft = (points[index].y - points[index - 1].y) /
      max(points[index].x - points[index - 1].x, minPointGap)
    let deltaRight = (points[index + 1].y - points[index].y) /
      max(points[index + 1].x - points[index].x, minPointGap)

    if deltaLeft * deltaRight <= 0 { return 0 }

    let weight = (points[index].x - points[index - 1].x + points[index + 1].x - points[index].x)
    let weighted = (
      (points[index].x - points[index - 1].x) * deltaRight +
        (points[index + 1].x - points[index].x) * deltaLeft
    ) / max(weight, minPointGap)

    return fritschCarlsonClamp(weighted, deltaLeft: deltaLeft, deltaRight: deltaRight)
  }

  private static func fritschCarlsonClamp(_ tangent: Double, deltaLeft: Double, deltaRight: Double) -> Double {
    let magnitude = min(abs(tangent), 3 * min(abs(deltaLeft), abs(deltaRight)))
    if tangent < 0 { return -magnitude }
    return magnitude
  }

  private static func enforceOrdering(_ points: [CurvePoint]) -> [CurvePoint] {
    guard !points.isEmpty else {
      return [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    }

    var sorted = points.sorted { $0.x < $1.x }
    for index in sorted.indices {
      sorted[index].x = min(max(sorted[index].x, 0), 1)
      sorted[index].y = min(max(sorted[index].y, 0), 1)
    }

    for index in 1..<sorted.count {
      if sorted[index].x <= sorted[index - 1].x {
        sorted[index].x = min(1, sorted[index - 1].x + minPointGap)
      }
    }

    return sorted
  }
}
