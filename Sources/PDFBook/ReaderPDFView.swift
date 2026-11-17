import PDFKit

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// The PDFKit view of a `PDFReaderSession`: what PDFKit does not report by itself (scrolling, taps that did nothing
// else, the size) and what it has to be told (the menu of a selection, what covers its top and bottom).

extension ReaderPDFView {
    enum Key {
        case left, right, next, previous
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(pageDidChange), name: .PDFViewPageChanged, object: self)
        center.addObserver(self, selector: #selector(pageDidChange), name: .PDFViewVisiblePagesChanged, object: self)
        center.addObserver(self, selector: #selector(pageDidChange), name: .PDFViewScaleChanged, object: self)
        center.addObserver(self, selector: #selector(selectionDidChange), name: .PDFViewSelectionChanged, object: self)
    }

    @objc private func pageDidChange() {
        session?.pageObserved()
    }

    @objc private func selectionDidChange() {
        session?.selectionObserved()
    }

    func selectionItems() -> [(action: PDFSelectionAction, selected: PDFSelectedText)] {
        guard !selectionActions.isEmpty, let selected = session?.selectedText else { return [] }
        return selectionActions.map { ($0, selected) }
    }
}

/// Receives the links to outside the document, so that the view does not open them itself. An object of its own:
/// a PDFView that is its own delegate calls itself without end (its internal delegate calls go through `delegate`).
final class LinkDelegate: NSObject, PDFViewDelegate {
    weak var session: PDFReaderSession?

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        session?.linkClicked(url)
    }
}

#if canImport(UIKit)

final class ReaderPDFView: PDFView {
    weak var session: PDFReaderSession? {
        didSet { linkDelegate.session = session }
    }

    var selectionActions: [PDFSelectionAction] = []
    private let linkDelegate = LinkDelegate()

    static var searchHighlightColor: UIColor { .systemYellow.withAlphaComponent(0.5) }

