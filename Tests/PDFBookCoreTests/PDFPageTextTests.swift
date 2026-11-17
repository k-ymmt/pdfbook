import CoreGraphics
import Foundation
import PDFBookCore
import Testing

/// Builds the lines PDFKit would report for a page string (lines separated by "\n").
private func lines(_ string: String, bounds: (Int, String) -> CGRect? = { _, _ in nil }) -> [PDFPageText.Line] {
    var found: [(String, NSRange)] = []
    let ns = string as NSString
    ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { text, range, _, _ in
        if let text { found.append((text, range)) }
    }
    return found.enumerated().map { index, line in .init(text: line.0, range: line.1, bounds: bounds(index, line.0)) }
}

@Suite struct PDFPageTextTests {
    @Test func linesAreJoinedByASpace() {
        let text = PDFPageText(lines: lines("The quick brown \nfox jumps over\nthe lazy dog."))
        #expect(text.text == "The quick brown fox jumps over the lazy dog.")
    }

    @Test func aPhraseThatWrapsIsFoundAndMapsToBothLines() throws {
        let page = "The quick brown \nfox jumps over\nthe lazy dog."
        let text = PDFPageText(lines: lines(page))
        let match = try #require(text.matches(of: "brown  FOX").first)
        #expect(String(text.text[match.range]) == "brown fox")
        #expect(match.sourceRanges.map { (page as NSString).substring(with: $0) } == ["brown", "fox"])
    }

    @Test func searchIgnoresCaseDiacriticsAndWidth() {
        let text = PDFPageText(lines: lines("Café ＡＢＣ résumé"))
        #expect(text.matches(of: "cafe").count == 1)
        #expect(text.matches(of: "abc").count == 1)
        #expect(text.matches(of: "RESUME").count == 1)
        #expect(text.matches(of: "   ").isEmpty)
        #expect(text.matches(of: "zebra").isEmpty)
    }

    @Test func everyMatchIsReportedInOrder() {
        let page = "one two one\ntwo one"
        let text = PDFPageText(lines: lines(page))
        let matches = text.matches(of: "one")
        #expect(matches.count == 3)
        #expect(matches.flatMap(\.sourceRanges).map(\.location) == [0, 8, 16])
    }

    @Test func japaneseLinesWrapWithoutASpace() throws {
        let page = "吾輩は猫であ\nる。名前はまだ無い。"
        let text = PDFPageText(lines: lines(page))
        #expect(text.text == "吾輩は猫である。名前はまだ無い。")
        let match = try #require(text.matches(of: "猫である").first)
        #expect(match.sourceRanges.map { (page as NSString).substring(with: $0) } == ["猫であ", "る"])
    }

    @Test func verticalColumnsAreJoinedAndReadFromTheRight() throws {
        // PDFKit reports vertical text one character per line, the left column first. Two columns: "吾輩は" on the right,
        // "猫です" on the left.
        let page = "猫\nで\nす\n吾\n輩\nは"
        let text = PDFPageText(lines: lines(page) { index, _ in
            let column = index / 3, row = index % 3
            return CGRect(x: 100 + Double(column) * 30, y: 72 + Double(row) * 16, width: 16, height: 16)
        })
        #expect(text.text == "吾輩は猫です")
        let match = try #require(text.matches(of: "は猫").first)
        #expect(match.sourceRanges.map { (page as NSString).substring(with: $0) } == ["は", "猫"])
    }

    @Test func tiersOfVerticalTextAreEachReadFromTheRight() {
        // upper tier: columns "ab" (left) and "cd" (right); lower tier: "ef" (left), "gh" (right)
        let page = "あ\nい\nう\nえ\nか\nき\nく\nけ"
        let text = PDFPageText(lines: lines(page) { index, _ in
            let column = (index / 2) % 2, tier = index / 4, row = index % 2
            return CGRect(x: 100 + Double(column) * 30, y: 72 + Double(tier) * 200 + Double(row) * 16, width: 16, height: 16)
        })
        #expect(text.text == "うえあいくけかき")
    }

