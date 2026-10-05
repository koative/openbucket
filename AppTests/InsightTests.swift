import CoreGraphics
import Testing

@testable import OpenBucket

struct TreemapTests {
  static let cases: [[Double]] = [
    [6, 6, 4, 3, 2, 2, 1],
    [1, 1000, 3, 7, 500, 2, 2, 90],
    (1...200).map { Double($0 * $0) },
    [5, 5],
  ]
  let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)

  @Test(arguments: cases)
  func preservesAreaAndStaysInBounds(_ values: [Double]) {
    let rects = Treemap.layout(values, in: bounds)
    #expect(rects.count == values.count)
    let total = values.reduce(0, +)
    let area = rects.reduce(0) { $0 + $1.width * $1.height }
    #expect(abs(area - bounds.width * bounds.height) / (bounds.width * bounds.height) < 0.005)
    for (value, rect) in zip(values, rects) {
      #expect(bounds.insetBy(dx: -1e-6, dy: -1e-6).contains(rect))
      // Order preserved: each rect's share of the area matches its own value.
      let share = rect.width * rect.height / (bounds.width * bounds.height)
      #expect(abs(share - value / total) < 1e-6)
    }
  }

  @Test func nonPositiveValuesGetEmptyRects() {
    let rects = Treemap.layout([0, 4, -3, .nan, 4], in: bounds)
    #expect(rects[0].isEmpty && rects[2].isEmpty && rects[3].isEmpty)
    #expect(abs(rects[1].width * rects[1].height - 120_000) < 1e-6)
    #expect(abs(rects[4].width * rects[4].height - 120_000) < 1e-6)
  }

  @Test func singleValueFillsRect() {
    #expect(Treemap.layout([42], in: bounds) == [bounds])
  }

  @Test func emptyInputOrRect() {
    #expect(Treemap.layout([], in: bounds).isEmpty)
    #expect(Treemap.layout([1, 2], in: .zero) == [.zero, .zero])
  }
}
