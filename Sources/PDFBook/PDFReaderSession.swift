import CoreGraphics
import Foundation
import Observation
import PDFBookCore
import PDFKit

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// How a PDF is laid out on screen: the mode, one page or two, and which way the pages advance.
nonisolated public struct PDFReaderLayout: Equatable, Sendable {
    public enum Mode: Hashable, Sendable {
        /// All pages in one vertical strip.
        case scroll
        /// One page (or one spread) at a time.
        case pages
    }

    public var mode: Mode
    /// Two pages side by side, the first page alone (a cover).
    public var twoPages: Bool
    /// Which way the pages advance (decides the sides of a spread and the direction of a page turn).
    public var direction: PDFPageDirection

    public init(mode: Mode = .scroll, twoPages: Bool = false, direction: PDFPageDirection = .leftToRight) {
        self.mode = mode
        self.twoPages = twoPages
        self.direction = direction
    }
}

/// Why the reader moved.
nonisolated public enum PDFNavigationCause: Hashable, Sendable {
    /// A page was turned (a tap on the edge, a swipe, a key).
    case pageTurn
    /// The application asked for another place (`go(to:)`, `show(_:)`).
    case jump
    /// A link inside the document was followed.
    case link
    /// The reader scrolled and stopped on another page.
    case scroll
}

nonisolated public enum PDFReaderEvent: Sendable {
    /// The position changed, by whatever means (also sent once when the first page is shown).
    case positionChanged(PDFReadingPosition)
    /// The pages on screen changed while the position stayed (one page instead of two, another layout).
    case visiblePagesChanged([Int])
    /// The reader moved to another place. Not sent for the first page or when the layout changes.
    case navigated(cause: PDFNavigationCause, from: PDFReadingPosition?, to: PDFReadingPosition)
    /// In the scroll layout: the reader started (true) or stopped (false) scrolling.
    case scrolling(Bool)
    /// A tap that did nothing else (not on a link, not ending a selection, not on a page-turn edge).
    case tapped
    case selectionChanged(hasSelection: Bool)
    /// A link to somewhere outside the document was tapped. The view does not open it.
    case externalLink(URL)
    /// An overlay (`PDFReaderSession.overlays`) was tapped. `rects` are its rectangles on the tapped page, in the
    /// view's coordinates measured from the view's top-left corner (what a popover is anchored to).
    case overlayTapped(id: String, rects: [CGRect])
    /// One of the file's own text marks or notes was tapped (reported once `PDFBookDocument.annotations()` has read
    /// them). `rects` as for an overlay.
    case annotationTapped(id: String, rects: [CGRect])
}

/// One match of a search of the document's text.
nonisolated public struct PDFSearchHit: Identifiable, Hashable, Sendable {
    /// The match's number in the order found.
    public let id: Int
    /// The page of the match, the first page being 1.
    public var page: Int
    /// The text around the match.
    public var snippet: String
    public var matchRangeInSnippet: Range<String.Index>
    /// The match as ranges of the page's string (`PDFPage.string`, UTF-16).
    public var sourceRanges: [NSRange]

    public init(id: Int, page: Int, snippet: String, matchRangeInSnippet: Range<String.Index>, sourceRanges: [NSRange]) {
        self.id = id
        self.page = page
        self.snippet = snippet
        self.matchRangeInSnippet = matchRangeInSnippet
        self.sourceRanges = sourceRanges
    }
}

/// The text the reader has selected, as a place.
nonisolated public struct PDFSelectedText: Hashable, Sendable {
    /// The selection as `page=…&highlight=…`: one rectangle per line, in reading order.
    public var fragment: PDFFragment
    /// The selected text, its lines joined.
    public var text: String

    public init(fragment: PDFFragment, text: String) {
        self.fragment = fragment
        self.text = text
    }
}

/// An item of the menu shown for a selection. When a view has any, they replace the system's items.
public struct PDFSelectionAction: Identifiable {
    public var id: String
    public var title: String
    public var systemImage: String?
    public var perform: (PDFSelectedText) -> Void

    public init(id: String, title: String, systemImage: String? = nil, perform: @escaping (PDFSelectedText) -> Void) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.perform = perform
    }
}

/// One PDF being read: owns the PDFKit view, keeps the reading position, and turns what happens in the view into
/// events. Show it with `PDFReaderView`.
@Observable
public final class PDFReaderSession {
    public let document: PDFBookDocument

