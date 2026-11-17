import CoreGraphics

/// Joins the rectangles a selection is made of into one rectangle per line.
///
/// PDFKit reports horizontal text one line at a time, but vertical text (Japanese books) one character at a time:
/// forty selected characters would be forty `highlight=` parameters. A rectangle is added to the one before it when
/// - it is about as wide as it is tall (a character, not a line) and sits directly below it in the same column, or
/// - it continues it on the same line (it overlaps it or starts where it ends).
/// Everything else starts a new rectangle. The order is kept.
public enum PDFLineRects {
    /// - Parameter rects: rectangles in displayed-page coordinates (y down), in reading order.
    public static func merged(_ rects: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for rect in rects.map(\.standardized) where rect.width > 0 || rect.height > 0 {
            if let last = result.last, continuesColumn(rect, after: last) || continuesLine(rect, after: last) {
                result[result.count - 1] = last.union(rect)
            } else {
                result.append(rect)
            }
        }
        return result
    }

    /// A character below `previous` in the same column.
    private static func continuesColumn(_ rect: CGRect, after previous: CGRect) -> Bool {
        // a character: not much wider than tall. A line of horizontal text is many times wider
        guard rect.width <= rect.height * 1.6, previous.width <= rect.width * 1.6, rect.width <= previous.width * 1.6 else { return false }
        guard abs(rect.midX - previous.midX) <= rect.width * 0.5 else { return false }
        let gap = rect.minY - previous.maxY
        return gap >= -rect.height * 0.6 && gap <= rect.height * 0.8
    }

    /// The same line, further along (or overlapping).
    private static func continuesLine(_ rect: CGRect, after previous: CGRect) -> Bool {
        let overlap = min(rect.maxY, previous.maxY) - max(rect.minY, previous.minY)
        guard overlap >= min(rect.height, previous.height) * 0.6 else { return false }
        let gap = rect.minX - previous.maxX
        return rect.minX >= previous.minX - 1 && gap <= min(rect.height, previous.height) * 0.3
    }
}
