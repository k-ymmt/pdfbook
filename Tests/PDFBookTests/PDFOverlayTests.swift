import CoreGraphics
import Foundation
@_spi(Testing) import PDFBook
import PDFKit
import Testing

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// What the application draws over the pages (overlays), the file's own marks, and finding a quote again.
@MainActor @Suite struct PDFOverlayTests {
    let folder = try! TemporaryFolder()
    static let size = CGSize(width: 640, height: 800)
    static let yellow = PDFOverlay.Color(red: 1, green: 0.8, blue: 0, alpha: 0.4)
    static let blue = PDFOverlay.Color(red: 0.1, green: 0.4, blue: 1)

    /// The paper with a highlight over the second line of page 2 (with a comment), an underline over two lines of
    /// page 2, a note on page 5, and two annotations that are not listed (a hidden mark, a note without words).
    private static func annotated() -> MiniPDF {
        var paper = Fixture.paper()
        paper.pages[1].marks = [
            .init(subtype: "Highlight", rect: CGRect(x: 72, y: 692, width: 300, height: 16), quads: [CGRect(x: 72, y: 692, width: 300, height: 16)],
                  contents: "Worth a second look"),
            .init(subtype: "Underline", rect: CGRect(x: 72, y: 620, width: 300, height: 40),
                  quads: [CGRect(x: 72, y: 644, width: 300, height: 16), CGRect(x: 72, y: 620, width: 120, height: 16)], color: [0, 0.5, 1]),
            .init(subtype: "Highlight", rect: CGRect(x: 72, y: 500, width: 300, height: 16), quads: [CGRect(x: 72, y: 500, width: 300, height: 16)],
                  hidden: true),
        ]
        paper.pages[4].marks = [
            .init(subtype: "Text", rect: CGRect(x: 500, y: 700, width: 20, height: 20), contents: "A note in the margin"),
            .init(subtype: "Text", rect: CGRect(x: 500, y: 600, width: 20, height: 20)),
        ]
        return paper
    }

    /// The middle of a rectangle of the view's coordinates, measured from the view's top-left corner (what a tap
    /// takes): an AppKit view counts y up from its bottom edge, a UIKit view down from its top.
    private static func centreFromTopLeft(_ rect: CGRect) -> CGPoint {
        #if canImport(UIKit)
        CGPoint(x: rect.midX, y: rect.midY)
        #else
        CGPoint(x: rect.midX, y: size.height - rect.midY)
        #endif
    }

    #if canImport(UIKit)
    /// Tells the view controllers inside a view that they appear, as a window would.
    private static func appear(_ view: UIView) {
        if let controller = view.next as? UIViewController, controller.view === view {
            controller.beginAppearanceTransition(true, animated: false)
            controller.endAppearanceTransition()
        }
        view.subviews.forEach(appear)
    }
    #endif

    private func session(_ pdf: MiniPDF = Fixture.paper(), _ layout: PDFReaderLayout = PDFReaderLayout(),
                         at position: PDFReadingPosition? = nil) throws -> (PDFReaderSession, EventLog, URL)
    {
        let url = try folder.write(pdf.data(), named: "paper-\(UUID().uuidString).pdf")
        let session = PDFReaderSession(document: try PDFBookDocument(url: url), layout: layout, initialPosition: position)
        let log = EventLog()
        session.onEvent = { log.events.append($0) }
        session.layOut(size: Self.size)
        return (session, log, url)
    }

    /// The place of some text of a page, as a selection would give it.
    private func fragment(of text: String, to end: String? = nil, onPage number: Int, in session: PDFReaderSession) throws -> PDFFragment {
        let page = try #require(session.document.pdf.page(at: number - 1))
        let string = try #require(page.string) as NSString
        let start = string.range(of: text)
        try #require(start.location != NSNotFound)
        let upper = end.map { string.range(of: $0, range: NSRange(location: start.location, length: string.length - start.location)).upperBound } ?? start.upperBound
        // not through the view's selection: a tap right after a selection ended is not a tap on the page
        let selection = try #require(page.selection(for: NSRange(location: start.location, length: upper - start.location)))
        return try #require(session.selectedText(of: selection)).fragment
    }