    /// The layout. Changing it keeps the reader at the same place.
    @ObservationIgnored public var layout: PDFReaderLayout {
        didSet { if layout != oldValue { applyLayout() } }
    }

    /// Where the reader is; nil until the first page is shown.
    public private(set) var position: PDFReadingPosition?
    /// The pages on screen (1-based, ascending).
    public private(set) var visiblePages: [Int] = []

    /// Receives the events. Called on the main actor.
    @ObservationIgnored public var onEvent: (PDFReaderEvent) -> Void = { _ in }

    /// What the application draws over the pages: highlights, underlines, lines through the text, frames. Setting
    /// the list replaces what was drawn before (from the first overlay that changed on). In memory only: the file is
    /// never written. They are drawn in the list's order, and a tap on one is reported as `.overlayTapped`: where
    /// two lie over each other, the later one in the list is on top and gets the tap.
    ///
    /// The marks are on the pages of the document, so one session at a time draws on a document: a new session
    /// starts with none and takes away what an earlier session on the same document left.
    @ObservationIgnored public var overlays: [PDFOverlay] = [] {
        didSet { if overlays != oldValue { applyOverlays() } }
    }

    @ObservationIgnored let view: ReaderPDFView

    /// How far above a rectangle the view is put when going to it, in points of the page: the line is not glued to
    /// the top edge.
    public static let leadAboveTarget: Double = 72

    @ObservationIgnored private var initialPosition: PDFReadingPosition?
    @ObservationIgnored private var hasStarted = false
    /// The session itself is moving the view: what the view reports meanwhile is not the reader's doing.
    @ObservationIgnored private var isCommanding = false
    @ObservationIgnored private var lastCommandEnd = Date.distantPast
    @ObservationIgnored private var pending: Pending?
    @ObservationIgnored private var lastPendingID = 0
    @ObservationIgnored private var motion: Motion?
    @ObservationIgnored private var motionEnd: Task<Void, Never>?
    @ObservationIgnored private var contentInsets: (top: CGFloat, bottom: CGFloat) = (0, 0)
    @ObservationIgnored private var hasSelection = false
    @ObservationIgnored private var relayout: Relayout?
    @ObservationIgnored private var lastSelectionEnd = Date.distantPast

    /// A move that is expected to show up in what the view reports (a page change of the paged layout, a link the
    /// view follows itself). `cause` nil: expected, and not to be reported as a navigation.
    private struct Pending {
        /// Which expectation this is: whoever waits for it gives up only its own.
        var id: Int
        var cause: PDFNavigationCause?
        var from: PDFReadingPosition?
        var deadline: Date
    }

    /// The view is being laid out again (a new size, another layout, other insets). PDFKit then moves the document by
    /// its own rules, some of it a moment later: until `until`, whatever the view reports that the reader did not do is
    /// answered by putting `anchor` back.
    private struct Relayout {
        var anchor: PDFReadingPosition
        var until: Date
    }

    /// Expects a move to show up in what the view reports within `seconds`; replaces what was expected before.
    @discardableResult
    private func expect(_ cause: PDFNavigationCause?, from: PDFReadingPosition?, within seconds: TimeInterval = 0.6) -> Int {
        lastPendingID += 1
        pending = Pending(id: lastPendingID, cause: cause, from: from, deadline: Date().addingTimeInterval(seconds))
        return lastPendingID
    }

    /// A stretch of scrolling in the scroll layout, from the first change to 140 ms without one.
    private struct Motion {
        var from: PDFReadingPosition?
        /// nil: the reader's own scrolling
        var cause: PDFNavigationCause?
        var lastEmit: Date
    }

    /// - Parameter initialPosition: where to start; nil for the first page.
    public init(document: PDFBookDocument, layout: PDFReaderLayout = PDFReaderLayout(), initialPosition: PDFReadingPosition? = nil) {
        self.document = document
        self.layout = layout
        self.initialPosition = initialPosition
        view = ReaderPDFView(frame: .zero)
        view.session = self
        view.document = document.pdf
        configureView(rebuild: true)
        // what an earlier session on this document drew is not this session's
        applyOverlays()
    }

    private var pageCount: Int { document.pageCount }

    // MARK: Layout

