import CoreGraphics
import Foundation
@testable import PDFBookCore
import Testing

@Suite struct PDFFragmentTests {
    @Test func aPageAloneIsAPage() throws {
        let fragment = try #require(PDFFragment("page=12"))
        #expect(fragment.page == 12)
        #expect(fragment.isPage)
        #expect(fragment.description == "page=12")
        #expect(fragment == PDFFragment(page: 12))
    }

    @Test func rectanglesBelongToThePageBeforeThem() throws {
        let fragment = try #require(PDFFragment("page=12&highlight=72,523,96,110&highlight=72,410,110,124"))
        #expect(!fragment.isPage)
        #expect(fragment.parts == [.init(page: 12, rects: [.init(left: 72, right: 523, top: 96, bottom: 110),
                                                         .init(left: 72, right: 410, top: 110, bottom: 124)])])
        #expect(fragment.description == "page=12&highlight=72,523,96,110&highlight=72,410,110,124")
    }

    @Test func aLaterPageSwitchesThePage() throws {
        let text = "page=12&highlight=72,523,700,714&page=13&highlight=72,300,72,86"
        let fragment = try #require(PDFFragment(text))
        #expect(fragment.parts.map(\.page) == [12, 13])
        #expect(fragment.page == 12)
        #expect(fragment.description == text)
    }

    @Test func unknownParametersAreSkippedAndNeverWritten() throws {
        let fragment = try #require(PDFFragment("page=3&zoom=200&highlight=1,2,3,4&color=pink&style=underline"))
        #expect(fragment.description == "page=3&highlight=1,2,3,4")
        #expect(PDFFragment("zoom=200&page=3")?.description == "page=3")
    }

    @Test func parametersMayBeSeparatedByANumberSignAndValuesMayBePercentEncoded() throws {
        #expect(PDFFragment("page=3#highlight=1,2,3,4")?.description == "page=3&highlight=1,2,3,4")
        #expect(PDFFragment("page=3&highlight=1%2C2%2C3%2C4")?.description == "page=3&highlight=1,2,3,4")
    }

    @Test func withoutRectanglesTheLastPageWins() {
        #expect(PDFFragment("page=3&page=5") == PDFFragment(page: 5))
    }

    @Test func aPageWithoutRectanglesInsideARangeIsDropped() {
        #expect(PDFFragment("page=3&page=5&highlight=1,2,3,4")?.description == "page=5&highlight=1,2,3,4")
        #expect(PDFFragment("page=5&highlight=1,2,3,4&page=9")?.description == "page=5&highlight=1,2,3,4")
    }

    @Test func rectanglesOfTheSamePageAreJoined() {
        #expect(PDFFragment("page=5&highlight=1,2,3,4&page=5&highlight=5,6,7,8")?.description == "page=5&highlight=1,2,3,4&highlight=5,6,7,8")
    }

    @Test(arguments: [
        "", "highlight=1,2,3,4", "color=pink", "page=0", "page=-1", "page=1.5", "page=abc", "page=", "page=١٢",
        "page=2&highlight=1,2,3", "page=2&highlight=1,2,3,4,5", "page=2&highlight=a,b,c,d", "page=2&highlight=5,1,3,4",
        "page=2&highlight=1,2,9,4", "page=2&highlight=nan,2,3,4", "page=2&highlight=1e2,200,3,4", "highlight=1,2,3,4&page=2",
        "epubcfi(/6/4!/4/2)",
    ])
    func whatIsNotAPlaceIsRefused(_ text: String) {
        #expect(PDFFragment(text) == nil)
    }

    @Test func realNumbersAreReadAndWrittenShort() throws {
        let fragment = try #require(PDFFragment("page=2&highlight=72.5,523.25,96,110.10"))
        #expect(fragment.parts[0].rects[0].left == 72.5)
        #expect(fragment.description == "page=2&highlight=72.5,523.25,96,110.1")
    }

    @Test func aTinyNegativeNumberIsWrittenAsZero() throws {
        #expect(PDFFragment.Rect(left: -0.001, right: 10, top: -0.004, bottom: 20).written == "0,10,0,20")
        let fragment = try #require(PDFFragment(parts: [.init(page: 1, rects: [.init(left: -0.001, right: 10, top: 0, bottom: 20)])]))
        #expect(fragment.description == "page=1&highlight=0,10,0,20")
    }

    @Test func lineRectanglesAreRoundedOutward() throws {
        let fragment = try #require(PDFFragment(page: 4, lineRects: [CGRect(x: 72.4, y: 96.6, width: 450.3, height: 13.2)]))
        #expect(fragment.description == "page=4&highlight=72,523,96,110")
        #expect(fragment.parts[0].rects[0].cgRect == CGRect(x: 72, y: 96, width: 451, height: 14))
        #expect(PDFFragment(page: 4, lineRects: []) == nil)
        #expect(PDFFragment(parts: [.init(page: 0, rects: [.init(left: 1, right: 2, top: 3, bottom: 4)])]) == nil)
    }

    @Test func whatIsWrittenReadsBackTheSame() throws {
        let fragment = try #require(PDFFragment(parts: [
            .init(page: 7, rects: [.init(left: 10, right: 20, top: 30, bottom: 40), .init(left: 10, right: 15, top: 40, bottom: 50)]),
            .init(page: 8, rects: [.init(left: 0, right: 612, top: 0, bottom: 12)]),
        ]))
        #expect(PDFFragment(fragment.description) == fragment)
    }

    @Test func placesAreOrderedByPageThenFromTheTopThenFromTheLeft() throws {
        let page3 = PDFFragment(page: 3)
        let top = try #require(PDFFragment("page=3&highlight=72,200,96,110"))
        let topRight = try #require(PDFFragment("page=3&highlight=300,400,96,110"))
        let lower = try #require(PDFFragment("page=3&highlight=72,200,300,314"))
        let page4 = PDFFragment(page: 4)
        let order = [page3, top, topRight, lower, page4]
        for (index, earlier) in order.enumerated() {
            for later in order[(index + 1)...] {
                #expect(earlier.precedes(later))
                #expect(!later.precedes(earlier))
            }
            #expect(!earlier.precedes(earlier))
        }
    }
}

