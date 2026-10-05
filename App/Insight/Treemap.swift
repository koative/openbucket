import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing, van Wijk 2000).
enum Treemap {
  /// One rect per value, in input order; areas are proportional to the values. Zero, negative and
  /// non-finite values get `.zero`.
  static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
    var result = Array(repeating: CGRect.zero, count: values.count)
    let order = values.indices.filter { values[$0] > 0 && values[$0].isFinite }
      .sorted { values[$0] > values[$1] }
    let total = order.reduce(0) { $0 + values[$1] }
    guard total > 0, rect.width > 0, rect.height > 0 else { return result }
    let scale = Double(rect.width * rect.height) / total
    let areas = values.map { $0 * scale }
    var free = rect
    var row: [Int] = []

    /// Worst aspect ratio of `row` laid along a side of length `side`.
    func worst(_ row: [Int], _ side: Double) -> Double {
      let sum = row.reduce(0) { $0 + areas[$1] }
      let largest = row.map { areas[$0] }.max() ?? 0
      let smallest = row.map { areas[$0] }.min() ?? 0
      return max(side * side * largest / (sum * sum), sum * sum / (side * side * smallest))
    }

    /// Places `row` along the shorter side of `free` and removes the strip it used.
    func place(_ row: [Int]) {
      let sum = row.reduce(0) { $0 + areas[$1] }
      if free.width >= free.height {
        let width = min(sum / free.height, free.width)
        var y = free.minY
        for index in row {
          let height = min(areas[index] / width, free.maxY - y)
          result[index] = CGRect(x: free.minX, y: y, width: width, height: height)
          y += height
        }
        free = CGRect(x: free.minX + width, y: free.minY, width: free.width - width, height: free.height)
      } else {
        let height = min(sum / free.width, free.height)
        var x = free.minX
        for index in row {
          let width = min(areas[index] / height, free.maxX - x)
          result[index] = CGRect(x: x, y: free.minY, width: width, height: height)
          x += width
        }
        free = CGRect(x: free.minX, y: free.minY + height, width: free.width, height: free.height - height)
      }
    }

    for index in order {
      let side = min(free.width, free.height)
      if row.isEmpty || worst(row + [index], side) <= worst(row, side) {
        row.append(index)
      } else {
        place(row)
        row = [index]
      }
    }
    place(row)
    return result
  }
}