    private func configureView(rebuild: Bool) {
        let paged = layout.mode == .pages
        #if canImport(UIKit)
        // The page view controller shows one page at a time whatever the display mode says, so it turns the single
        // pages only: a spread is laid out by the view itself and turned by the session (a swipe, a tap on an edge).
        let usesController = paged && !layout.twoPages
        // the controller reads the direction when it is made
        if view.isUsingPageViewController, rebuild || !usesController { view.usePageViewController(false, withViewOptions: nil) }
        // the controller turns along the display direction: sideways for pages, like a book
        view.displayDirection = usesController ? .horizontal : .vertical
        #else
        view.displayDirection = .vertical
        #endif
        view.displaysRTL = layout.direction == .rightToLeft
        view.displaysAsBook = layout.twoPages
        view.displayMode = switch (paged, layout.twoPages) {
        case (false, false): .singlePageContinuous
        case (false, true): .twoUpContinuous
        case (true, false): .singlePage
        case (true, true): .twoUp
        }
        #if canImport(UIKit)
        if usesController, !view.isUsingPageViewController { view.usePageViewController(true, withViewOptions: nil) }
        #endif
        view.autoScales = true
        view.applyContentInsets(top: effectiveInsets.top, bottom: effectiveInsets.bottom)
    }

    private func applyLayout() {
        let anchor = position
        isCommanding = true
        endMotion(report: false)
        pending = nil
        configureView(rebuild: true)
        isCommanding = false
        lastCommandEnd = Date()
        guard hasStarted, let anchor else { return }
        beginRelayout(anchor: anchor, replacing: true)
        view.layoutDocument()
        restore(anchor)
        refresh()
    }

    private func beginRelayout(anchor: PDFReadingPosition?, replacing: Bool = false) {
        let until = Date().addingTimeInterval(0.25)
        if !replacing, let relayout, relayout.until > Date() {
            self.relayout = Relayout(anchor: relayout.anchor, until: until)
        } else if let anchor {
            relayout = Relayout(anchor: anchor, until: until)
        }
    }

    /// The anchor to put back, while the view is being laid out again and the reader is not scrolling.
    private var relayoutAnchor: PDFReadingPosition? {
        guard let relayout, relayout.until > Date(), !view.isUserScrolling else { return nil }
        return relayout.anchor
    }

    /// The view's size is about to change (called by the view).
    func sizeWillChange() {
        guard hasStarted else { return }
        beginRelayout(anchor: position)
    }

    private var effectiveInsets: (top: CGFloat, bottom: CGFloat) {
        layout.mode == .scroll ? contentInsets : (0, 0)
    }

    /// The part of the view at its top and bottom that something else covers (bars over a full-screen page), in the
    /// scroll layout: the document starts below it and positions are measured from below it.
    func setContentInsets(top: CGFloat, bottom: CGFloat) {
        guard contentInsets.top != top || contentInsets.bottom != bottom else { return }
        contentInsets = (top, bottom)
        guard layout.mode == .scroll else { return }
        let anchor = position
        isCommanding = true
        view.applyContentInsets(top: top, bottom: bottom)
        isCommanding = false
        lastCommandEnd = Date()
        if hasStarted, let anchor {
            beginRelayout(anchor: anchor, replacing: true)
            restore(anchor)
            refresh()
        }
    }

    /// The view was laid out (called by the view).
    func viewDidLayout(sizeChanged: Bool) {
        if !hasStarted {
            guard view.bounds.width > 1, view.bounds.height > 1, pageCount > 0 else { return }
            hasStarted = true
            view.applyContentInsets(top: effectiveInsets.top, bottom: effectiveInsets.bottom)
            view.layoutDocument()
            let start = initialPosition ?? .top(ofPage: 1, pageCount: pageCount)
            initialPosition = nil
            beginRelayout(anchor: start, replacing: true)
            restore(start)
            refresh()
            return
        }
        view.applyContentInsets(top: effectiveInsets.top, bottom: effectiveInsets.bottom)
        if sizeChanged {
            beginRelayout(anchor: position)
            if let anchor = relayout?.anchor {
                restore(anchor)
                refresh()
            }
        }
    }

    // MARK: Measuring

    /// The y of the view's coordinates where reading starts: the top edge, below what covers it.
    private var topY: CGFloat { view.yFromTop(effectiveInsets.top) }

