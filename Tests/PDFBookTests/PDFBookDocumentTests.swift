import CoreGraphics
import Foundation
import PDFBook
import Testing

@MainActor @Suite struct PDFBookDocumentTests {
    let folder = try! TemporaryFolder()

    private func paper(direction: String? = nil) throws -> PDFBookDocument {
        try PDFBookDocument(url: folder.write(Fixture.paper(direction: direction).data(), named: "paper-\(direction ?? "none").pdf"))
    }

    @Test func aDocumentReportsItsFacts() throws {
        let document = try paper()
        #expect(document.pageCount == 8)
        #expect(document.title == "Prototype Paper")
        #expect(document.author == "A. Author")
        #expect(!document.isLocked)
        #expect(document.allowsCopying)
        #expect(document.pageDirection == nil)
    }

    @Test func theOutlineCarriesLabelsPagesAndNesting() throws {
        let outline = try paper().outline
        #expect(outline.map(\.label) == ["Introduction", "Methods", "Results"])
        #expect(outline.map(\.page) == [1, 3, 6])
        #expect(outline.map(\.id) == [0, 1, 3])
        #expect(outline[1].children.map(\.label) == ["Setup"])
        #expect(outline[1].children.map(\.page) == [4])
        #expect(outline[1].children.map(\.id) == [2])
    }

    @Test func aPlaceBelongsToTheOutlineEntryBeforeIt() throws {
        let index = try paper().outlineIndex
        #expect(index.entries.map(\.title) == ["Introduction", "Methods", "Setup", "Results"])
        #expect(index.entry(atPage: 2)?.entry.title == "Introduction")
        #expect(index.entry(atPage: 4)?.index == 2)
        #expect(index.entry(at: PDFFragment("page=8&highlight=72,300,100,114")!)?.entry.title == "Results")
    }

    @Test func theReadingDirectionIsReadFromTheViewerPreferences() throws {
        #expect(try paper(direction: "R2L").pageDirection == .rightToLeft)
        #expect(try paper(direction: "L2R").pageDirection == .leftToRight)
    }

    @Test func whatIsNotAPDFIsRefused() throws {
        let garbage = try folder.write(Data("not a pdf at all".utf8), named: "garbage.pdf")
        #expect(throws: PDFBookDocument.OpenError.unreadable) { try PDFBookDocument(url: garbage) }
        let empty = try folder.write(Data(), named: "empty.pdf")
        #expect(throws: PDFBookDocument.OpenError.unreadable) { try PDFBookDocument(url: empty) }
        let whole = Fixture.paper().data()
        let cut = try folder.write(whole.prefix(whole.count / 2), named: "cut.pdf")
        #expect(throws: PDFBookDocument.OpenError.self) { try PDFBookDocument(url: cut) }
        #expect(throws: PDFBookDocument.OpenError.unreadable) { try PDFBookDocument(url: folder.url.appendingPathComponent("missing.pdf")) }
    }

    @Test func aLockedDocumentOpensWithItsPassword() async throws {
        let document = try PDFBookDocument(url: Fixture.locked(password: "secret", in: folder))
        #expect(document.isLocked)
        #expect(document.title == nil)
        #expect(document.outline.isEmpty)
        #expect(await document.unlock(password: "wrong") == false)
        #expect(document.isLocked)
        #expect(await document.unlock(password: "secret"))
        #expect(!document.isLocked)
        #expect(document.pageCount == 8)
        #expect(document.title == "Prototype Paper")
        #expect(document.outline.count == 3)
        // the text is read through a second document, which has to be unlocked too
        #expect(await document.excerpt(ofPage: 1).hasPrefix("Chapter page 1"))
    }