    private var offsetObservation: NSKeyValueObservation?
    private let tapDelegate = TapDelegate()
    private weak var observedScrollView: UIScrollView?
    private var laidOutSize = CGSize.zero
    private var insets: (top: CGFloat, bottom: CGFloat) = (0, 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = linkDelegate
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTap(_:)))
        tap.delegate = tapDelegate
        addGestureRecognizer(tap)
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(didSwipe(_:)))
            swipe.direction = direction
            swipe.delegate = tapDelegate
            addGestureRecognizer(swipe)
        }
        observeNotifications()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The scroll view of the continuous layouts (none while a page view controller shows the pages).
    var contentScrollView: UIScrollView? {
        isUsingPageViewController ? nil : subviews.lazy.compactMap { $0 as? UIScrollView }.first
    }

    /// Whether the view turns the pages by itself (the page view controller), so that a swipe is not the session's.
    var turnsPagesItself: Bool { isUsingPageViewController }

    var isUserScrolling: Bool {
        guard let scrollView = contentScrollView else { return false }
        return scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating || scrollView.isZooming || scrollView.isZoomBouncing
    }

    func yFromTop(_ distance: CGFloat) -> CGFloat {
        bounds.minY + distance
    }

    /// A rectangle of the view's coordinates, measured from the view's top-left corner with y down.
    func rectFromTopLeft(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
    }

    func layoutDocument() {
        layoutDocumentView()
        layoutIfNeeded()
    }

    func layoutNow() {
        setNeedsLayout()
        layoutIfNeeded()
    }

    override var frame: CGRect {
        willSet { if newValue.size != frame.size { session?.sizeWillChange() } }
    }

    override var bounds: CGRect {
        willSet { if newValue.size != bounds.size { session?.sizeWillChange() } }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        observeScrollView()
        let changed = bounds.size != laidOutSize
        laidOutSize = bounds.size
        session?.viewDidLayout(sizeChanged: changed)
    }

    private func observeScrollView() {
        let scrollView = contentScrollView
        guard scrollView !== observedScrollView else { return }
        observedScrollView = scrollView
        offsetObservation = scrollView?.observe(\.contentOffset) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.session?.scrollObserved() }
        }
        applyContentInsets(top: insets.top, bottom: insets.bottom)
    }

    func applyContentInsets(top: CGFloat, bottom: CGFloat) {
        insets = (top, bottom)
        guard let scrollView = contentScrollView else { return }
        if scrollView.contentInsetAdjustmentBehavior != .never { scrollView.contentInsetAdjustmentBehavior = .never }
        let wanted = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        if scrollView.contentInset != wanted {
            scrollView.contentInset = wanted
            scrollView.verticalScrollIndicatorInsets = wanted
        }
    }

    // MARK: Page coordinates

    /// A point of the view in the coordinates of a page it shows.
    ///
    /// While the page view controller shows the pages, `convert(_:to: page)` and `convert(_:from: page)` answer zero:
    /// the page is mapped through the view the controller zooms (it covers the displayed page exactly) instead.
    func pagePoint(_ point: CGPoint, on page: PDFPage) -> CGPoint {
        guard let zoomed = zoomedPageView(showing: page), zoomed.bounds.width > 0, zoomed.bounds.height > 0 else { return convert(point, to: page) }
        let geometry = PDFBookDocument.geometry(of: page)
        let size = geometry.displayedSize
        let inZoomed = zoomed.convert(point, from: self)
        let displayed = CGPoint(x: (inZoomed.x - zoomed.bounds.minX) / zoomed.bounds.width * size.width,
                                y: (inZoomed.y - zoomed.bounds.minY) / zoomed.bounds.height * size.height)
        return geometry.page(displayed)
    }

    /// A rectangle of a page (page coordinates) in the view's coordinates.
    func viewRect(_ rect: CGRect, on page: PDFPage) -> CGRect {
        guard let zoomed = zoomedPageView(showing: page), zoomed.bounds.width > 0, zoomed.bounds.height > 0 else { return convert(rect, from: page) }
        let geometry = PDFBookDocument.geometry(of: page)
        let size = geometry.displayedSize
        guard size.width > 0, size.height > 0 else { return .zero }
        let displayed = geometry.displayed(rect)
        let sx = zoomed.bounds.width / size.width, sy = zoomed.bounds.height / size.height
        let inZoomed = CGRect(x: zoomed.bounds.minX + displayed.minX * sx, y: zoomed.bounds.minY + displayed.minY * sy,
                              width: displayed.width * sx, height: displayed.height * sy)
        return zoomed.convert(inZoomed, to: self)
    }

    /// The view the page view controller zooms for the page on screen: of the scroll views that have one, the one that
    /// covers most of this view. nil outside the page view controller and for another page than the current one.
    private func zoomedPageView(showing page: PDFPage) -> UIView? {
        guard isUsingPageViewController, page == currentPage else { return nil }
        var best: (view: UIView, area: CGFloat)?
        func visit(_ view: UIView) {
            if let scrollView = view as? UIScrollView, let zoomed = scrollView.delegate?.viewForZooming?(in: scrollView) {
                let visible = zoomed.convert(zoomed.bounds, to: self).intersection(bounds)
                let area = visible.isNull ? 0 : visible.width * visible.height
                if area > (best?.area ?? 0) { best = (zoomed, area) }
                return
            }
            for subview in view.subviews where !subview.isHidden { visit(subview) }
        }
        visit(self)
        return best?.view
    }

    /// Scrolls vertically so that a point of a page sits `inset` below the view's top edge (as far as the document
    /// can scroll).
    func alignTop(of point: CGPoint, on page: PDFPage, inset: CGFloat) {
        guard let scrollView = contentScrollView else { return }
        let current = convert(point, from: page)
        var offset = scrollView.contentOffset
        let lowest = -scrollView.contentInset.top
        let highest = max(lowest, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
        offset.y = min(max(offset.y + current.y - yFromTop(inset), lowest), highest)
        if offset != scrollView.contentOffset { scrollView.setContentOffset(offset, animated: false) }
    }

    // MARK: Taps

    @objc private func didTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        session?.tapped(at: recognizer.location(in: self))
    }

    @objc private func didSwipe(_ recognizer: UISwipeGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        session?.swiped(toLeft: recognizer.direction == .left)
    }

    /// The session's tap and swipes work beside PDFKit's own recognizers: it does not take the long press that starts a selection
    /// or the tap that follows a link away from them. Its delegate is an object of its own: PDFView is the delegate of
    /// its recognizers and answers for those.
    private final class TapDelegate: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }

    // MARK: The menu of a selection

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        let items = selectionItems()
        guard !items.isEmpty else { return }
        for identifier: UIMenu.Identifier in [.lookup, .share, .standardEdit, .learn, .speech, .replace, .textStyle, .spelling, .substitutions,
                                              .transformations, .autoFill, .format]
        {
            builder.remove(menu: identifier)
        }
        let actions = items.map { item in
            UIAction(title: item.action.title, image: item.action.systemImage.flatMap { UIImage(systemName: $0) }) { _ in
                item.action.perform(item.selected)
            }
        }
        builder.insertChild(UIMenu(title: "", identifier: UIMenu.Identifier("pdfbook.selection"), options: .displayInline, children: actions),
                            atStartOfMenu: .root)
    }
}