    private func pageNumber(_ page: PDFPage?) -> Int? {
        guard let page else { return nil }
        let index = document.pdf.index(for: page)
        return index == NSNotFound ? nil : index + 1
    }

    private func measure() -> (position: PDFReadingPosition, visible: [Int])? {
        let count = pageCount
        guard count > 0 else { return nil }
        let visible = Set(view.visiblePages.compactMap(pageNumber))
        let current = pageNumber(view.currentPage)
        if layout.mode == .pages {
            var page = current ?? visible.min()
            // a spread is named by its first page
            if layout.twoPages, let current, let first = visible.min(), visible.contains(current), current - first == 1 { page = first }
            guard let page else { return nil }
            let shown = layout.twoPages ? visible.filter { $0 == page || $0 == page + 1 }.sorted() : [page]
            return (.top(ofPage: page, pageCount: count), shown.isEmpty ? [page] : shown)
        }
        // the page at the top edge (looked up a point below it: the edge itself may lie between two pages); of a row of
        // two, the earlier one
        let y = topY
        var top: (page: PDFPage, number: Int)?
        for share in layout.twoPages ? [0.25, 0.75] : [0.5] {
            let probe = CGPoint(x: view.bounds.minX + view.bounds.width * share, y: view.yFromTop(effectiveInsets.top + 1))
            guard let page = view.page(for: probe, nearest: true), let number = pageNumber(page) else { continue }
            if top == nil || number < top!.number { top = (page, number) }
        }
        guard let top else {
            guard let current else { return nil }
            return (.top(ofPage: current, pageCount: count), visible.isEmpty ? [current] : visible.sorted())
        }
        let geometry = PDFBookDocument.geometry(of: top.page)
        let height = geometry.displayedSize.height
        let inPage = view.convert(CGPoint(x: view.bounds.midX, y: y), to: top.page)
        // rounded: the same place measured twice differs in the last bits
        let offset = height > 0 ? min(max(0, (Double(geometry.displayed(inPage).y / height) * 1_000_000).rounded() / 1_000_000), 0.999_999) : 0
        let position = PDFReadingPosition(page: top.number, offset: offset, totalProgression: (Double(top.number - 1) + offset) / Double(count))
        return (position, visible.isEmpty ? [top.number] : visible.sorted())
    }

    /// Reads the view and takes over what it shows. True when the position changed.
    @discardableResult
    private func refresh() -> Bool {
        guard hasStarted, let measured = measure() else { return false }
        let visibleChanged = visiblePages != measured.visible
        if visibleChanged { visiblePages = measured.visible }
        guard position != measured.position else {
            if visibleChanged { onEvent(.visiblePagesChanged(measured.visible)) }
            return false
        }
        position = measured.position
        onEvent(.positionChanged(measured.position))
        return true
    }

    /// What a move is compared by: "did the reader end up somewhere else". The paged layout has no place finer
    /// than the page.
    nonisolated public struct Place: Hashable, Sendable {
        var page: Int
        var offset: Int
    }

    public var place: Place {
        place(of: position)
    }

    private func place(of position: PDFReadingPosition?) -> Place {
        guard let position else { return Place(page: 0, offset: 0) }
        return Place(page: position.page, offset: layout.mode == .scroll ? Int((position.offset * 2000).rounded()) : 0)
    }

    // MARK: Moving

    /// Puts a place of the document at the top of the view, without reporting anything.
    private func restore(_ position: PDFReadingPosition) {
        let wasCommanding = isCommanding
        isCommanding = true
        defer {
            isCommanding = wasCommanding
            lastCommandEnd = Date()
        }
        let number = document.clampedPage(position.page)
        guard let page = document.pdf.page(at: number - 1) else { return }
        if layout.mode == .scroll {
            let geometry = PDFBookDocument.geometry(of: page)
            let y = position.offset * Double(geometry.displayedSize.height)
            let target = geometry.page(CGPoint(x: 0, y: y))
            view.go(to: PDFDestination(page: page, at: target))
            view.alignTop(of: target, on: page, inset: effectiveInsets.top)
        } else if pageNumber(view.currentPage) != number {
            // the page view controller reports the change later: expected, and not a page turn
            if pending == nil { expect(nil, from: nil) }
            view.go(to: page)
        }
    }

