import CoreGraphics
import Foundation
import PDFBookCore
import PDFKit

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// An annotation that is part of the PDF file: a text mark someone made in another application, or a note. PDFKit
/// draws these by itself; this is what a reader lists beside its own marks. Read-only: the library never changes
/// the file.
nonisolated public struct PDFDocumentAnnotation: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case highlight
        case underline
        case strikethrough
        /// A note placed on the page (PDF's `Text` annotation): no marked text, only `contents`.
        case note
    }

    /// Stable for one file: the page and the annotation's place among that page's annotations.
    public var id: String
    public var kind: Kind
    /// Where it is: the page with one rectangle per marked line (a note: the rectangle of its icon).
    public var fragment: PDFFragment
    /// The text under a mark, its lines joined. Empty for a note and for a mark over a page without text.
    public var text: String
    /// What the annotation says (the comment of a mark, the text of a note); nil when it says nothing.
    public var contents: String?
    /// The annotation's colour, when it has one.
    public var color: PDFOverlay.Color?

    public init(id: String, kind: Kind, fragment: PDFFragment, text: String, contents: String?, color: PDFOverlay.Color?) {
        self.id = id
        self.kind = kind
        self.fragment = fragment
        self.text = text
        self.contents = contents
        self.color = color
    }
}

extension PDFBookDocument {
    /// The file's own text marks and notes, in page order. Read away from the main actor, once: later calls return
    /// the same list. Empty while the document is locked.
    public func annotations() async -> [PDFDocumentAnnotation] {
        if let loadedAnnotations { return loadedAnnotations }
        guard !isLocked else { return [] }
        let found = await textStore.annotations()
        loadedAnnotations = found
        return found
    }

    /// The text at a place: what lies under each rectangle, joined like the lines of a selection. Empty for a place
    /// without text (a whole page, a scan); nil when the document does not have one of its pages.
    public func text(in fragment: PDFFragment) async -> String? {
        await textStore.text(in: fragment)
    }

    /// Finds a quote in the document and returns where it is: the match on the page of `fragment` nearest to it,
    /// else the first match on the nearest page that has one. Case, diacritics and character width are ignored (as
    /// in `search(_:)`). nil when the quote is nowhere on a single page.
    ///
    /// For a mark whose place no longer holds its text (the file was replaced by another edition).
    public func locate(_ quote: String, near fragment: PDFFragment) async -> PDFFragment? {
        await textStore.locate(quote, near: fragment)
    }
}

extension PDFBookDocument {
    /// A selection as a place and its text: one rectangle per line (the pieces of one line or of one column of
    /// vertical text joined), in reading order, in the coordinates of the displayed page.
    nonisolated static func selectedText(of selection: PDFSelection, in pdf: PDFDocument) -> PDFSelectedText? {
        var parts: [(page: Int, rects: [CGRect])] = []
        var lines: [String] = []
        for line in selection.selectionsByLine() {
            guard let page = line.pages.first else { continue }
            let index = pdf.index(for: page)
            guard index != NSNotFound else { continue }
            let bounds = line.bounds(for: page)
            guard !bounds.isEmpty else { continue }
            let rect = geometry(of: page).displayed(bounds)
            if parts.last?.page == index + 1 {
                parts[parts.count - 1].rects.append(rect)
            } else {
                parts.append((index + 1, [rect]))
            }
            lines.append(line.string ?? "")
        }
        let fragment = PDFFragment(parts: parts.map { part in
            PDFFragment.Part(page: part.page, rects: PDFLineRects.merged(part.rects).map(PDFFragment.Rect.init(enclosing:)))
        })
        guard let fragment else { return nil }
        return PDFSelectedText(fragment: fragment, text: PDFPageText.joined(lines))
    }
}

extension PDFTextStore {
    /// More than this many annotations are not listed (a file with a mark on every line of every page).
    private static let annotationLimit = 5000
    /// How many matches on one page are measured to find the one nearest to the old place.
    private static let matchLimit = 32