#else

final class ReaderPDFView: PDFView {
    weak var session: PDFReaderSession? {
        didSet { linkDelegate.session = session }
    }

    var selectionActions: [PDFSelectionAction] = []
    private let linkDelegate = LinkDelegate()

    static var searchHighlightColor: NSColor { .systemYellow.withAlphaComponent(0.5) }

    private weak var observedClipView: NSClipView?
    private weak var observedScrollView: NSScrollView?
    /// Between the start and the end of a live scroll (a gesture with its momentum, the scroller's knob).
    private var isLiveScrolling = false
    private var laidOutSize = CGSize.zero
    private var insets: (top: CGFloat, bottom: CGFloat) = (0, 0)
    private var performers: [() -> Void] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = linkDelegate
        observeNotifications()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var contentScrollView: NSScrollView? {
        documentView?.enclosingScrollView
    }

    /// The view never turns the pages by itself: every page turn is the session's.
    var turnsPagesItself: Bool { false }

    /// Whether the reader is scrolling: during a live scroll, or while a scroll wheel event is being handled (a wheel
    /// with notches has no start and no end; the event stays "current" after it was handled, hence its age).
    var isUserScrolling: Bool {
        if isLiveScrolling { return true }
        guard let event = NSApp?.currentEvent, event.type == .scrollWheel else { return false }
        return ProcessInfo.processInfo.systemUptime - event.timestamp < 0.1
    }

    /// Runs what moves the document as a scroll of the reader's (true) or as a move the view makes by itself.
    func scroll(asReader: Bool, _ body: () -> Void) {
        guard asReader, let scrollView = contentScrollView else { return body() }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        body()
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }

    func yFromTop(_ distance: CGFloat) -> CGFloat {
        isFlipped ? bounds.minY + distance : bounds.maxY - distance
    }

    /// A rectangle of the view's coordinates, measured from the view's top-left corner with y down.
    func rectFromTopLeft(_ rect: CGRect) -> CGRect {
        let rect = rect.standardized
        return CGRect(x: rect.minX - bounds.minX, y: isFlipped ? rect.minY - bounds.minY : bounds.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    func layoutDocument() {
        layoutDocumentView()
        layoutSubtreeIfNeeded()
    }

    func layoutNow() {
        needsLayout = true
        layoutSubtreeIfNeeded()
        layout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { session?.sizeWillChange() }
        super.setFrameSize(newSize)
    }

    override func layout() {
        super.layout()
        observeClipView()
        let changed = bounds.size != laidOutSize
        laidOutSize = bounds.size
        session?.viewDidLayout(sizeChanged: changed)
    }

    private func observeScrollView() {
        let scrollView = contentScrollView
        guard scrollView !== observedScrollView else { return }
        let center = NotificationCenter.default
        if let observedScrollView {
            center.removeObserver(self, name: NSScrollView.willStartLiveScrollNotification, object: observedScrollView)
            center.removeObserver(self, name: NSScrollView.didEndLiveScrollNotification, object: observedScrollView)
        }
        observedScrollView = scrollView
        // a scroll view that went away never says that its scroll ended
        isLiveScrolling = false
        guard let scrollView else { return }
        center.addObserver(self, selector: #selector(liveScrollDidStart), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        center.addObserver(self, selector: #selector(liveScrollDidEnd), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }

    @objc private func liveScrollDidStart() {
        isLiveScrolling = true
    }

    @objc private func liveScrollDidEnd() {
        isLiveScrolling = false
    }

    private func observeClipView() {
        observeScrollView()
        let clipView = contentScrollView?.contentView
        guard clipView !== observedClipView else { return }
        if let observedClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClipView)
        }
        observedClipView = clipView
        guard let clipView else { return }
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewDidScroll), name: NSView.boundsDidChangeNotification, object: clipView)
        applyContentInsets(top: insets.top, bottom: insets.bottom)
    }