    private func move(to position: PDFReadingPosition, cause: PDFNavigationCause, before body: () -> Void = {}) async {
        guard hasStarted else {
            // nothing is shown yet: the session starts there, with what `body` marks
            body()
            initialPosition = position
            return
        }
        // a scroll still under way ends here, so that the move starts from where it had come to
        endMotion(report: true)
        let from = self.position
        let fromPlace = place
        relayout = nil
        if layout.mode == .scroll {
            isCommanding = true
            body()
            restore(position)
            isCommanding = false
            lastCommandEnd = Date()
            refresh()
            if place != fromPlace, let now = self.position { onEvent(.navigated(cause: cause, from: from, to: now)) }
        } else {
            body()
            let expected = expect(cause, from: from)
            restore(position)
            pageObserved()
            // The page view controller (iOS) reports the new page a moment later. A later move replaces what is
            // expected: this one then stops waiting and leaves the other's expectation alone.
            var tries = 0
            let target = document.clampedPage(position.page)
            while pending?.id == expected, tries < 12, holdsPageReports || !visiblePages.contains(target) {
                try? await Task.sleep(for: .milliseconds(40))
                pageObserved()
                tries += 1
            }
            if pending?.id == expected { pending = nil }
        }
    }

    /// Goes to a position. The page is clamped to the document.
    public func go(to position: PDFReadingPosition) async {
        clearSearchHighlight()
        await move(to: position, cause: .jump)
    }

    /// Goes to a page (1-based), its top.
    public func go(toPage page: Int) async {
        await go(to: .top(ofPage: document.clampedPage(page), pageCount: pageCount))
    }

    /// Goes to the start of a place written as a fragment. A page past the end is the last page.
    public func go(to fragment: PDFFragment) async {
        await go(to: document.position(of: fragment))
    }

    /// Goes to where an outline entry points. Nothing happens for an entry without a destination.
    public func go(to item: PDFOutlineItem) async {
        guard let position = document.position(of: item) else { return }
        await go(to: position)
    }

    /// Goes to a search hit and marks it.
    public func show(_ hit: PDFSearchHit) async {
        guard let page = document.pdf.page(at: hit.page - 1) else { return }
        let selection = PDFKit.PDFSelection(document: document.pdf)
        for range in hit.sourceRanges {
            if let part = page.selection(for: range) { selection.add(part) }
        }
        var position = PDFReadingPosition.top(ofPage: hit.page, pageCount: pageCount)
        let geometry = PDFBookDocument.geometry(of: page)
        let bounds = selection.bounds(for: page)
        if !bounds.isEmpty, geometry.displayedSize.height > 0 {
            position = document.position(page: hit.page, top: Double(geometry.displayed(bounds).minY) - Self.leadAboveTarget)
        }
        await move(to: position, cause: .jump) {
            selection.color = ReaderPDFView.searchHighlightColor
            view.highlightedSelections = selection.pages.isEmpty ? nil : [selection]
        }
    }

    /// Removes the mark of the last `show(_:)`.
    public func clearSearchHighlight() {
        if view.highlightedSelections != nil { view.highlightedSelections = nil }
    }

    /// In the paged layout, turns to the next (true) or previous page or spread. Does nothing at either end and in
    /// the scroll layout.
    public func turnPage(forward: Bool) {
        guard hasStarted, layout.mode == .pages, forward ? view.canGoToNextPage : view.canGoToPreviousPage else { return }
        relayout = nil
        expect(.pageTurn, from: position)
        if forward { view.goToNextPage(nil) } else { view.goToPreviousPage(nil) }
        pageObserved()
    }

    // MARK: What the view reports

    /// The current page or the visible pages changed (a notification of the view).
    func pageObserved() {
        guard hasStarted, !isCommanding, !holdsPageReports else { return }
        guard layout.mode == .pages else {
            scrollObserved()
            return
        }
        if let anchor = relayoutAnchor, pending?.cause == nil {
            restore(anchor)
            refresh()
            return
        }
        let old = position
        refresh()
        guard let old, let new = position, old.page != new.page else { return }
        if let pending, pending.deadline > Date() {
            self.pending = nil
            if let cause = pending.cause { onEvent(.navigated(cause: cause, from: pending.from, to: new)) }
        } else {
            pending = nil
            onEvent(.navigated(cause: .pageTurn, from: old, to: new))
        }
    }

