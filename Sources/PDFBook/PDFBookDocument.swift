import CoreGraphics
import Foundation
import PDFBookCore
import PDFKit

/// One entry of a PDF's outline (its table of contents).
nonisolated public struct PDFOutlineItem: Identifiable, Hashable, Sendable {
    /// The entry's number in document order (the outline read depth first), counting every entry.
    public let id: Int
    public var label: String
    /// The page the entry points to, the first page being 1; nil for an entry without a destination in this file.
    public var page: Int?
    /// Where on the page it points: the distance from the top of the displayed page in points (0 when the outline
    /// does not say).
    public var top: Double
    public var children: [PDFOutlineItem]

    public init(id: Int, label: String, page: Int?, top: Double = 0, children: [PDFOutlineItem] = []) {
        self.id = id
        self.label = label
        self.page = page
        self.top = top
        self.children = children
    }
}

/// A PDF file opened as a book: PDFKit's document plus what a reader asks of it — the title, the outline with pages,
/// which way the pages turn, each page's geometry and text.
///
/// The file is read from disk as needed (PDFKit maps it), never loaded whole. A document whose file is replaced
/// while it is open (the usual atomic save: a new file renamed over the old one) keeps reading the old file.
public final class PDFBookDocument {
    nonisolated public enum OpenError: Error, Hashable, Sendable {
        /// The file is not a PDF, is damaged or cut short, or is empty.
        case unreadable
        /// The PDF has no pages.
        case noPages
    }

    public let url: URL
    /// PDFKit's document (the one a `PDFReaderSession` displays).
    public let pdf: PDFDocument
    /// A second document on the same file for reading text away from the main actor (search, excerpts).
    let textStore: PDFTextStore

    /// The outline, empty when the file has none (and while the document is locked).
    public private(set) var outline: [PDFOutlineItem] = []
    /// The outline's entries that have a destination, flattened, for "which entry is this place in".
    public private(set) var outlineIndex = PDFOutlineIndex(entries: [])
    /// The direction the file asks for (`/ViewerPreferences /Direction`), nil when it does not say.
    public private(set) var pageDirection: PDFPageDirection?
    /// The file's own text marks and notes once `annotations()` has read them; nil before.
    public internal(set) var loadedAnnotations: [PDFDocumentAnnotation]?
    /// The annotations a reader session has put on the pages for its overlays (`PDFReaderSession.overlays`). They
    /// are on this document's pages, so the record is here: a session that follows another on the same document
    /// takes away what the earlier one drew. In the order they were added to the pages, which is the order PDFKit
    /// draws them in.
    var drawnOverlays: [(overlay: PDFOverlay, annotations: [(page: PDFPage, annotation: PDFAnnotation)])] = []

    /// Opens the file. A password-protected document opens locked (`isLocked`): unlock it before showing it.
    public init(url: URL) throws(OpenError) {
        guard let pdf = PDFDocument(url: url) else { throw .unreadable }
        // refused before the second document is opened
        guard pdf.isLocked || pdf.pageCount > 0 else { throw .noPages }
        self.url = url
        self.pdf = pdf
        textStore = PDFTextStore(url: url)
        if !pdf.isLocked { readStructure() }
    }

    // MARK: Password

    /// Whether the document needs a password before anything of it can be read.
    public var isLocked: Bool { pdf.isLocked }

    /// Unlocks the document with the user or owner password. False when the password is wrong (or the document,
    /// once open, turns out to have no pages).
    public func unlock(password: String) async -> Bool {
        // unlocked before: true only if that unlocking succeeded (a document without pages stays refused)
        guard pdf.isLocked else { return pdf.pageCount > 0 }
        guard pdf.unlock(withPassword: password), !pdf.isLocked, pdf.pageCount > 0 else { return false }
        await textStore.unlock(password: password)
        readStructure()
        return true
    }

    // MARK: Facts

    public var pageCount: Int { pdf.pageCount }

    /// The document's title (the Info dictionary's `Title`), nil when it has none or is locked.
    public var title: String? { Self.attribute(PDFDocumentAttribute.titleAttribute, of: pdf) }

    /// The document's author (`Author`).
    public var author: String? { Self.attribute(PDFDocumentAttribute.authorAttribute, of: pdf) }

    /// Whether the document lets its text be copied (false: offer no "copy" or "quote" of a selection).
    public var allowsCopying: Bool { pdf.allowsCopying }

