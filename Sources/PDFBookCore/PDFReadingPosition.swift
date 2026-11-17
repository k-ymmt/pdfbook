import Foundation

/// Where a reader is in a PDF: a page and how far down it.
public struct PDFReadingPosition: Hashable, Sendable, Codable {
    /// The physical page, the first page being 1 (the number `PDFFragment` writes as `page=`).
    public var page: Int
    /// How much of the page lies above the top of the view, as a share of the page's displayed height (0 ..< 1).
    /// 0 where pages are shown one at a time.
    public var offset: Double
    /// How much of the whole document lies above the top of the view (0 ... 1).
    public var totalProgression: Double

    public init(page: Int, offset: Double = 0, totalProgression: Double = 0) {
        self.page = max(1, page)
        self.offset = offset.isFinite ? min(max(offset, 0), 0.999_999) : 0
        self.totalProgression = totalProgression.isFinite ? min(max(totalProgression, 0), 1) : 0
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(page: container.decode(Int.self, forKey: .page),
                      offset: container.decodeIfPresent(Double.self, forKey: .offset) ?? 0,
                      totalProgression: container.decodeIfPresent(Double.self, forKey: .totalProgression) ?? 0)
    }

    /// The position at the top of a page of a document with `pageCount` pages.
    public static func top(ofPage page: Int, pageCount: Int) -> PDFReadingPosition {
        PDFReadingPosition(page: page, offset: 0, totalProgression: pageCount > 0 ? Double(max(1, page) - 1) / Double(pageCount) : 0)
    }
}

/// Which way the pages of a book advance. A right-to-left book (Japanese vertical text, manga) turns its pages the
/// other way and puts the earlier page of a spread on the right.
public enum PDFPageDirection: String, Hashable, Sendable, Codable {
    case leftToRight
    case rightToLeft

    /// The value of `/ViewerPreferences /Direction` in the document catalog (`L2R` / `R2L`).
    public init?(viewerPreference name: String) {
        switch name {
        case "L2R": self = .leftToRight
        case "R2L": self = .rightToLeft
        default: return nil
        }
    }
}