    /// The scroll offset changed (observed by the view).
    func scrollObserved() {
        guard hasStarted, !isCommanding, layout.mode == .scroll else { return }
        if let anchor = relayoutAnchor {
            restore(anchor)
            refresh()
            return
        }
        let now = Date()
        if motion == nil {
            // what the view still reports right after the session moved it
            if now.timeIntervalSince(lastCommandEnd) < 0.08, !view.isUserScrolling {
                refresh()
                return
            }
            var cause: PDFNavigationCause?
            if let pending, pending.deadline > now { cause = pending.cause }
            pending = nil
            motion = Motion(from: position, cause: cause, lastEmit: .distantPast)
            if cause == nil { onEvent(.scrolling(true)) }
        }
        if now.timeIntervalSince(motion?.lastEmit ?? .distantPast) >= 0.1 {
            motion?.lastEmit = now
            refresh()
        }
        motionEnd?.cancel()
        motionEnd = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, let self else { return }
            if view.isUserScrolling {
                // a finger resting on the page: not over yet
                scrollObserved()
            } else {
                endMotion(report: true)
            }
        }
    }

    private func endMotion(report: Bool) {
        motionEnd?.cancel()
        motionEnd = nil
        guard let motion else { return }
        self.motion = nil
        guard report else { return }
        refresh()
        if motion.cause == nil { onEvent(.scrolling(false)) }
        guard let now = position else { return }
        if let cause = motion.cause {
            if place(of: motion.from) != place(of: now) { onEvent(.navigated(cause: cause, from: motion.from, to: now)) }
        } else if motion.from?.page != now.page {
            onEvent(.navigated(cause: .scroll, from: motion.from, to: now))
        }
    }

    /// A sideways swipe over a spread that the view lays out itself (iOS: the page view controller turns the single
    /// pages by itself). A swipe to the left goes on in a left-to-right book. Not while the page is enlarged (the
    /// swipe then moves the page) or a selection is being made.
    func swiped(toLeft: Bool) {
        guard hasStarted, layout.mode == .pages, !view.turnsPagesItself, !hasSelection else { return }
        guard view.scaleFactor <= view.scaleFactorForSizeToFit * 1.02 else { return }
        clearSearchHighlight()
        turnPage(forward: toLeft == (layout.direction == .leftToRight))
    }

    /// A tap or click that the view did not use for anything else, at a point of the view.
    func tapped(at point: CGPoint) {
        guard hasStarted else { return }
        // a tap that ended a selection is not a tap on the page
        if hasSelection || Date().timeIntervalSince(lastSelectionEnd) < 0.4 { return }
        switch linkKind(at: point) {
        case .inside:
            expectLink()
            return
        case .outside:
            return
        case nil:
            break
        }
        // a mark under the tap is what the tap was for: not a page turn, not the bars
        if let hit = markHit(at: point) {
            onEvent(hit)
            return
        }
        clearSearchHighlight()
        if layout.mode == .pages, view.bounds.width > 0 {
            let share = (point.x - view.bounds.minX) / view.bounds.width
            let leftToRight = layout.direction == .leftToRight
            if share < 0.25 {
                turnPage(forward: !leftToRight)
                return
            }
            if share >= 0.75 {
                turnPage(forward: leftToRight)
                return
            }
        }
        onEvent(.tapped)
    }

    enum LinkKind {
        /// to a place in the document: the view goes there itself
        case inside
        /// a URL: reported through `linkClicked(_:)`
        case outside
    }

    func linkKind(at point: CGPoint) -> LinkKind? {
        guard let page = view.page(for: point, nearest: false) else { return nil }
        let inPage = view.convert(point, to: page)
        // every annotation under the point, not only the topmost: an overlay drawn over a link lies above it
        guard let annotation = page.annotations.last(where: { $0.type == "Link" && $0.bounds.contains(inPage) }) else { return nil }
        return annotation.url != nil || annotation.action is PDFActionURL ? .outside : .inside
    }

    // MARK: Overlays

    private func applyOverlays() {
        // the same id twice: the later one, at the later one's place
        var last: [String: Int] = [:]
        for (index, overlay) in overlays.enumerated() { last[overlay.id] = index }
        let wanted = overlays.enumerated().filter { last[$0.element.id] == $0.offset }.map(\.element)
        // PDFKit draws a page's annotations in the order they were added, and a tap goes to the later overlay of the
        // list: what is drawn has to be in the list's order. So everything from the first difference on is taken
        // off and added again (a change of one overlay must not lift it above the ones after it)
        let drawn = document.drawnOverlays
        var kept = 0
        while kept < drawn.count, kept < wanted.count, drawn[kept].overlay == wanted[kept] { kept += 1 }
        guard kept < drawn.count || kept < wanted.count else { return }
        var changed: [PDFPage] = []
        for entry in drawn[kept...] {
            for (page, annotation) in entry.annotations {
                page.removeAnnotation(annotation)
                changed.append(page)
            }
        }
        document.drawnOverlays.removeSubrange(kept...)
        for overlay in wanted[kept...] {
            let annotations = overlay.annotations(in: document.pdf)
            for (page, annotation) in annotations {
                page.addAnnotation(annotation)
                changed.append(page)
            }
            document.drawnOverlays.append((overlay, annotations))
        }
        var seen = Set<ObjectIdentifier>()
        for page in changed where seen.insert(ObjectIdentifier(page)).inserted {
            view.annotationsChanged(on: page)
        }
    }

    /// The overlay or, failing that, the document's own mark at a point of the view, as the event that reports it.
    private func markHit(at point: CGPoint) -> PDFReaderEvent? {
        guard let page = view.page(for: point, nearest: false), let number = pageNumber(page) else { return nil }
        let geometry = PDFBookDocument.geometry(of: page)
        let displayed = geometry.displayed(view.convert(point, to: page))
        func inView(_ rects: [CGRect]) -> [CGRect] {
            rects.map { view.rectFromTopLeft(view.convert(geometry.page($0), from: page)) }
        }
        var seen = Set<String>()
        for overlay in overlays.reversed() where seen.insert(overlay.id).inserted {
            let rects = PDFOverlay.rects(of: overlay.fragment, onPage: number, hitBy: displayed)
            if !rects.isEmpty { return .overlayTapped(id: overlay.id, rects: inView(rects)) }
        }
        for annotation in (document.loadedAnnotations ?? []).reversed() where annotation.fragment.page == number {
            let rects = PDFOverlay.rects(of: annotation.fragment, onPage: number, hitBy: displayed)
            if !rects.isEmpty { return .annotationTapped(id: annotation.id, rects: inView(rects)) }
        }
        return nil
    }

    /// The view is about to follow a link inside the document.
    func expectLink() {
        clearSearchHighlight()
        relayout = nil
        expect(.link, from: position, within: 0.8)
    }

    func linkClicked(_ url: URL) {
        onEvent(.externalLink(url))
    }

    func selectionObserved() {
        let has = !(view.currentSelection?.string ?? "").isEmpty
        guard has != hasSelection else { return }
        hasSelection = has
        if !has { lastSelectionEnd = Date() }
        onEvent(.selectionChanged(hasSelection: has))
    }

    /// A key of the paged layout: the arrows turn the page the way it lies (in a right-to-left book the left arrow
    /// goes on). False when the key is not the session's.
    func handle(_ key: ReaderPDFView.Key) -> Bool {
        guard hasStarted, layout.mode == .pages else { return false }
        let leftToRight = layout.direction == .leftToRight
        switch key {
        case .left: turnPage(forward: !leftToRight)
        case .right: turnPage(forward: leftToRight)
        case .next: turnPage(forward: true)
        case .previous: turnPage(forward: false)
        }
        return true
    }

    // MARK: Selection

    /// The selected text as a place; nil without a selection.
    public var selectedText: PDFSelectedText? {
        view.currentSelection.flatMap { PDFBookDocument.selectedText(of: $0, in: document.pdf) }
    }

    public func clearSelection() {
        view.clearSelection()
    }

    // MARK: For tests

    /// Gives the view a size and lays it out, as a window would.
    @_spi(Testing) public func layOut(size: CGSize) {
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutNow()
    }

    @_spi(Testing) public var pdfView: PDFView { view }

    /// A selection as `selectedText` would report it, without making it the view's selection.
    @_spi(Testing) public func selectedText(of selection: PDFSelection) -> PDFSelectedText? {
        PDFBookDocument.selectedText(of: selection, in: document.pdf)
    }

    /// While true the session does not hear the view's page changes: the page view controller of iOS reports a page a
    /// moment after it was asked for, and this is how a test makes that moment last.
    @ObservationIgnored @_spi(Testing) public var holdsPageReports = false {
        didSet { if !holdsPageReports, oldValue { pageObserved() } }
    }
}

