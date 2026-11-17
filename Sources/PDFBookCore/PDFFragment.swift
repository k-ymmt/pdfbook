import CoreGraphics
import Foundation

/// A place in a PDF written as a URL fragment: `page=12`, or `page=12&highlight=72,523,96,110&highlight=…`, or a
/// range that crosses pages, `page=12&highlight=…&page=13&highlight=…`.
///
/// The vocabulary is RFC 8118 §3 (`application/pdf`): `page=<n>` is the physical page, the first page being 1, and
/// `highlight=<left>,<right>,<top>,<bottom>` is a rectangle. The RFC defines one rectangle per fragment; this type
/// extends it by repetition, following the RFC's rule that parameters are processed from left to right:
///
/// - `highlight=` belongs to the `page=` before it, one rectangle per line of text, in reading order.
/// - A later `page=` switches the page, so one fragment can hold a range that runs over a page break.
/// - A fragment without any rectangle names a page (the last `page=` wins, as it would in a viewer).
///
/// Coordinates are in points (1/72 inch) from the top-left corner of the page **as it is displayed**: the crop box
/// with the page's own rotation applied, x to the right and y down (`PDFPageGeometry` converts). Parameters this
/// type does not know (`zoom=`, an application's own `color=`) are skipped when reading and never written.
public struct PDFFragment: Hashable, Sendable, CustomStringConvertible {
    /// One rectangle, in the RFC's order. Written as integers rounded outward (`init(enclosing:)`).
    public struct Rect: Hashable, Sendable {
        public var left: Double
        public var right: Double
        public var top: Double
        public var bottom: Double

        public init(left: Double, right: Double, top: Double, bottom: Double) {
            self.left = left
            self.right = right
            self.top = top
            self.bottom = bottom
        }

        /// The smallest rectangle with integer edges that contains `rect` (displayed-page coordinates): left and top
        /// are rounded down, right and bottom up.
        public init(enclosing rect: CGRect) {
            let rect = rect.standardized
            self.init(left: Double(rect.minX).rounded(.down), right: Double(rect.maxX).rounded(.up),
                      top: Double(rect.minY).rounded(.down), bottom: Double(rect.maxY).rounded(.up))
        }

        /// The rectangle in displayed-page coordinates (origin top-left, y down).
        public var cgRect: CGRect {
            CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }

        var isValid: Bool {
            left.isFinite && right.isFinite && top.isFinite && bottom.isFinite && left <= right && top <= bottom
        }

        var written: String {
            [left, right, top, bottom].map(PDFFragment.number).joined(separator: ",")
        }
    }

    /// The rectangles on one page.
    public struct Part: Hashable, Sendable {
        /// The physical page, the first page being 1.
        public var page: Int
        public var rects: [Rect]

        public init(page: Int, rects: [Rect] = []) {
            self.page = page
            self.rects = rects
        }
    }

    /// At least one part. Either a single part without rectangles (a page), or parts that all have rectangles
    /// (a range); neighbouring parts never share a page.
    public let parts: [Part]

    /// A whole page.
    public init(page: Int) {
        parts = [Part(page: max(1, page))]
    }

    /// A range. Parts without rectangles are dropped and neighbouring parts of one page are joined; nil when a page
    /// is below 1, a rectangle is not a rectangle, or nothing is left.
    public init?(parts: [Part]) {
        guard let normalized = Self.normalized(parts) else { return nil }
        self.parts = normalized
    }

    /// The first page (1-based).
    public var page: Int { parts[0].page }

    /// Whether the fragment names a page rather than a range on it.
    public var isPage: Bool { parts[0].rects.isEmpty }

    // MARK: Reading

    /// Reads the fragment (the part after `#`, still percent-encoded). nil when it does not name a place: no
    /// `page=`, a `highlight=` before the first `page=`, a page that is not a whole number from 1, or a rectangle
    /// that is not four numbers with left ≤ right and top ≤ bottom.
    public init?(_ fragment: String) {
        var parts: [Part] = []
        var lastPage: Int?
        // RFC 8118: parameters are separated by `&` or `#`
        for parameter in fragment.split(whereSeparator: { $0 == "&" || $0 == "#" }) {
            let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let value = String(pair[1]).removingPercentEncoding ?? String(pair[1])
            switch pair[0] {
            case "page":
                guard let page = Self.pageNumber(value) else { return nil }
                lastPage = page
                parts.append(Part(page: page))
            case "highlight":
                guard !parts.isEmpty, let rect = Self.rect(value) else { return nil }
                parts[parts.count - 1].rects.append(rect)
            default:
                continue
            }
        }
        guard let lastPage else { return nil }
        if parts.allSatisfy(\.rects.isEmpty) {
            self.init(page: lastPage)
        } else {
            self.init(parts: parts)
        }
    }

    private static func pageNumber(_ value: String) -> Int? {
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let page = Int(value), page >= 1 else { return nil }
        return page
    }

    private static func rect(_ value: String) -> Rect? {
        let numbers = value.split(separator: ",", omittingEmptySubsequences: false).map { component -> Double? in
            let text = component.trimmingCharacters(in: .whitespaces)
            // digits, one optional sign and one optional decimal point: no exponents, no "nan" / "inf"
            guard !text.isEmpty, text.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E || $0 == 0x2D || $0 == 0x2B }) else { return nil }
            return Double(text)
        }
        guard numbers.count == 4, let left = numbers[0], let right = numbers[1], let top = numbers[2], let bottom = numbers[3] else { return nil }
        let rect = Rect(left: left, right: right, top: top, bottom: bottom)
        return rect.isValid ? rect : nil
    }

    private static func normalized(_ parts: [Part]) -> [Part]? {
        var result: [Part] = []
        for part in parts {
            guard part.page >= 1, part.rects.allSatisfy(\.isValid) else { return nil }
            guard !part.rects.isEmpty else { continue }
            if let last = result.last, last.page == part.page {
                result[result.count - 1].rects += part.rects
            } else {
                result.append(part)
            }
        }
        return result.isEmpty ? nil : result
    }

    // MARK: Writing

    /// The fragment as written (without `#`): `page=` first, then that page's rectangles, then the next page.
    public var description: String {
        parts.map { part in
            (["page=\(part.page)"] + part.rects.map { "highlight=" + $0.written }).joined(separator: "&")
        }.joined(separator: "&")
    }

    /// Whole numbers without a decimal point, others with at most two decimals.
    static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: Order

    /// Whether this place starts before `other` in the book: by page, then from the top of the page (a whole page
    /// comes before every range on it), then from the left.
    public func precedes(_ other: PDFFragment) -> Bool {
        let lhs = sortKey, rhs = other.sortKey
        if lhs.page != rhs.page { return lhs.page < rhs.page }
        if lhs.top != rhs.top { return lhs.top < rhs.top }
        return lhs.left < rhs.left
    }

    private var sortKey: (page: Int, top: Double, left: Double) {
        guard let first = parts[0].rects.first else { return (page, -.infinity, -.infinity) }
        return (page, first.top, first.left)
    }
}

extension PDFFragment {
    /// A range on one page from the rectangles of its lines (displayed-page coordinates, in reading order). Each
    /// rectangle is rounded outward to integers. nil when there is no rectangle.
    public init?(page: Int, lineRects: [CGRect]) {
        self.init(parts: [Part(page: page, rects: lineRects.map(Rect.init(enclosing:)))])
    }
}