    /// A text entry of the Info dictionary, trimmed; nil when it is missing or blank.
    nonisolated static func attribute(_ key: PDFDocumentAttribute, of pdf: PDFDocument) -> String? {
        guard let value = pdf.documentAttributes?[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The nearest page that exists (1-based): a link to a page past the end opens the last page.
    public func clampedPage(_ page: Int) -> Int {
        min(max(1, page), max(1, pageCount))
    }

    /// How a page is displayed (its crop box and rotation); nil when there is no such page. 1-based.
    public func geometry(ofPage page: Int) -> PDFPageGeometry? {
        pdf.page(at: page - 1).map(Self.geometry(of:))
    }

    nonisolated static func geometry(of page: PDFPage) -> PDFPageGeometry {
        PDFPageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
    }

    // MARK: Text

    /// The text of a page in reading order (1-based). Read away from the main actor.
    public func text(ofPage page: Int) async -> PDFPageText {
        await textStore.text(ofPage: page - 1)
    }

    /// The first characters of a page, for the text of a link to it. Empty for a page without text.
    public func excerpt(ofPage page: Int, maxLength: Int = 40) async -> String {
        await textStore.text(ofPage: page - 1).excerpt(maxLength: maxLength)
    }

    // MARK: Outline and direction

    private func readStructure() {
        pageDirection = Self.pageDirection(of: pdf)
        var counter = 0
        var entries: [PDFOutlineIndex.Entry] = []
        outline = pdf.outlineRoot.map { items(of: $0, depth: 0, counter: &counter, entries: &entries) } ?? []
        outlineIndex = PDFOutlineIndex(entries: entries)
    }

    /// A damaged outline can be very deep or loop: stop at these.
    private static let maxOutlineDepth = 32
    private static let maxOutlineItems = 20000

    private func items(of parent: PDFOutline, depth: Int, counter: inout Int, entries: inout [PDFOutlineIndex.Entry]) -> [PDFOutlineItem] {
        guard depth < Self.maxOutlineDepth else { return [] }
        var result: [PDFOutlineItem] = []
        for index in 0 ..< parent.numberOfChildren {
            guard counter < Self.maxOutlineItems, let child = parent.child(at: index) else { break }
            let id = counter
            counter += 1
            let label = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
            var pageNumber: Int?
            var top = 0.0
            if let destination, let page = destination.page {
                let pageIndex = pdf.index(for: page)
                if pageIndex != NSNotFound {
                    pageNumber = pageIndex + 1
                    top = Self.top(of: destination.point, on: Self.geometry(of: page))
                    entries.append(.init(title: label, page: pageIndex + 1, top: top))
                }
            }
            let children = items(of: child, depth: depth + 1, counter: &counter, entries: &entries)
            result.append(PDFOutlineItem(id: id, label: label, page: pageNumber, top: top, children: children))
        }
        return result
    }

    /// Where a destination's point lies, from the top of the displayed page (clamped to the page); 0 when the
    /// destination does not say. An unspecified coordinate is `kPDFDestinationUnspecifiedValue` (FLT_MAX); a missing x
    /// counts as the page's left edge.
    nonisolated static func top(of point: CGPoint, on geometry: PDFPageGeometry) -> Double {
        let unspecified = CGFloat(Float.greatestFiniteMagnitude) / 2
        guard point.y.isFinite, point.y < unspecified else { return 0 }
        let x = point.x.isFinite && point.x < unspecified ? point.x : geometry.cropBox.minX
        let y = Double(geometry.displayed(CGPoint(x: x, y: point.y)).y)
        return min(max(0, y), Double(geometry.displayedSize.height))
    }

    nonisolated static func pageDirection(of pdf: PDFDocument) -> PDFPageDirection? {
        guard let catalog = pdf.documentRef?.catalog else { return nil }
        var preferences: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "ViewerPreferences", &preferences), let preferences else { return nil }
        var name: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(preferences, "Direction", &name), let name else { return nil }
        return PDFPageDirection(viewerPreference: String(cString: name))
    }
}

// MARK: - Without a reader

/// What can be read from a PDF file without showing it: enough to file it (a title, an author, a cover).
nonisolated public struct PDFBookInfo: Hashable, Sendable {
    public var title: String?
    public var author: String?
    public var pageCount: Int
    /// The file needs a password: nothing else could be read.
    public var isLocked: Bool

    public init(title: String?, author: String?, pageCount: Int, isLocked: Bool) {
        self.title = title
        self.author = author
        self.pageCount = pageCount
        self.isLocked = isLocked
    }

    /// Reads the file's facts. nil when it is not a PDF that can be opened. Callable from any thread; it reads only
    /// the document's structure (about 5 MB of memory for a 360 MB file).
    public static func read(fileAt url: URL) -> PDFBookInfo? {
        guard let pdf = PDFDocument(url: url) else { return nil }
        guard !pdf.isLocked else { return PDFBookInfo(title: nil, author: nil, pageCount: 0, isLocked: true) }
        return PDFBookInfo(title: PDFBookDocument.attribute(PDFDocumentAttribute.titleAttribute, of: pdf),
                           author: PDFBookDocument.attribute(PDFDocumentAttribute.authorAttribute, of: pdf),
                           pageCount: pdf.pageCount, isLocked: false)
    }

    /// The first page as a small image (a cover), at most `maxPixelSize` on its longer side. nil for a locked or
    /// unreadable file. Uses PDFKit's thumbnail, which stays within a few megabytes even for a page that is one
    /// large image (drawing the page into a bitmap context does not).
    public static func cover(fileAt url: URL, maxPixelSize: CGFloat = 600) -> CGImage? {
        guard let pdf = PDFDocument(url: url), !pdf.isLocked, let page = pdf.page(at: 0) else { return nil }
        let size = PDFBookDocument.geometry(of: page).displayedSize
        guard size.width > 0, size.height > 0, maxPixelSize > 0 else { return nil }
        let scale = min(1, maxPixelSize / max(size.width, size.height))
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let image = page.thumbnail(of: target, for: .cropBox)
        #if canImport(UIKit)
        return image.cgImage
        #else
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }
}

// MARK: - Text away from the main actor

/// A second `PDFDocument` on the same file, used only inside this actor: reading a page's text takes time on a
/// dense page, and a search reads every page.
actor PDFTextStore {
    let document: PDFDocument?
    var cachedAnnotations: [PDFDocumentAnnotation]?

    /// The pages read so far, with when each was last asked for. The least recently used goes first once there are
    /// more than `cacheLimit` pages and they hold more than `cacheBudget` bytes: a book of ordinary size is read
    /// once, so a second search (the query typed further) does not read every page again.
    private var cache: [Int: (text: PDFPageText, lastUse: Int)] = [:]
    private var cacheSize = 0
    private var uses = 0
    static let cacheLimit = 48
    static let cacheBudget = 8 << 20

    init(url: URL) {
        document = PDFDocument(url: url)
    }

    func unlock(password: String) {
        _ = document?.unlock(withPassword: password)
    }

    /// The text of a page (0-based). Empty when there is no such page or it has no text.
    func text(ofPage index: Int) -> PDFPageText {
        uses += 1
        if let entry = cache[index] {
            cache[index]?.lastUse = uses
            return entry.text
        }
        guard let document, !document.isLocked, index >= 0, index < document.pageCount, let page = document.page(at: index) else {
            return PDFPageText(lines: [])
        }
        let text = Self.text(of: page)
        cache[index] = (text, uses)
        cacheSize += text.estimatedByteCount
        while cache.count > Self.cacheLimit, cacheSize > Self.cacheBudget,
              let oldest = cache.min(by: { $0.value.lastUse < $1.value.lastUse })
        {
            cache[oldest.key] = nil
            cacheSize -= oldest.value.text.estimatedByteCount
        }
        return text
    }

    /// The lines of `PDFPage.string`. A single character gets its bounds measured: that is how the columns of
    /// vertical text are told from lines (`PDFPageText`).
    static func text(of page: PDFPage) -> PDFPageText {
        guard let string = page.string, !string.isEmpty else { return PDFPageText(lines: []) }
        let geometry = PDFBookDocument.geometry(of: page)
        let whole = string as NSString
        var lines: [PDFPageText.Line] = []
        whole.enumerateSubstrings(in: NSRange(location: 0, length: whole.length), options: .byLines) { text, range, _, _ in
            guard let text, range.length > 0 else { return }
            var bounds: CGRect?
            // `characterBounds(at:)` does not count line breaks, so its index is not the string's: measure through a selection
            if text.isSingleCharacter, let selection = page.selection(for: range) {
                let rect = selection.bounds(for: page)
                if !rect.isEmpty { bounds = geometry.displayed(rect) }
            }
            lines.append(PDFPageText.Line(text: text, range: range, bounds: bounds))
        }
        return PDFPageText(lines: lines)
    }
}