    func annotations() -> [PDFDocumentAnnotation] {
        if let cachedAnnotations { return cachedAnnotations }
        guard let document, !document.isLocked else { return [] }
        var result: [PDFDocumentAnnotation] = []
        pages: for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let geometry = PDFBookDocument.geometry(of: page)
            for (order, annotation) in page.annotations.enumerated() {
                guard Self.isShown(annotation), let kind = Self.kind(ofType: annotation.type) else { continue }
                let contents = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines)
                var rects: [CGRect] = []
                var lines: [String] = []
                if kind == .note {
                    // a note without words has nothing to list
                    guard contents?.isEmpty == false else { continue }
                    rects = [geometry.displayed(annotation.bounds)]
                } else {
                    for quad in Self.quads(of: annotation) {
                        let displayed = geometry.displayed(quad)
                        rects.append(displayed)
                        lines.append(Self.text(of: page.selection(for: geometry.page(Self.core(of: displayed)))))
                    }
                    rects = PDFLineRects.merged(rects)
                }
                guard let fragment = PDFFragment(page: index + 1, lineRects: rects) else { continue }
                result.append(PDFDocumentAnnotation(id: "\(index + 1)-\(order)", kind: kind, fragment: fragment, text: PDFPageText.joined(lines),
                                                    contents: contents?.isEmpty == false ? contents : nil, color: Self.color(of: annotation)))
                if result.count >= Self.annotationLimit { break pages }
            }
        }
        cachedAnnotations = result
        return result
    }

    /// Whether the file wants the annotation on screen: not with the Hidden (bit 2) or NoView (bit 6) flag.
    /// (`shouldDisplay` stays true for those.)
    private static func isShown(_ annotation: PDFAnnotation) -> Bool {
        guard annotation.shouldDisplay else { return false }
        let flags = (annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
        return flags & (1 << 1 | 1 << 5) == 0
    }

    private static func kind(ofType type: String?) -> PDFDocumentAnnotation.Kind? {
        switch type {
        case "Highlight": .highlight
        case "Underline", "Squiggly": .underline
        case "StrikeOut": .strikethrough
        case "Text": .note
        default: nil
        }
    }

    /// The marked areas of a text mark in page coordinates: one per quadrilateral, or the annotation's bounds when
    /// it has none.
    private static func quads(of annotation: PDFAnnotation) -> [CGRect] {
        let origin = annotation.bounds.origin
        let points = (annotation.quadrilateralPoints ?? []).map { value -> CGPoint in
            #if canImport(UIKit)
            let point = value.cgPointValue
            #else
            let point = value.pointValue
            #endif
            return CGPoint(x: origin.x + point.x, y: origin.y + point.y)
        }
        guard points.count >= 4 else { return annotation.bounds.isEmpty ? [] : [annotation.bounds] }
        return stride(from: 0, to: points.count - 3, by: 4).map { start in
            let quad = points[start ..< start + 4]
            let xs = quad.map(\.x), ys = quad.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }

    private static func color(of annotation: PDFAnnotation) -> PDFOverlay.Color? {
        #if canImport(UIKit)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard annotation.color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return PDFOverlay.Color(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
        #else
        guard let color = annotation.color.usingColorSpace(.sRGB) else { return nil }
        return PDFOverlay.Color(red: Double(color.redComponent), green: Double(color.greenComponent), blue: Double(color.blueComponent),
                                alpha: Double(color.alphaComponent))
        #endif
    }

    /// The middle of a line's rectangle (displayed-page coordinates): what is asked for the text "in" it. The
    /// rectangles of neighbouring lines overlap (each reaches from the ascenders to the descenders) and a written
    /// rectangle is rounded outward, so the whole rectangle would also catch the lines above and below and the
    /// characters beside it. The short side loses 30 % at each end (a line: its height; a column of vertical text:
    /// its width), the long side 1.5 pt.
    static func core(of rect: CGRect) -> CGRect {
        let rect = rect.standardized
        let lineIsHorizontal = rect.width >= rect.height
        let dx = lineIsHorizontal ? min(1.5, rect.width * 0.25) : rect.width * 0.3
        let dy = lineIsHorizontal ? rect.height * 0.3 : min(1.5, rect.height * 0.25)
        return rect.insetBy(dx: dx, dy: dy)
    }

    /// The text of the selection of one rectangle. A column of vertical text is one rectangle here and one line per
    /// character for PDFKit: its pieces are joined the way the lines of a selection are (`selectedText`), so that
    /// the text of a place reads the same as the selection it was made from.
    private static func text(of selection: PDFSelection?) -> String {
        PDFPageText.joined((selection?.string ?? "").split(whereSeparator: \.isNewline))
    }

    func text(in fragment: PDFFragment) -> String? {
        guard let document, !document.isLocked else { return nil }
        var lines: [String] = []
        for part in fragment.parts {
            guard part.page <= document.pageCount, let page = document.page(at: part.page - 1) else { return nil }
            let geometry = PDFBookDocument.geometry(of: page)
            for rect in part.rects {
                lines.append(Self.text(of: page.selection(for: geometry.page(Self.core(of: rect.cgRect)))))
            }
        }
        return PDFPageText.joined(lines)
    }

    func locate(_ quote: String, near fragment: PDFFragment) -> PDFFragment? {
        // a quote of whitespace only is found nowhere: no page is read for it
        guard !PDFPageText.normalized(quote).isEmpty, let document, !document.isLocked, document.pageCount > 0 else { return nil }
        let count = document.pageCount
        let origin = min(max(1, fragment.page), count)
        let old = fragment.parts[0].rects.first
        for distance in 0 ..< count {
            for number in distance == 0 ? [origin] : [origin + distance, origin - distance] where number >= 1 && number <= count {
                guard !Task.isCancelled else { return nil }
                var matches = text(ofPage: number - 1).matches(of: quote)
                guard !matches.isEmpty, let page = document.page(at: number - 1) else { continue }
                let onOldPage = number == fragment.page && old != nil
                if onOldPage, matches.count > Self.matchLimit, let old, let anchor = Self.characterIndex(at: old, on: page) {
                    // too many to measure: the ones nearest to the old place in the page's text, in reading order
                    func start(_ match: PDFPageText.Match) -> Int { match.sourceRanges.first?.location ?? 0 }
                    matches = matches.sorted { abs(start($0) - anchor) < abs(start($1) - anchor) }.prefix(Self.matchLimit)
                        .sorted { start($0) < start($1) }
                }
                let found = matches.prefix(Self.matchLimit).compactMap { match -> PDFFragment? in
                    let selection = PDFSelection(document: document)
                    for range in match.sourceRanges {
                        if let part = page.selection(for: range) { selection.add(part) }
                    }
                    return PDFBookDocument.selectedText(of: selection, in: document)?.fragment
                }
                // on the page the mark was on, the match nearest to where it was; elsewhere the first
                if onOldPage, let old, let nearest = found.min(by: { Self.distance(of: $0, from: old) < Self.distance(of: $1, from: old) }) {
                    return nearest
                }
                if let first = found.first { return first }
            }
        }
        return nil
    }

    /// The index in the page's text of the character at the start of a rectangle (displayed-page coordinates); nil
    /// when there is no character there.
    private static func characterIndex(at rect: PDFFragment.Rect, on page: PDFPage) -> Int? {
        let core = core(of: rect.cgRect)
        let start = core.width >= core.height ? CGPoint(x: core.minX, y: core.midY) : CGPoint(x: core.midX, y: core.minY)
        let index = page.characterIndex(at: PDFBookDocument.geometry(of: page).page(start))
        return index >= 0 && index != NSNotFound ? index : nil
    }

    /// How far a match is from where the mark was: between the top-left corners of their first rectangles (squared),
    /// so that of two matches on one line the one at the old place wins.
    private static func distance(of fragment: PDFFragment, from old: PDFFragment.Rect) -> Double {
        guard let rect = fragment.parts[0].rects.first else { return .greatestFiniteMagnitude }
        let dx = rect.left - old.left, dy = rect.top - old.top
        return dx * dx + dy * dy
    }
}