    /// The share of the pixels of a rectangle of a page (displayed coordinates) that have a colour (not white, grey
    /// or black), with the page drawn as PDFKit draws it.
    private func colouredShare(of rect: CGRect, onPage number: Int, in session: PDFReaderSession) throws -> Double {
        let page = try #require(session.document.pdf.page(at: number - 1))
        let box = page.bounds(for: .cropBox)
        let scale: CGFloat = 2
        let width = Int(box.width * scale), height = Int(box.height * scale)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .cropBox, to: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // displayed coordinates (y down from the top) are the bitmap's rows from the top
        var coloured = 0, total = 0
        for y in Int(rect.minY * scale) ..< Int(rect.maxY * scale) where y >= 0 && y < height {
            for x in Int(rect.minX * scale) ..< Int(rect.maxX * scale) where x >= 0 && x < width {
                let pixel = data + (y * width + x) * 4
                let r = Int(pixel[0]), g = Int(pixel[1]), b = Int(pixel[2])
                if max(r, g, b) - min(r, g, b) > 24 { coloured += 1 }
                total += 1
            }
        }
        return total == 0 ? 0 : Double(coloured) / Double(total)
    }

    // MARK: Overlays

    @Test func anOverlayIsDrawnInItsStyleAndTheFileStaysAsItWas() throws {
        let (session, _, url) = try session()
        let before = try Data(contentsOf: url)
        let place = try fragment(of: "quick brown fox", onPage: 1, in: session)
        let rect = place.parts[0].rects[0].cgRect
        #expect(try colouredShare(of: rect, onPage: 1, in: session) < 0.01)

        session.overlays = [PDFOverlay(id: "a", fragment: place, color: Self.yellow, style: .highlight)]
        #expect(try colouredShare(of: rect.insetBy(dx: 2, dy: 2), onPage: 1, in: session) > 0.7, "a highlight fills the line")

        // the line of an underline is in the lowest part, the line of a strikethrough in the middle
        let upper = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.4)
        let middle = CGRect(x: rect.minX, y: rect.minY + rect.height * 0.3, width: rect.width, height: rect.height * 0.4)
        let lower = CGRect(x: rect.minX, y: rect.maxY - rect.height * 0.35, width: rect.width, height: rect.height * 0.35)
        session.overlays = [PDFOverlay(id: "a", fragment: place, color: Self.blue, style: .underline)]
        #expect(try colouredShare(of: lower, onPage: 1, in: session) > 0.03)
        #expect(try colouredShare(of: upper, onPage: 1, in: session) < 0.01)
        session.overlays = [PDFOverlay(id: "a", fragment: place, color: Self.blue, style: .strikethrough)]
        #expect(try colouredShare(of: middle, onPage: 1, in: session) > 0.03)
        #expect(try colouredShare(of: CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2), onPage: 1, in: session) < 0.01)

        // a frame: colour along the edges, none inside
        session.overlays = [PDFOverlay(id: "a", fragment: place, color: Self.blue, style: .outline)]
        #expect(try colouredShare(of: CGRect(x: rect.minX - 1, y: rect.minY + 3, width: 2, height: rect.height - 6), onPage: 1, in: session) > 0.3)
        #expect(try colouredShare(of: CGRect(x: rect.minX + 3, y: rect.minY - 1, width: rect.width - 6, height: 2), onPage: 1, in: session) > 0.3)
        #expect(try colouredShare(of: rect.insetBy(dx: 3, dy: 3), onPage: 1, in: session) < 0.01)

