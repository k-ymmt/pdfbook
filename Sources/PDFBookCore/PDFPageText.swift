import CoreGraphics
import Foundation

/// The text of one page in reading order, built from the lines PDFKit reports.
///
/// PDFKit's `PDFPage.string` breaks the text where the page breaks it, so a phrase that wraps is not found by a
/// plain search, and it reports vertical text (Japanese books) one character per line, the columns from left to
/// right, the reverse of the order they are read in. This type joins the lines into one string to search and to
/// take excerpts from, and maps a range of that string back to ranges of `PDFPage.string`:
///
/// - Single characters stacked in a column become one line; a run of columns is read from right to left.
/// - Lines are joined by a space, except between two CJK characters (which wrap without one).
public struct PDFPageText: Sendable {
    /// One line of `PDFPage.string`.
    public struct Line: Sendable {
        public var text: String
        /// The line's range in the page's string (UTF-16), without its line break.
        public var range: NSRange
        /// The line's bounds in displayed-page coordinates (y down). Only single characters need it (it is how a
        /// column of vertical text is recognized): pass nil for longer lines to save the measurement.
        public var bounds: CGRect?

        public init(text: String, range: NSRange, bounds: CGRect? = nil) {
            self.text = text
            self.range = range
            self.bounds = bounds
        }
    }

    /// A match of a search.
    public struct Match: Sendable, Hashable {
        /// The range in `PDFPageText.text`.
        public var range: Range<String.Index>
        /// The same characters as ranges of the page's string (UTF-16), in reading order: more than one where the
        /// match runs over a line break or down a column.
        public var sourceRanges: [NSRange]
    }

    /// The page's text in reading order.
    public let text: String

    /// A run of `text` that is a run of the page's string.
    private struct Piece: Sendable {
        var start: Int
        var source: NSRange
    }

    private let pieces: [Piece]

    public init(lines: [Line]) {
        var text = ""
        var length = 0
        var pieces: [Piece] = []
        for group in Self.readingOrder(Self.grouped(lines)) {
            guard let first = group.first?.text.first else { continue }
            if let last = text.last, Self.needsSpace(between: last, and: first) {
                text += " "
                length += 1
            }
            for line in group {
                let count = line.text.utf16.count
                pieces.append(Piece(start: length, source: NSRange(location: line.range.location, length: min(count, line.range.length))))
                text += line.text
                length += count
            }
        }
        self.text = text
        self.pieces = pieces
    }

    /// Whether the page has no text (a scan without a text layer).
    public var isEmpty: Bool { text.isEmpty }

    /// About how much memory the value holds, for a cache that keeps many pages.
    package var estimatedByteCount: Int {
        text.utf8.count + pieces.count * MemoryLayout<Piece>.stride
    }

    // MARK: Lines

    /// Lines that are read as one: a line of horizontal text alone, or the characters of one column.
    private static func grouped(_ lines: [Line]) -> [[Line]] {
        var groups: [[Line]] = []
        var previousCell: CGRect?
        for line in lines {
            var line = line
            // PDFKit keeps the spaces a line ends with
            let trimmed = line.text.trimmingTrailingWhitespace()
            line.range.length -= line.text.utf16.count - trimmed.utf16.count
            line.text = trimmed
            guard !line.text.isEmpty else { continue }
            let cell = line.text.isSingleCharacter ? line.bounds?.standardized : nil
            if let cell, let previous = previousCell, isBelow(cell, previous) {
                groups[groups.count - 1].append(line)
            } else {
                groups.append([line])
            }
            previousCell = cell
        }
        return groups
    }

    /// Whether `cell` is the next character down the column of `previous`.
    private static func isBelow(_ cell: CGRect, _ previous: CGRect) -> Bool {
        let width = max(cell.width, previous.width), height = max(cell.height, previous.height)
        guard abs(cell.midX - previous.midX) <= width * 0.5 else { return false }
        let gap = cell.minY - previous.maxY
        return gap >= -height * 0.6 && gap <= height * 1.2
    }

    /// Reverses each run of columns that goes from left to right: the columns of vertical text are read from the
    /// right. A column further left than the one before it starts a new run (the next tier of the page).
    ///
    /// A single character counts as a column of its own (the last column of a paragraph may hold one character) when it
    /// stands in a run with a real column and beside it: a lone character elsewhere (a page number under the columns)
    /// keeps its place.
    private static func readingOrder(_ groups: [[Line]]) -> [[Line]] {
        var result: [[Line]] = []
        var run: [[Line]] = []
        func columnX(_ group: [Line]) -> CGFloat? {
            guard group.count > 1 || group[0].text.isSingleCharacter else { return nil }
            return group[0].bounds?.standardized.midX
        }
        func flush() {
            defer { run = [] }
            let columns = run.filter { $0.count > 1 }
            guard !columns.isEmpty else {
                result += run
                return
            }
            // the tier: from the top of the highest column to the bottom of the lowest
            let top = columns.compactMap { $0.first?.bounds?.standardized.minY }.min() ?? 0
            let bottom = columns.compactMap { $0.last?.bounds?.standardized.maxY }.max() ?? 0
            var part: [[Line]] = []
            for group in run {
                if group.count == 1, let midY = group[0].bounds?.standardized.midY, midY < top || midY > bottom {
                    result += part.reversed()
                    part = []
                    result.append(group)
                } else {
                    part.append(group)
                }
            }
            result += part.reversed()
        }
        for group in groups {
            guard let x = columnX(group) else {
                flush()
                result.append(group)
                continue
            }
            if let last = run.last, let lastX = columnX(last), x <= lastX { flush() }
            run.append(group)
        }
        flush()
        return result
    }

