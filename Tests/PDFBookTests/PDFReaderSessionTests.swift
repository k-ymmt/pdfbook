import CoreGraphics
import Foundation
@_spi(Testing) import PDFBook
import PDFKit
import Testing

/// Collects a session's events.
@MainActor final class EventLog {
    var events: [PDFReaderEvent] = []

    var navigations: [(cause: PDFNavigationCause, from: Int?, to: Int)] {
        events.compactMap { event in
            if case .navigated(let cause, let from, let to) = event { return (cause, from?.page, to.page) }
            return nil
        }
    }

    var positions: [PDFReadingPosition] {
        events.compactMap { event in
            if case .positionChanged(let position) = event { return position }
            return nil
        }
    }
}

@MainActor @Suite struct PDFReaderSessionTests {
    let folder = try! TemporaryFolder()
    static let size = CGSize(width: 640, height: 800)

    private func session(_ layout: PDFReaderLayout = PDFReaderLayout(), at position: PDFReadingPosition? = nil,
                         direction: String? = nil) throws -> (PDFReaderSession, EventLog)
    {
        let document = try PDFBookDocument(url: folder.write(Fixture.paper(direction: direction).data(), named: "paper.pdf"))
        let session = PDFReaderSession(document: document, layout: layout, initialPosition: position)
        let log = EventLog()
        session.onEvent = { log.events.append($0) }
        session.layOut(size: Self.size)
        return (session, log)
    }

    @Test func theFirstPageIsShownAndReportedOnce() throws {
        let (session, log) = try session()
        #expect(session.position?.page == 1)
        #expect(session.position?.offset == 0)
        #expect(session.visiblePages.first == 1)
        #expect(log.positions.count == 1)
        #expect(log.navigations.isEmpty)
    }

    @Test func aSessionStartsAtTheGivenPosition() throws {
        let (session, log) = try session(at: PDFReadingPosition(page: 5, offset: 0.5))
        let position = try #require(session.position)
        #expect(position.page == 5)
        #expect(abs(position.offset - 0.5) < 0.01)
        #expect(abs(position.totalProgression - 4.5 / 8) < 0.01)
        #expect(log.navigations.isEmpty)
    }

    @Test func goingToAPageIsAJump() async throws {
        let (session, log) = try session()
        await session.go(toPage: 6)
        #expect(session.position?.page == 6)
        #expect(session.position?.offset ?? 1 < 0.01)
        #expect(session.visiblePages.contains(6))
        #expect(log.navigations.map(\.cause) == [.jump])
        #expect(log.navigations.first?.from == 1)
        #expect(log.navigations.first?.to == 6)
        // the position is reported before the move it belongs to
        let lastPosition = log.events.lastIndex { if case .positionChanged = $0 { true } else { false } }
        let navigated = log.events.lastIndex { if case .navigated = $0 { true } else { false } }
        #expect(try #require(lastPosition) < (try #require(navigated)))
    }

    @Test func goingWhereTheReaderIsMovesNothing() async throws {
        let (session, log) = try session()
        await session.go(toPage: 3)
        let place = session.place
        log.events = []
        await session.go(toPage: 3)
        #expect(session.place == place)
        #expect(log.events.isEmpty)
    }

    @Test func aPagePastTheEndIsTheLastPage() async throws {
        let (session, _) = try session()
        await session.go(to: PDFFragment(page: 40))
        #expect(session.position?.page == 8)
    }

    @Test func aRangeIsShownWithALittleOfThePageAboveIt() async throws {
        let (session, _) = try session()
        await session.go(to: PDFFragment("page=4&highlight=72,300,400,414")!)
        let position = try #require(session.position)
        #expect(position.page == 4)
        #expect(abs(position.offset - (400 - 72) / 792) < 0.01)
    }

    @Test func anOutlineEntryLeadsToItsPage() async throws {
        let (session, log) = try session()
        let setup = try #require(session.document.outline[1].children.first)
        await session.go(to: setup)
        #expect(session.position?.page == 4)
        #expect(log.navigations.map(\.cause) == [.jump])
    }

    @Test func thePagedLayoutShowsOnePageAndTurnsIt() async throws {
        let (session, log) = try session(PDFReaderLayout(mode: .pages))
        #expect(session.position == .top(ofPage: 1, pageCount: 8))
        #expect(session.visiblePages == [1])
        session.turnPage(forward: true)
        #expect(session.position?.page == 2)
        #expect(session.visiblePages == [2])
        session.turnPage(forward: false)
        session.turnPage(forward: false)
        #expect(session.position?.page == 1)
        #expect(log.navigations.map(\.cause) == [.pageTurn, .pageTurn])
        #expect(log.navigations.map(\.to) == [2, 1])
        log.events = []
        await session.go(toPage: 7)
        #expect(session.position?.page == 7)
        #expect(log.navigations.map(\.cause) == [.jump])
        #expect(log.navigations.first?.from == 1)
    }