        session.overlays = []
        #expect(try colouredShare(of: rect.insetBy(dx: -2, dy: -2), onPage: 1, in: session) < 0.01)
        #expect(try Data(contentsOf: url) == before, "the file is never written")
    }

    @Test func settingTheListReplacesOnlyWhatChanged() throws {
        let (session, _, _) = try session()
        let first = try fragment(of: "quick brown fox", onPage: 1, in: session)
        let second = try fragment(of: "Page 3 line 2", onPage: 3, in: session)
        let across = try #require(PDFFragment(parts: first.parts + second.parts))
        func marks(onPage number: Int) -> [PDFAnnotation] {
            (session.document.pdf.page(at: number - 1)?.annotations ?? []).filter { $0.type != "Link" }
        }
        session.overlays = [PDFOverlay(id: "a", fragment: first, color: Self.yellow), PDFOverlay(id: "b", fragment: second, color: Self.yellow)]
        #expect(marks(onPage: 1).map(\.type) == ["Highlight"])
        #expect(marks(onPage: 3).map(\.type) == ["Highlight"])
        let kept = try #require(marks(onPage: 3).first)

        // "b" changes its style, "a" before it stays: the annotation of "a" is the same object
        let keptFirst = try #require(marks(onPage: 1).first)
        session.overlays = [PDFOverlay(id: "a", fragment: first, color: Self.yellow), PDFOverlay(id: "b", fragment: second, color: Self.blue, style: .underline)]
        #expect(marks(onPage: 3).map(\.type) == ["Underline"])
        #expect(marks(onPage: 1).first === keptFirst)
        #expect(marks(onPage: 3).first !== kept)
        // one more at the end leaves both
        let keptSecond = try #require(marks(onPage: 3).first)
        let third = try fragment(of: "Page 5 line 2", onPage: 5, in: session)
        session.overlays += [PDFOverlay(id: "z", fragment: third, color: Self.yellow)]
        #expect(marks(onPage: 1).first === keptFirst && marks(onPage: 3).first === keptSecond)
        #expect(marks(onPage: 5).count == 1)

        // one overlay over a page break is one annotation on each page; a frame is one square per rectangle
        session.overlays = [PDFOverlay(id: "c", fragment: across, color: Self.blue, style: .outline)]
        #expect(marks(onPage: 1).map(\.type) == ["Square"])
        #expect(marks(onPage: 3).map(\.type) == ["Square"])

        // what names a whole page, or a page the document does not have, draws nothing
        let beyond = try #require(PDFFragment(page: 99, lineRects: [CGRect(x: 10, y: 10, width: 50, height: 12)]))
        session.overlays = [PDFOverlay(id: "d", fragment: PDFFragment(page: 2), color: Self.yellow), PDFOverlay(id: "e", fragment: beyond, color: Self.yellow)]
        #expect((1 ... 8).allSatisfy { marks(onPage: $0).isEmpty })
    }

    /// PDFKit draws a page's annotations in the order they were added, and a tap goes to the later overlay of the
    /// list. A change of an earlier overlay must not lift it above the later one it lies under.
    @Test func overlaysThatLieOverEachOtherAreDrawnInTheListsOrderAfterAChange() throws {
        let (session, log, _) = try session()
        let place = try fragment(of: "quick brown fox", onPage: 1, in: session)
        func colours() -> [PDFOverlay.Color?] {
            (session.document.pdf.page(at: 0)?.annotations ?? []).filter { $0.type == "Square" }.map { annotation in
                sRGB(annotation.color)
            }
        }
        let red = PDFOverlay.Color(red: 1, green: 0, blue: 0), green = PDFOverlay.Color(red: 0, green: 1, blue: 0)
        session.overlays = [PDFOverlay(id: "a", fragment: place, color: red, style: .outline), PDFOverlay(id: "b", fragment: place, color: Self.blue, style: .outline)]
        session.overlays = [PDFOverlay(id: "a", fragment: place, color: green, style: .outline), PDFOverlay(id: "b", fragment: place, color: Self.blue, style: .outline)]
        #expect(colours().map { $0?.blue ?? -1 } == [0, 1].map { Double($0) * Self.blue.blue }, "a under b: \(colours())")
        // the list in another order is drawn in that order
        session.overlays = [PDFOverlay(id: "b", fragment: place, color: Self.blue, style: .outline), PDFOverlay(id: "a", fragment: place, color: green, style: .outline)]
        #expect(colours().last??.green == 1, "\(colours())")
        let page = try #require(session.document.pdf.page(at: 0))
        let geometry = try #require(session.document.geometry(ofPage: 1))
        let inView = session.pdfView.convert(geometry.page(place.parts[0].rects[0].cgRect), from: page)
        log.events = []
        PDFReaderViewInsets.tap(at: Self.centreFromTopLeft(inView), on: session)
        #expect({ if case .overlayTapped(id: "a", _) = log.events.first { true } else { false } }())
    }

    /// A rectangle taller than wide is a column of vertical text: the line of an underline runs down its right side
    /// (the side line of vertical Japanese), the line of a strikethrough down its middle — not across its foot.
    @Test func theLinesOfAColumnRunDownIt() throws {
        let (session, _, _) = try session()
        // an empty part of page 1, right of the text
        let rect = CGRect(x: 480, y: 300, width: 16, height: 120)
        let place = try #require(PDFFragment(page: 1, lineRects: [rect]))
        let left = CGRect(x: rect.minX, y: rect.minY + 10, width: rect.width * 0.35, height: rect.height - 20)
        let middle = CGRect(x: rect.minX + rect.width * 0.3, y: rect.minY + 10, width: rect.width * 0.4, height: rect.height - 20)
        let right = CGRect(x: rect.maxX - rect.width * 0.35, y: rect.minY + 10, width: rect.width * 0.35, height: rect.height - 20)
        session.overlays = [PDFOverlay(id: "a", fragment: place, color: Self.blue, style: .underline)]
        #expect(try colouredShare(of: right, onPage: 1, in: session) > 0.03, "the line is on the right side")
        #expect(try colouredShare(of: left, onPage: 1, in: session) < 0.01)
        session.overlays = [PDFOverlay(id: "a", fragment: place, color: Self.blue, style: .strikethrough)]
        #expect(try colouredShare(of: middle, onPage: 1, in: session) > 0.03, "the line is in the middle")
        #expect(try colouredShare(of: CGRect(x: rect.maxX - 2, y: rect.minY + 10, width: 2, height: rect.height - 20), onPage: 1, in: session) < 0.01)
        #expect(try colouredShare(of: CGRect(x: rect.minX, y: rect.minY + 10, width: 2, height: rect.height - 20), onPage: 1, in: session) < 0.01)
    }

    @Test func aSessionThatFollowsAnotherOnTheDocumentStartsWithoutItsOverlays() throws {
        let (session, _, _) = try session()
        let place = try fragment(of: "quick brown fox", onPage: 1, in: session)
        func marks() -> [PDFAnnotation] {
            (session.document.pdf.page(at: 0)?.annotations ?? []).filter { $0.type != "Link" }
        }
        session.overlays = [PDFOverlay(id: "a", fragment: place, color: Self.yellow)]
        #expect(marks().count == 1)

        // the reader is shown again from the top: a new session on the same document
        let next = PDFReaderSession(document: session.document)
        #expect(marks().isEmpty)
        next.overlays = [PDFOverlay(id: "a", fragment: place, color: Self.yellow)]
        #expect(marks().count == 1, "drawn once, not on top of what the first session left")
    }

    @Test func aTapOnAnOverlayReportsItAndNothingElse() throws {
        let (session, log, _) = try session()
        let place = try fragment(of: "quick brown fox", onPage: 1, in: session)
        session.overlays = [PDFOverlay(id: "a", fragment: place, color: Self.yellow)]
        let page = try #require(session.document.pdf.page(at: 0))
        let geometry = try #require(session.document.geometry(ofPage: 1))
        // where the middle of the rectangle is on screen, from the view's top-left corner
        let inView = session.pdfView.convert(geometry.page(place.parts[0].rects[0].cgRect), from: page)
        let point = Self.centreFromTopLeft(inView)
        log.events = []
        PDFReaderViewInsets.tap(at: point, on: session)
        #expect(log.events.count == 1)
        guard case .overlayTapped(let id, let rects) = log.events.first else {
            Issue.record("\(log.events)")
            return
        }
        #expect(id == "a")
        #expect(rects.count == 1)
        #expect(try #require(rects.first).contains(point), "the rectangles are measured from the view's top-left corner")
        #expect(abs(try #require(rects.first).width - inView.width) < 0.5)

        // beside it: an ordinary tap
        log.events = []
        PDFReaderViewInsets.tap(at: CGPoint(x: point.x, y: point.y + 200), on: session)
        #expect({ if case .tapped = log.events.first { true } else { false } }())
    }

    /// The paper's first page has a link over its second line (to page 4). An overlay drawn over the same line lies
    /// above the link among the page's annotations: the tap is still the link's.
    @Test func aTapOnALinkUnderAnOverlayIsLeftToTheLink() throws {
        let (session, log, _) = try session()
        let place = try #require(PDFFragment(page: 1, lineRects: [CGRect(x: 72, y: 86, width: 200, height: 16)]))
        session.overlays = [PDFOverlay(id: "a", fragment: place, color: Self.yellow)]
        let page = try #require(session.document.pdf.page(at: 0))
        let geometry = try #require(session.document.geometry(ofPage: 1))
        let inView = session.pdfView.convert(geometry.page(place.parts[0].rects[0].cgRect), from: page)
        log.events = []
        PDFReaderViewInsets.tap(at: Self.centreFromTopLeft(inView), on: session)
        #expect(!log.events.contains { if case .overlayTapped = $0 { true } else { false } })
        #expect(!log.events.contains { if case .tapped = $0 { true } else { false } })
    }

    #if os(macOS)
    /// With nothing selected, PDFKit's menu of a secondary click is about the word under the pointer. That word is
    /// selected and gets the application's actions (a click on a word, then "Highlight"), not PDFKit's menu.
    @Test func aSecondaryClickOnAWordOffersTheApplicationsActionsForIt() throws {
        let (session, _, _) = try session()
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = session.pdfView
        session.layOut(size: Self.size)
        let place = try fragment(of: "Chapter", onPage: 1, in: session)
        let page = try #require(session.document.pdf.page(at: 0))
        let geometry = try #require(session.document.geometry(ofPage: 1))
        let inView = session.pdfView.convert(geometry.page(place.parts[0].rects[0].cgRect), from: page)
        let point = CGPoint(x: inView.midX, y: Self.size.height - inView.midY)
        var picked: [String] = []
        let actions = [PDFSelectionAction(id: "mark", title: "Mark") { picked.append($0.text) }]
        #expect(session.selectedText == nil)
        #expect(PDFReaderViewInsets.menuTitles(at: point, actions: actions, on: session) == ["Mark"])
        #expect(session.selectedText?.text == "Chapter")
        // away from the text nothing gets selected: PDFKit's own menu
        session.clearSelection()
        let margin = PDFReaderViewInsets.menuTitles(at: CGPoint(x: Self.size.width - 8, y: Self.size.height - 8), actions: actions, on: session)
        #expect(!margin.contains("Mark"))
        #expect(picked.isEmpty)
        window.contentView = nil
    }
    #endif

    @Test func aTapOnAnOverlayAtThePagesEdgeDoesNotTurnThePage() async throws {
        let (session, log, _) = try session(Fixture.paper(), PDFReaderLayout(mode: .pages))
        // the start of the first line lies in the left quarter of the view, where a tap turns the page
        #if canImport(UIKit)
        // The page view controller of iOS builds the view of a page when it appears, which a view without a window
        // never does (a package's tests have no window scene to make one in): it is told that it appears
        Self.appear(session.pdfView)
        session.layOut(size: Self.size)
        #endif
        let place = try fragment(of: "Chapter", onPage: 1, in: session)
        let rect = place.parts[0].rects[0].cgRect
        // from the view's top-left corner (the page view controller of iOS lays the page out itself, with margins)
        let inView = try #require(PDFReaderViewInsets.rectInView(rect, onPage: 1, on: session))
        // the page is scaled the same way across and down, and lies in the view
        let scaleAcross = inView.width / rect.width, scaleDown = inView.height / rect.height
        #expect(scaleAcross > 0.5 && abs(scaleAcross - scaleDown) < 0.02 * scaleAcross, "\(inView)")
        #expect(CGRect(origin: .zero, size: Self.size).contains(inView), "\(inView)")
        let point = CGPoint(x: inView.midX, y: inView.midY)
        try #require(point.x < Self.size.width * 0.25)
        await session.go(toPage: 2)
        await session.go(toPage: 1)
        session.overlays = [PDFOverlay(id: "edge", fragment: place, color: Self.yellow)]
        log.events = []
        PDFReaderViewInsets.tap(at: point, on: session)
        #expect(session.position?.page == 1)
        #expect({ if case .overlayTapped(id: "edge", _) = log.events.first { true } else { false } }())
        // without the overlay the same tap turns the page (back, from page 2)
        session.overlays = []
        await session.go(toPage: 2)
        PDFReaderViewInsets.tap(at: point, on: session)
        #expect(session.position?.page == 1)
    }

    @Test func anOverlayOnARotatedCroppedPageLiesWhereItsRectanglesSay() throws {
        var paper = Fixture.paper()
        paper.pages[0].rotate = 90
        paper.pages[0].cropBox = CGRect(x: 36, y: 100, width: 500, height: 660)
        let (session, _, _) = try session(paper)
        let place = try fragment(of: "quick brown fox", onPage: 1, in: session)
        session.overlays = [PDFOverlay(id: "a", fragment: place, color: Self.yellow)]
        let page = try #require(session.document.pdf.page(at: 0))
        let annotation = try #require(page.annotations.first { $0.type == "Highlight" })
        let geometry = try #require(session.document.geometry(ofPage: 1))
        let expected = geometry.page(place.parts[0].rects[0].cgRect)
        #expect(abs(annotation.bounds.minX - expected.minX) < 0.01 && abs(annotation.bounds.minY - expected.minY) < 0.01)
        #expect(abs(annotation.bounds.width - expected.width) < 0.01 && abs(annotation.bounds.height - expected.height) < 0.01)
        // the line runs down the displayed page and across the unrotated one
        let rect = place.parts[0].rects[0].cgRect
        #expect(rect.height > rect.width)
        #expect(annotation.bounds.width > annotation.bounds.height)
    }

    // MARK: The file's own marks

    @Test func theFilesOwnMarksAndNotesAreListedInPageOrder() async throws {
        let (session, _, _) = try session(Self.annotated())
        let document = session.document
        #expect(document.loadedAnnotations == nil)
        let annotations = await document.annotations()
        #expect(annotations.map(\.kind) == [.highlight, .underline, .note])
        #expect(annotations.map(\.fragment.page) == [2, 2, 5])
        #expect(annotations[0].text.hasPrefix("Page 2 line 2: lorem ipsum"))
        #expect(annotations[0].contents == "Worth a second look")
        #expect(annotations[0].fragment.parts[0].rects.count == 1)
        // two quadrilaterals, two lines
        #expect(annotations[1].fragment.parts[0].rects.count == 2)
        #expect(annotations[1].text.hasPrefix("Page 2 line 4: lorem ipsum"))
        #expect(annotations[1].text.contains("Page 2 line 5"))
        #expect(annotations[1].contents == nil)
        let colour = try #require(annotations[1].color)
        #expect(colour.blue > 0.9 && colour.red < 0.1)
        #expect(annotations[2].text.isEmpty)
        #expect(annotations[2].contents == "A note in the margin")
        #expect(Set(annotations.map(\.id)).count == 3)
        #expect(document.loadedAnnotations == annotations)

        // overlays are not the file's: they never show up in the list
        session.overlays = [PDFOverlay(id: "mine", fragment: annotations[0].fragment, color: Self.yellow)]
        #expect(await document.annotations() == annotations)
    }

    @Test func aTapOnOneOfTheFilesMarksIsReportedOnceTheyAreRead() async throws {
        let (session, log, _) = try session(Self.annotated(), at: PDFReadingPosition(page: 2))
        let page = try #require(session.document.pdf.page(at: 1))
        let geometry = try #require(session.document.geometry(ofPage: 2))
        // the highlighted second line of page 2: baseline 696 in the media box
        let inView = session.pdfView.convert(CGRect(x: 100, y: 694, width: 10, height: 10), from: page)
        let point = Self.centreFromTopLeft(inView)
        _ = geometry
        log.events = []
        PDFReaderViewInsets.tap(at: point, on: session)
        #expect({ if case .tapped = log.events.first { true } else { false } }(), "not read yet: an ordinary tap")
        let annotations = await session.document.annotations()
        log.events = []
        PDFReaderViewInsets.tap(at: point, on: session)
        guard case .annotationTapped(let id, let rects) = log.events.first else {
            Issue.record("\(log.events)")
            return
        }
        #expect(id == annotations[0].id)
        #expect(try #require(rects.first).contains(point))
        // an overlay over it is above it
        session.overlays = [PDFOverlay(id: "mine", fragment: annotations[0].fragment, color: Self.yellow)]
        log.events = []
        PDFReaderViewInsets.tap(at: point, on: session)
        #expect({ if case .overlayTapped(id: "mine", _) = log.events.first { true } else { false } }())
    }

    // MARK: The text at a place, and finding it again

    @Test func theTextAtAPlaceIsTheTextThatWasSelected() async throws {
        let (session, _, _) = try session()
        let document = session.document
        // part of a line: not the words beside it, not the lines above and below
        let part = try fragment(of: "quick brown", onPage: 1, in: session)
        #expect(await document.text(in: part) == "quick brown")
        let line = try fragment(of: "Page 1 line 3: lorem ipsum dolor sit amet", onPage: 1, in: session)
        #expect(await document.text(in: line) == "Page 1 line 3: lorem ipsum dolor sit amet")
        let lines = try fragment(of: "quick", to: "line 3", onPage: 1, in: session)
        #expect(await document.text(in: lines) == "quick brown fox. Page 1 line 2: lorem ipsum dolor sit amet Page 1 line 3")
        #expect(await document.text(in: PDFFragment(page: 2)) == "")
        let beyond = try #require(PDFFragment(page: 99, lineRects: [CGRect(x: 10, y: 10, width: 50, height: 12)]))
        #expect(await document.text(in: beyond) == nil)
        // nothing there: empty, not nil
        let margin = try #require(PDFFragment(page: 1, lineRects: [CGRect(x: 300, y: 700, width: 100, height: 14)]))
        #expect(await document.text(in: margin) == "")
    }

    @Test func aQuoteIsFoundAgainOnTheNearestPage() async throws {
        let (session, _, _) = try session()
        let document = session.document
        // the phrase of page 3 that wraps: found over its two lines, from a place on another page
        let old = try fragment(of: "quick brown fox", onPage: 5, in: session)
        let found = try #require(await document.locate("A phrase that wraps at the end of this line continues here", near: old))
        #expect(found.page == 3)
        #expect(found.parts[0].rects.count == 2)
        #expect(await document.text(in: found) == "A phrase that wraps at the end of this line continues here")

        // every page has "the quick brown fox": the nearest page wins, the page itself first
        #expect(await document.locate("quick brown fox", near: PDFFragment(page: 6))?.page == 6)
        #expect(await document.locate("Page 7 line 2", near: PDFFragment(page: 1))?.page == 7)
        #expect(await document.locate("Page 2 line 9", near: PDFFragment(page: 99))?.page == 2)
        #expect(await document.locate("no such words anywhere", near: old) == nil)
        #expect(await document.locate(" \n ", near: old) == nil)

        // on the page itself, the match nearest to the old place: "lorem ipsum" is on every line
        let line9 = try fragment(of: "Page 4 line 9", onPage: 4, in: session)
        let again = try #require(await document.locate("lorem ipsum", near: line9))
        #expect(again.page == 4)
        #expect(abs(again.parts[0].rects[0].top - line9.parts[0].rects[0].top) < 2)
    }

    /// Of two matches on one line the one at the old place wins, and so does a match after the first 32 of a page
    /// (only so many are measured: the ones nearest to the old place in the page's text).
    @Test func aQuoteThatIsStillAtItsPlaceIsFoundThereAmongItsRepeats() async throws {
        var twice = MiniPDF.Page(lines: ["target filler target", "another line"])
        twice.fontSize = 12
        var many = MiniPDF.Page(lines: (1 ... 40).map { _ in "The same words on every line" })
        many.fontSize = 10
        many.leading = 16
        many.origin = CGPoint(x: 72, y: 760)
        let (session, _, _) = try session(MiniPDF(pages: [twice, many]))
        let document = session.document
        func place(ofOccurrence occurrence: Int, of text: String, onPage number: Int) throws -> PDFFragment {
            let page = try #require(document.pdf.page(at: number - 1))
            let string = try #require(page.string) as NSString
            var search = NSRange(location: 0, length: string.length), found = NSRange(location: NSNotFound, length: 0)
            for _ in 1 ... occurrence {
                found = string.range(of: text, range: search)
                try #require(found.location != NSNotFound)
                search = NSRange(location: found.upperBound, length: string.length - found.upperBound)
            }
            let selection = try #require(page.selection(for: found))
            return try #require(session.selectedText(of: selection)).fragment
        }
        let second = try place(ofOccurrence: 2, of: "target", onPage: 1)
        let first = try place(ofOccurrence: 1, of: "target", onPage: 1)
        try #require(first != second && first.parts[0].rects[0].top == second.parts[0].rects[0].top)
        #expect(await document.locate("target", near: second) == second)
        #expect(await document.locate("target", near: first) == first)

        let late = try place(ofOccurrence: 40, of: "The same words on every line", onPage: 2)
        #expect(await document.locate("The same words on every line", near: late) == late)
        let early = try place(ofOccurrence: 2, of: "The same words on every line", onPage: 2)
        #expect(await document.locate("The same words on every line", near: early) == early)
    }

    /// PDFKit gives a column of vertical text one line per character; a selection of it is one rectangle and its
    /// characters joined. The text at that place reads the same (not one character per line).
    @Test func theTextOfAColumnIsJoinedLikeTheSelectionItCameFrom() async throws {
        // one letter per line, each right below the other: what PDFKit makes of vertical text
        var column = MiniPDF.Page(lines: ["A", "B", "C", "D"])
        column.fontSize = 14
        column.leading = 14
        let (session, _, _) = try session(MiniPDF(pages: [column]))
        let page = try #require(session.document.pdf.page(at: 0))
        let string = try #require(page.string) as NSString
        let range = NSRange(location: string.range(of: "A").location, length: string.range(of: "D").upperBound - string.range(of: "A").location)
        let selection = try #require(page.selection(for: range))
        let selected = try #require(session.selectedText(of: selection))
        try #require(selected.fragment.parts[0].rects.count == 1, "the letters are one column: \(selected.fragment)")
        #expect(selected.text == "A B C D")
        #expect(await session.document.text(in: selected.fragment) == selected.text)
    }
}

/// A colour's sRGB components (AppKit converts the colour space first; UIKit reports them in extended sRGB).
#if canImport(UIKit)
private func sRGB(_ color: UIColor) -> PDFOverlay.Color? {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
    return PDFOverlay.Color(red: Double(red), green: Double(green), blue: Double(blue))
}
#else
private func sRGB(_ color: NSColor) -> PDFOverlay.Color? {
    color.usingColorSpace(.sRGB).map { PDFOverlay.Color(red: Double($0.redComponent), green: Double($0.greenComponent), blue: Double($0.blueComponent)) }
}
#endif