    /// Characters of scripts written without spaces between words: a line break between two of them is not a space.
    static func wrapsWithoutSpace(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80 ... 0x30FF, // CJK radicals, punctuation, Hiragana, Katakana
             0x3100 ... 0x312F, 0x31A0 ... 0x31FF, // Bopomofo, Katakana extensions
             0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, // Han
             0xF900 ... 0xFAFF, // compatibility ideographs
             0xFE30 ... 0xFE4F, // vertical forms
             0xFF00 ... 0xFF60, 0xFFE0 ... 0xFFEF, // full-width forms
             0x20000 ... 0x3FFFF: // Han extensions
            return true
        default:
            return false
        }
    }

    /// Whether two lines are joined with a space: always, except between two CJK characters.
    static func needsSpace(between last: Character, and first: Character) -> Bool {
        !(wrapsWithoutSpace(last) && wrapsWithoutSpace(first))
    }

    /// Joins the lines of a selection the way a page's lines are joined (a space, except between CJK characters).
    public static func joined<S: StringProtocol>(_ lines: [S]) -> String {
        var text = ""
        for line in lines {
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = line.first else { continue }
            if let last = text.last, needsSpace(between: last, and: first) { text += " " }
            text += line
        }
        return text
    }

    // MARK: Search

    /// Every place `query` is found, in reading order. Case, diacritics and character width are ignored; runs of
    /// whitespace in the query match one space.
    public func matches(of query: String) -> [Match] {
        let query = Self.normalized(query)
        guard !query.isEmpty, !text.isEmpty else { return [] }
        let string = text as NSString
        var matches: [Match] = []
        var search = NSRange(location: 0, length: string.length)
        while search.length > 0 {
            let found = string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: search)
            guard found.location != NSNotFound, found.length > 0 else { break }
            // a match that cuts a character in two (half of a surrogate pair) is skipped, not the rest of the page
            if let range = Range(found, in: text) {
                matches.append(Match(range: range, sourceRanges: sourceRanges(forUTF16: found)))
            }
            search = NSRange(location: found.upperBound, length: string.length - found.upperBound)
        }
        return matches
    }

    /// The query as it is searched for: runs of whitespace as one space, none at either end. Empty: nothing to find.
    package static func normalized(_ query: String) -> String {
        query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The ranges of the page's string for a range of `text`.
    public func sourceRanges(for range: Range<String.Index>) -> [NSRange] {
        sourceRanges(forUTF16: NSRange(range, in: text))
    }

    private func sourceRanges(forUTF16 range: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        // the pieces are in the order of `text`: start at the last one that begins at or before the range
        var low = 0, high = pieces.count
        while low < high {
            let middle = (low + high) / 2
            if pieces[middle].start <= range.location { low = middle + 1 } else { high = middle }
        }
        for piece in pieces[max(0, low - 1)...] {
            guard piece.start < range.upperBound else { break }
            let start = max(range.location, piece.start), end = min(range.upperBound, piece.start + piece.source.length)
            guard start < end else { continue }
            let source = NSRange(location: piece.source.location + start - piece.start, length: end - start)
            if let last = result.last, last.upperBound == source.location {
                result[result.count - 1].length += source.length
            } else {
                result.append(source)
            }
        }
        return result
    }

    /// The text around a match and the match's range in it: up to `before` characters ahead of it and `after`
    /// behind, cut at the start or end of the page.
    public func snippet(around range: Range<String.Index>, before: Int = 24, after: Int = 60) -> (text: String, match: Range<String.Index>) {
        let start = text.index(range.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
        let snippet = String(text[start ..< end])
        let lower = snippet.index(snippet.startIndex, offsetBy: text.distance(from: start, to: range.lowerBound))
        let upper = snippet.index(lower, offsetBy: text.distance(from: range.lowerBound, to: range.upperBound))
        return (snippet, lower ..< upper)
    }

    /// The first characters of the page (for the text of a link to the page). Empty for a page without text.
    public func excerpt(maxLength: Int = 40) -> String {
        String(text.prefix(max(0, maxLength)))
    }
}

extension StringProtocol {
    /// Whether the string is exactly one character, without counting the characters of a long line.
    package var isSingleCharacter: Bool {
        !isEmpty && index(after: startIndex) == endIndex
    }
}

extension String {
    func trimmingTrailingWhitespace() -> String {
        var view = self[...]
        while let last = view.last, last.isWhitespace { view = view.dropLast() }
        return String(view)
    }
}