/// What tests do in place of the SwiftUI view and the reader's finger.
@_spi(Testing) public enum PDFReaderViewInsets {
    public static func set(top: CGFloat, bottom: CGFloat, on session: PDFReaderSession) {
        session.setContentInsets(top: top, bottom: bottom)
    }

    /// A sideways swipe over the page.
    public static func swipe(toLeft: Bool, on session: PDFReaderSession) {
        session.swiped(toLeft: toLeft)
    }

    #if !canImport(UIKit)
    /// Scrolls the view to a place the way the reader does (`byReader`, a live scroll) or the way PDFKit moves the
    /// document by itself.
    public static func scroll(to position: PDFReadingPosition, on session: PDFReaderSession, byReader: Bool) {
        guard let page = session.document.pdf.page(at: session.document.clampedPage(position.page) - 1) else { return }
        let geometry = PDFBookDocument.geometry(of: page)
        let target = geometry.page(CGPoint(x: 0, y: position.offset * Double(geometry.displayedSize.height)))
        session.view.scroll(asReader: byReader) {
            session.view.go(to: PDFDestination(page: page, at: target))
            session.view.alignTop(of: target, on: page, inset: 0)
        }
    }
    #endif

    #if !canImport(UIKit)
    /// The titles of the menu a secondary click at a point of the view (from its top-left corner) opens, with
    /// `actions` as the application's actions for a selection. The view has to be in a window.
    public static func menuTitles(at point: CGPoint, actions: [PDFSelectionAction], on session: PDFReaderSession) -> [String] {
        session.view.selectionActions = actions
        let inView = CGPoint(x: session.view.bounds.minX + point.x, y: session.view.yFromTop(point.y))
        guard let window = session.view.window,
              let event = NSEvent.mouseEvent(with: .rightMouseDown, location: session.view.convert(inView, to: nil), modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return [] }
        return session.view.menu(for: event)?.items.map(\.title) ?? []
    }
    #endif