@Suite struct PDFPageGeometryTests {
    static let crop = CGRect(x: 36, y: 100, width: 500, height: 660)

    @Test(arguments: [0, 90, 180, 270])
    func convertingThereAndBackIsTheIdentity(_ rotation: Int) {
        let geometry = PDFPageGeometry(cropBox: Self.crop, rotation: rotation)
        for point in [CGPoint(x: 36, y: 100), CGPoint(x: 536, y: 760), CGPoint(x: 100, y: 300)] {
            let back = geometry.page(geometry.displayed(point))
            #expect(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9)
        }
        let rect = CGRect(x: 80, y: 500, width: 200, height: 14)
        let back = geometry.page(geometry.displayed(rect))
        #expect(abs(back.minX - rect.minX) < 1e-9 && abs(back.minY - rect.minY) < 1e-9 && abs(back.width - rect.width) < 1e-9 && abs(back.height - rect.height) < 1e-9)
    }

    @Test func theDisplayedOriginIsTheTopLeftCornerOfTheRotatedCropBox() {
        // the corner of the crop box that is shown at the top left, per rotation
        #expect(PDFPageGeometry(cropBox: Self.crop, rotation: 0).displayed(CGPoint(x: 36, y: 760)) == .zero)
        #expect(PDFPageGeometry(cropBox: Self.crop, rotation: 90).displayed(CGPoint(x: 36, y: 100)) == .zero)
        #expect(PDFPageGeometry(cropBox: Self.crop, rotation: 180).displayed(CGPoint(x: 536, y: 100)) == .zero)
        #expect(PDFPageGeometry(cropBox: Self.crop, rotation: 270).displayed(CGPoint(x: 536, y: 760)) == .zero)
    }

    @Test func aRotatedPageSwapsItsSides() {
        #expect(PDFPageGeometry(cropBox: Self.crop, rotation: 0).displayedSize == CGSize(width: 500, height: 660))
        #expect(PDFPageGeometry(cropBox: Self.crop, rotation: 90).displayedSize == CGSize(width: 660, height: 500))
        #expect(PDFPageGeometry(cropBox: Self.crop, rotation: -90).rotation == 270)
        #expect(PDFPageGeometry(cropBox: Self.crop, rotation: 450).rotation == 90)
    }

    @Test func aLineOfAnUprightPageKeepsItsWidthAndIsMeasuredFromTheTop() {
        let geometry = PDFPageGeometry(cropBox: Self.crop, rotation: 0)
        let displayed = geometry.displayed(CGRect(x: 72, y: 716, width: 381, height: 15))
        #expect(displayed == CGRect(x: 36, y: 29, width: 381, height: 15))
    }

    @Test func aLineOfAPageTurnedAQuarterRunsDownTheDisplayedPage() {
        let geometry = PDFPageGeometry(cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 90)
        // a horizontal line near the top of the unrotated page: after a clockwise quarter turn it runs down the right edge
        let displayed = geometry.displayed(CGRect(x: 72, y: 716, width: 381, height: 15))
        #expect(displayed == CGRect(x: 716, y: 72, width: 15, height: 381))
    }
}

@Suite struct PDFLineRectsTests {
    @Test func linesOfHorizontalTextStayApart() {
        let lines = [CGRect(x: 72, y: 96, width: 450, height: 14), CGRect(x: 72, y: 110, width: 300, height: 14)]
        #expect(PDFLineRects.merged(lines) == lines)
    }

    @Test func piecesOfOneLineAreJoined() {
        let pieces = [CGRect(x: 72, y: 96, width: 100, height: 14), CGRect(x: 172, y: 96, width: 80, height: 14), CGRect(x: 254, y: 97, width: 40, height: 13)]
        #expect(PDFLineRects.merged(pieces) == [CGRect(x: 72, y: 96, width: 222, height: 14)])
    }

    @Test func twoColumnsOfHorizontalTextOnTheSameLineStayApart() {
        let lines = [CGRect(x: 72, y: 96, width: 170, height: 14), CGRect(x: 320, y: 96, width: 170, height: 14)]
        #expect(PDFLineRects.merged(lines) == lines)
    }

    @Test func theCharactersOfAVerticalColumnBecomeOneRectangle() {
        // two columns of four characters, the right one first (the order they are read in)
        let right = (0 ..< 4).map { CGRect(x: 500, y: 72 + Double($0) * 16.5, width: 16, height: 16) }
        let left = (0 ..< 4).map { CGRect(x: 470, y: 72 + Double($0) * 16.5, width: 16, height: 16) }
        #expect(PDFLineRects.merged(right + left) == [CGRect(x: 500, y: 72, width: 16, height: 65.5), CGRect(x: 470, y: 72, width: 16, height: 65.5)])
    }

    @Test func emptyRectanglesAreDropped() {
        #expect(PDFLineRects.merged([.zero, CGRect(x: 1, y: 1, width: 5, height: 5)]) == [CGRect(x: 1, y: 1, width: 5, height: 5)])
    }
}