    @Test func aSpreadIsNamedByItsFirstPageAndTheCoverStandsAlone() async throws {
        let (session, _) = try session(PDFReaderLayout(mode: .pages, twoPages: true))
        #expect(session.visiblePages == [1])
        session.turnPage(forward: true)
        #expect(session.position?.page == 2)
        #expect(session.visiblePages == [2, 3])
        await session.go(toPage: 5)
        #expect(session.position?.page == 4)
        #expect(session.visiblePages == [4, 5])
    }

    @Test func changingTheLayoutKeepsThePlaceAndIsNotAMove() async throws {
        let (session, log) = try session()
        await session.go(toPage: 5)
        log.events = []
        session.layout.mode = .pages
        #expect(session.position?.page == 5)
        session.layout.mode = .scroll
        #expect(session.position?.page == 5)
        session.layout.direction = .rightToLeft
        #expect(session.position?.page == 5)
        #expect(log.navigations.isEmpty)
        #expect(session.pdfView.displaysRTL)
    }

    @Test func resizingKeepsThePlace() async throws {
        let (session, log) = try session()
        await session.go(to: PDFReadingPosition(page: 3, offset: 0.4))
        log.events = []
        session.layOut(size: CGSize(width: 900, height: 600))
        let position = try #require(session.position)
        #expect(position.page == 3)
        #expect(abs(position.offset - 0.4) < 0.01)
        #expect(log.navigations.isEmpty)
    }

    @Test func whatCoversTheTopMovesWhereReadingStarts() async throws {
        let (session, _) = try session()
        PDFReaderViewInsets.set(top: 60, bottom: 40, on: session)
        #expect(session.position?.page == 1)
        #expect(session.position?.offset == 0)
        await session.go(to: PDFReadingPosition(page: 2, offset: 0.25))
        let position = try #require(session.position)
        #expect(position.page == 2)
        #expect(abs(position.offset - 0.25) < 0.01)
    }

    @Test func aSearchHitIsShownAndMarked() async throws {
        let (session, log) = try session()
        var hits: [PDFSearchHit] = []
        for try await hit in session.document.search("continues here") { hits.append(hit) }
        let hit = try #require(hits.first)
        await session.show(hit)
        #expect(session.position?.page == 3)
        #expect(session.pdfView.highlightedSelections?.first?.string == "continues here")
        #expect(log.navigations.map(\.cause) == [.jump])
        await session.go(toPage: 1)
        #expect(session.pdfView.highlightedSelections == nil)
    }

    @Test func aSelectionIsAPlaceWithOneRectanglePerLine() throws {
        let (session, log) = try session()
        let page = try #require(session.document.pdf.page(at: 0))
        let string = try #require(page.string) as NSString
        let range = NSRange(location: string.range(of: "quick").location, length: string.range(of: "line 2").upperBound - string.range(of: "quick").location)
        session.pdfView.setCurrentSelection(page.selection(for: range), animate: false)
        let selected = try #require(session.selectedText)
        #expect(selected.text == "quick brown fox. Page 1 line 2")
        #expect(selected.fragment.page == 1)
        let rects = selected.fragment.parts[0].rects
        #expect(rects.count == 2)
        #expect(rects[0].top < rects[1].top)
        #expect(rects[0].left > rects[1].left)
        // the first line is 14 pt text on a baseline 72 pt below the top
        #expect(rects[0].top > 50 && rects[0].bottom < 80)
        #expect(PDFFragment(selected.fragment.description) == selected.fragment)
        #expect(log.events.contains { if case .selectionChanged(hasSelection: true) = $0 { true } else { false } })
        session.clearSelection()
        #expect(session.selectedText == nil)
    }

    @Test func aRightToLeftBookIsTurnedTheOtherWay() throws {
        let (session, _) = try session(PDFReaderLayout(mode: .pages, direction: .rightToLeft), direction: "R2L")
        #expect(session.document.pageDirection == .rightToLeft)
        PDFReaderViewInsets.tap(at: CGPoint(x: 20, y: 400), on: session)
        #expect(session.position?.page == 2)
        PDFReaderViewInsets.tap(at: CGPoint(x: 620, y: 400), on: session)
        #expect(session.position?.page == 1)
    }

    @Test func tapsOnTheEdgesTurnThePageAndTheMiddleIsATap() throws {
        let (session, log) = try session(PDFReaderLayout(mode: .pages))
        PDFReaderViewInsets.tap(at: CGPoint(x: 620, y: 400), on: session)
        #expect(session.position?.page == 2)
        PDFReaderViewInsets.tap(at: CGPoint(x: 20, y: 400), on: session)
        #expect(session.position?.page == 1)
        log.events = []
        PDFReaderViewInsets.tap(at: CGPoint(x: 320, y: 400), on: session)
        #expect(log.events.count == 1)
        #expect({ if case .tapped = log.events.first { true } else { false } }())
    }

    @Test func inTheScrollLayoutEveryTapIsATap() throws {
        let (session, log) = try session()
        log.events = []
        PDFReaderViewInsets.tap(at: CGPoint(x: 620, y: 700), on: session)
        #expect(session.position?.page == 1)
        #expect(log.events.count == 1)
    }
}