    /// A tap at a point of the view (from its top-left corner).
    public static func tap(at point: CGPoint, on session: PDFReaderSession) {
        session.tapped(at: CGPoint(x: session.view.bounds.minX + point.x, y: session.view.yFromTop(point.y)))
    }
}

extension PDFBookDocument {
    /// The position that shows a place of a page: `top` points from the top of the displayed page (clamped to it).
    public func position(page: Int, top: Double) -> PDFReadingPosition {
        let number = clampedPage(page)
        guard number == page, let geometry = geometry(ofPage: number), geometry.displayedSize.height > 0 else {
            return .top(ofPage: number, pageCount: pageCount)
        }
        let offset = min(max(0, top), Double(geometry.displayedSize.height)) / Double(geometry.displayedSize.height)
        return PDFReadingPosition(page: number, offset: offset, totalProgression: (Double(number - 1) + min(offset, 0.999_999)) / Double(max(1, pageCount)))
    }

    /// The position that shows the start of a fragment: the page's top for a page, a little above the first
    /// rectangle for a range. A page past the end is the last page.
    public func position(of fragment: PDFFragment) -> PDFReadingPosition {
        guard let top = fragment.parts[0].rects.first?.top else {
            return .top(ofPage: clampedPage(fragment.page), pageCount: pageCount)
        }
        return position(page: fragment.page, top: top - PDFReaderSession.leadAboveTarget)
    }

    /// The position an outline entry points to; nil for an entry without a destination.
    public func position(of item: PDFOutlineItem) -> PDFReadingPosition? {
        item.page.map { position(page: $0, top: item.top) }
    }

    /// Searches the text of every page, from the first; hits arrive in reading order. The work happens away from the
    /// main actor and stops when the stream is dropped.
    public func search(_ query: String) -> AsyncThrowingStream<PDFSearchHit, any Error> {
        let store = textStore, count = pageCount
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var id = 0
                for index in 0 ..< count {
                    guard !Task.isCancelled else { break }
                    let text = await store.text(ofPage: index)
                    for match in text.matches(of: query) {
                        let snippet = text.snippet(around: match.range)
                        continuation.yield(PDFSearchHit(id: id, page: index + 1, snippet: snippet.text, matchRangeInSnippet: snippet.match,
                                                        sourceRanges: match.sourceRanges))
                        id += 1
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