    @objc private func clipViewDidScroll() {
        session?.scrollObserved()
    }

    func applyContentInsets(top: CGFloat, bottom: CGFloat) {
        insets = (top, bottom)
        guard let scrollView = contentScrollView else { return }
        if scrollView.automaticallyAdjustsContentInsets { scrollView.automaticallyAdjustsContentInsets = false }
        let wanted = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        let current = scrollView.contentInsets
        if current.top != wanted.top || current.bottom != wanted.bottom || current.left != 0 || current.right != 0 {
            scrollView.contentInsets = wanted
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
    }

    /// A point of the view in the coordinates of a page it shows.
    func pagePoint(_ point: CGPoint, on page: PDFPage) -> CGPoint {
        convert(point, to: page)
    }

    /// A rectangle of a page (page coordinates) in the view's coordinates.
    func viewRect(_ rect: CGRect, on page: PDFPage) -> CGRect {
        convert(rect, from: page)
    }

    /// Scrolls vertically so that a point of a page sits `inset` below the view's top edge (as far as the document
    /// can scroll).
    func alignTop(of point: CGPoint, on page: PDFPage, inset: CGFloat) {
        guard let documentView, let scrollView = contentScrollView else { return }
        let clipView = scrollView.contentView
        // both points in the document view's coordinates: moving the clip view by their difference moves one onto the other
        let current = convert(convert(point, from: page), to: documentView)
        let wanted = convert(CGPoint(x: bounds.midX, y: yFromTop(inset)), to: documentView)
        var visible = clipView.bounds
        visible.origin.y += current.y - wanted.y
        let origin = clipView.constrainBoundsRect(visible).origin
        guard origin != clipView.bounds.origin else { return }
        clipView.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    // MARK: Clicks and keys

    override func mouseDown(with event: NSEvent) {
        let start = event.locationInWindow
        let point = convert(start, from: nil)
        let hadSelection = !(currentSelection?.string ?? "").isEmpty
        let link = session?.linkKind(at: point)
        if link == .inside { session?.expectLink() }
        // returns when the button is released (PDFKit tracks the drag itself)
        super.mouseDown(with: event)
        let end = window?.mouseLocationOutsideOfEventStream ?? start
        let moved = hypot(end.x - start.x, end.y - start.y) > 3
        let hasSelection = !(currentSelection?.string ?? "").isEmpty
        if event.clickCount == 1, !moved, link == nil, !hadSelection, !hasSelection {
            session?.tapped(at: point)
        }
    }

    override func keyDown(with event: NSEvent) {
        let key: Key? = switch event.specialKey {
        case .leftArrow: .left
        case .rightArrow: .right
        case .pageDown: .next
        case .pageUp: .previous
        default: event.charactersIgnoringModifiers == " " ? (event.modifierFlags.contains(.shift) ? .previous : .next) : nil
        }
        if let key, event.modifierFlags.intersection([.command, .control, .option]).isEmpty, session?.handle(key) == true { return }
        super.keyDown(with: event)
    }

    // MARK: The menu of a selection

    override func menu(for event: NSEvent) -> NSMenu? {
        var items = selectionItems()
        if items.isEmpty, !selectionActions.isEmpty {
            // With nothing selected PDFKit's menu is about the word under the pointer (it selects the word once the
            // menu is up). That word gets the application's actions like any other selection: select it now
            let point = convert(event.locationInWindow, from: nil)
            if let page = page(for: point, nearest: false), let word = page.selectionForWord(at: convert(point, to: page)),
               word.string?.contains(where: { !$0.isWhitespace }) == true
            {
                setCurrentSelection(word, animate: false)
                items = selectionItems()
            }
        }
        guard !items.isEmpty else { return super.menu(for: event) }
        let menu = NSMenu()
        performers = items.map { item in { item.action.perform(item.selected) } }
        for (index, item) in items.enumerated() {
            let menuItem = NSMenuItem(title: item.action.title, action: #selector(performSelectionAction(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = index
            if let name = item.action.systemImage { menuItem.image = NSImage(systemSymbolName: name, accessibilityDescription: nil) }
            menu.addItem(menuItem)
        }
        return menu
    }

    @objc private func performSelectionAction(_ sender: NSMenuItem) {
        guard performers.indices.contains(sender.tag) else { return }
        performers[sender.tag]()
    }
}

#endif