    @Test func pagesAreClampedToTheDocument() throws {
        let document = try paper()
        #expect(document.clampedPage(0) == 1)
        #expect(document.clampedPage(8) == 8)
        #expect(document.clampedPage(99) == 8)
        #expect(document.position(of: PDFFragment(page: 99)) == PDFReadingPosition.top(ofPage: 8, pageCount: 8))
        #expect(document.position(of: PDFFragment("page=99&highlight=72,300,400,414")!).page == 8)
        #expect(document.position(of: PDFFragment("page=99&highlight=72,300,400,414")!).offset == 0)
    }

    @Test func aRangeIsShownALittleAboveItsFirstRectangle() throws {
        let document = try paper()
        let position = document.position(of: PDFFragment("page=3&highlight=72,300,400,414")!)
        #expect(position.page == 3)
        #expect(abs(position.offset - (400 - 72) / 792) < 1e-9)
        #expect(abs(position.totalProgression - (2 + position.offset) / 8) < 1e-9)
        // near the top of the page there is nothing above to show
        #expect(document.position(of: PDFFragment("page=3&highlight=72,300,40,54")!).offset == 0)
    }

    @Test func theGeometryFollowsTheCropBoxAndTheRotation() throws {
        var pdf = MiniPDF(pages: [.init(lines: ["Rotated"]), .init(lines: ["Cropped"])])
        pdf.pages[0].rotate = 90
        pdf.pages[1].cropBox = CGRect(x: 36, y: 100, width: 500, height: 660)
        let document = try PDFBookDocument(url: folder.write(pdf.data(), named: "geometry.pdf"))
        #expect(document.geometry(ofPage: 1) == PDFPageGeometry(cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 90))
        #expect(document.geometry(ofPage: 1)?.displayedSize == CGSize(width: 792, height: 612))
        #expect(document.geometry(ofPage: 2)?.cropBox == CGRect(x: 36, y: 100, width: 500, height: 660))
        #expect(document.geometry(ofPage: 3) == nil)
    }

    @Test func theTextOfAPageIsReadInOrder() async throws {
        let document = try paper()
        #expect(await document.excerpt(ofPage: 2, maxLength: 14) == "Chapter page 2")
        #expect(await document.text(ofPage: 2).text.contains("the quick brown fox. Page 2 line 2: lorem"))
        #expect(await document.text(ofPage: 99).isEmpty)
    }

    @Test func aSearchFindsEveryPageInOrderAndPhrasesThatWrap() async throws {
        let document = try paper()
        var hits: [PDFSearchHit] = []
        for try await hit in document.search("QUICK brown") { hits.append(hit) }
        #expect(hits.map(\.page) == Array(1 ... 8))
        #expect(hits.map(\.id) == Array(0 ..< 8))
        #expect(hits.allSatisfy { String($0.snippet[$0.matchRangeInSnippet]) == "quick brown" })
        var wrapped: [PDFSearchHit] = []
        for try await hit in document.search("end of this line continues") { wrapped.append(hit) }
        #expect(wrapped.map(\.page) == [3])
        #expect(wrapped.first?.sourceRanges.count == 2)
        var none: [PDFSearchHit] = []
        for try await hit in document.search("zebra") { none.append(hit) }
        #expect(none.isEmpty)
    }

    @Test func theFactsAndTheCoverAreReadWithoutAReader() throws {
        let url = try folder.write(Fixture.paper().data(), named: "info.pdf")
        #expect(PDFBookInfo.read(fileAt: url) == PDFBookInfo(title: "Prototype Paper", author: "A. Author", pageCount: 8, isLocked: false))
        let cover = try #require(PDFBookInfo.cover(fileAt: url, maxPixelSize: 200))
        #expect(max(cover.width, cover.height) <= 400)
        #expect(cover.width < cover.height)
        let locked = try Fixture.locked(password: "secret", in: folder)
        #expect(PDFBookInfo.read(fileAt: locked)?.isLocked == true)
        #expect(PDFBookInfo.cover(fileAt: locked) == nil)
        #expect(PDFBookInfo.read(fileAt: try folder.write(Data("x".utf8), named: "x.pdf")) == nil)
    }
}
