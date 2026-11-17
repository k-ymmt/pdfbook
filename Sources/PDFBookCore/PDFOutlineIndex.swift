import Foundation

/// Which entry of the outline (the table of contents) a place belongs to: the last entry that starts at or before it.
public struct PDFOutlineIndex: Sendable {
    public struct Entry: Hashable, Sendable {
        public var title: String
        /// The page the entry points to, the first page being 1.
        public var page: Int
        /// Where on the page it points, from the top of the displayed page in points (0 when the outline does not say).
        public var top: Double

        public init(title: String, page: Int, top: Double = 0) {
            self.title = title
            self.page = page
            self.top = top
        }
    }

    /// The entries in document order (the outline flattened depth first), those without a destination left out.
    public let entries: [Entry]
    /// Indices into `entries`, ordered by where they point.
    private let ordered: [Int]

    public init(entries: [Entry]) {
        self.entries = entries
        ordered = entries.indices.sorted { lhs, rhs in
            let a = entries[lhs], b = entries[rhs]
            if a.page != b.page { return a.page < b.page }
            if a.top != b.top { return a.top < b.top }
            return lhs < rhs
        }
    }

    /// The entry a place belongs to, with its number in document order; nil before the first entry.
    /// - Parameter top: the distance from the top of the displayed page; nil for the page as a whole, which belongs
    ///   to the last entry that starts on it (a chapter's first page belongs to the chapter).
    public func entry(atPage page: Int, top: Double? = nil) -> (index: Int, entry: Entry)? {
        // the number of entries at or before the place
        var low = 0, high = ordered.count
        while low < high {
            let middle = (low + high) / 2
            let entry = entries[ordered[middle]]
            let isBefore = entry.page < page || (entry.page == page && (top.map { entry.top <= $0 } ?? true))
            if isBefore { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let index = ordered[low - 1]
        return (index, entries[index])
    }

    /// The entry a fragment starts in.
    public func entry(at fragment: PDFFragment) -> (index: Int, entry: Entry)? {
        entry(atPage: fragment.page, top: fragment.parts[0].rects.first?.top)
    }
}