    @Test func singleCharactersThatAreNotStackedStayLines() {
        let text = PDFPageText(lines: lines("A\nB") { index, _ in CGRect(x: 100 + Double(index) * 200, y: 72, width: 10, height: 12) })
        #expect(text.text == "A B")
    }

    @Test func theSnippetCarriesTheTextAroundTheMatch() throws {
        let text = PDFPageText(lines: lines("alpha beta gamma delta epsilon"))
        let match = try #require(text.matches(of: "gamma").first)
        let snippet = text.snippet(around: match.range, before: 5, after: 6)
        #expect(snippet.text == "beta gamma delta")
        #expect(String(snippet.text[snippet.match]) == "gamma")
        let whole = text.snippet(around: match.range)
        #expect(whole.text == "alpha beta gamma delta epsilon")
        #expect(String(whole.text[whole.match]) == "gamma")
    }

    @Test func theExcerptIsTheStartOfThePage() {
        #expect(PDFPageText(lines: lines("Chapter one\nIt was a dark night")).excerpt(maxLength: 14) == "Chapter one It")
        #expect(PDFPageText(lines: []).excerpt().isEmpty)
        #expect(PDFPageText(lines: lines("  \n")).isEmpty)
    }

    @Test func selectionLinesAreJoinedTheSameWay() {
        #expect(PDFPageText.joined(["brown ", "fox"]) == "brown fox")
        #expect(PDFPageText.joined(["猫", "で", "す"]) == "猫です")
        #expect(PDFPageText.joined(["", " "]) == "")
    }
}

@Suite struct PDFOutlineIndexTests {
    static let index = PDFOutlineIndex(entries: [
        .init(title: "Introduction", page: 2),
        .init(title: "Methods", page: 4, top: 72),
        .init(title: "Setup", page: 4, top: 400),
        .init(title: "Results", page: 6),
    ])

    @Test func aPlaceBelongsToTheLastEntryBeforeIt() {
        #expect(Self.index.entry(atPage: 1) == nil)
        #expect(Self.index.entry(atPage: 2)?.entry.title == "Introduction")
        #expect(Self.index.entry(atPage: 3, top: 500)?.index == 0)
        #expect(Self.index.entry(atPage: 4, top: 10)?.entry.title == "Introduction")
        #expect(Self.index.entry(atPage: 4, top: 72)?.entry.title == "Methods")
        #expect(Self.index.entry(atPage: 4, top: 600)?.index == 2)
        #expect(Self.index.entry(atPage: 99)?.entry.title == "Results")
    }

    @Test func aWholePageBelongsToTheLastEntryThatStartsOnIt() {
        #expect(Self.index.entry(atPage: 4)?.entry.title == "Setup")
        #expect(Self.index.entry(at: PDFFragment(page: 4))?.entry.title == "Setup")
        #expect(Self.index.entry(at: PDFFragment("page=4&highlight=72,200,100,114")!)?.entry.title == "Methods")
    }

    @Test func entriesOutOfPageOrderKeepTheirDocumentNumber() {
        let index = PDFOutlineIndex(entries: [.init(title: "Appendix", page: 9), .init(title: "Body", page: 2)])
        #expect(index.entry(atPage: 5)?.index == 1)
        #expect(index.entry(atPage: 9)?.index == 0)
    }

    @Test func positionsClampTheirValues() throws {
        let position = PDFReadingPosition(page: 0, offset: 1.5, totalProgression: -.infinity)
        #expect(position.page == 1 && position.offset < 1 && position.totalProgression == 0)
        #expect(PDFReadingPosition.top(ofPage: 3, pageCount: 8).totalProgression == 0.25)
        let decoded = try JSONDecoder().decode(PDFReadingPosition.self, from: Data(#"{"page":5}"#.utf8))
        #expect(decoded == PDFReadingPosition(page: 5))
        #expect(PDFPageDirection(viewerPreference: "R2L") == .rightToLeft)
        #expect(PDFPageDirection(viewerPreference: "L2R") == .leftToRight)
        #expect(PDFPageDirection(viewerPreference: "x") == nil)
    }
}
