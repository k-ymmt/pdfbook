import Foundation
import CoreGraphics

/// Writes a small PDF 1.4 by hand: pages of text lines in Helvetica (not embedded), with optional crop boxes, rotation,
/// links, an outline, a reading direction and a title. Enough structure for the tests, nothing a real file needs beyond.
struct MiniPDF {
    struct Link { var rect: CGRect; var toPage: Int?; var url: String? }
    /// An annotation of the file's own: a text mark ("Highlight", "Underline", "StrikeOut") over `quads`, or a note
    /// ("Text") at `rect`. Rectangles are in the media box (y up).
    struct Mark {
        var subtype: String
        var rect: CGRect
        var quads: [CGRect] = []
        var color: [CGFloat] = [1, 0.8, 0]
        var contents: String?
        var hidden = false
    }
    struct Page {
        var lines: [String]
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        var cropBox: CGRect?
        var rotate = 0
        var links: [Link] = []
        var marks: [Mark] = []
        /// The baseline of the first line (in the media box)
        var origin = CGPoint(x: 72, y: 720)
        var fontSize: CGFloat = 14
        var leading: CGFloat = 24
        /// Appended to the content stream as it is
        var extra = ""
    }
    struct Outline { var title: String; var page: Int; var children: [Outline] = [] }

    var pages: [Page]
    var title: String?
    var author: String?
    var outline: [Outline] = []
    /// "R2L" / "L2R" / nil
    var direction: String?
    /// The value of /PageLabels, when not nil
    var pageLabels: String?

    static func string(_ text: String) -> String {
        if text.unicodeScalars.allSatisfy({ $0.isASCII }) {
            var out = "("
            for c in text { if c == "(" || c == ")" || c == "\\" { out.append("\\") }; out.append(c) }
            return out + ")"
        }
        var hex = "<FEFF"
        for unit in text.utf16 { hex += String(format: "%04X", unit) }
        return hex + ">"
    }

    static func rect(_ r: CGRect) -> String {
        "[\(fmt(r.minX)) \(fmt(r.minY)) \(fmt(r.maxX)) \(fmt(r.maxY))]"
    }

    static func fmt(_ v: CGFloat) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }

    func data() -> Data {
        var objects: [Int: String] = [:]
        var streams: [Int: String] = [:]
        var next = 1
        func alloc() -> Int { defer { next += 1 }; return next }
        let catalog = alloc(), pagesID = alloc(), font = alloc()
        var pageIDs: [Int] = []
        for _ in pages { pageIDs.append(alloc()); _ = alloc() }
        objects[font] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
        for (index, page) in pages.enumerated() {
            let id = pageIDs[index], contentID = id + 1
            var content = "BT /F1 \(Self.fmt(page.fontSize)) Tf \(Self.fmt(page.leading)) TL \(Self.fmt(page.origin.x)) \(Self.fmt(page.origin.y)) Td\n"
            for line in page.lines { content += "\(Self.string(line)) Tj T*\n" }
            content += "ET\n" + page.extra
            streams[contentID] = content
            var dict = "<< /Type /Page /Parent \(pagesID) 0 R /MediaBox \(Self.rect(page.mediaBox)) /Resources << /Font << /F1 \(font) 0 R >> >> /Contents \(contentID) 0 R"
            if let crop = page.cropBox { dict += " /CropBox \(Self.rect(crop))" }
            if page.rotate != 0 { dict += " /Rotate \(page.rotate)" }
            if !page.links.isEmpty || !page.marks.isEmpty {
                dict += " /Annots ["
                for link in page.links {
                    dict += " << /Type /Annot /Subtype /Link /Rect \(Self.rect(link.rect)) /Border [0 0 0]"
                    if let to = link.toPage { dict += " /Dest [\(pageIDs[to]) 0 R /XYZ 0 792 0]" }
                    if let url = link.url { dict += " /A << /S /URI /URI \(Self.string(url)) >>" }
                    dict += " >>"
                }
                for mark in page.marks {
                    dict += " << /Type /Annot /Subtype /\(mark.subtype) /Rect \(Self.rect(mark.rect)) /F \(mark.hidden ? 2 : 4)"
                    dict += " /C [\(mark.color.map(Self.fmt).joined(separator: " "))]"
                    if !mark.quads.isEmpty {
                        // top left, top right, bottom left, bottom right of each quadrilateral
                        let points = mark.quads.flatMap { [$0.minX, $0.maxY, $0.maxX, $0.maxY, $0.minX, $0.minY, $0.maxX, $0.minY] }
                        dict += " /QuadPoints [\(points.map(Self.fmt).joined(separator: " "))]"
                    }
                    if mark.subtype == "Text" { dict += " /Name /Note" }
                    if let contents = mark.contents { dict += " /Contents \(Self.string(contents))" }
                    dict += " >>"
                }
                dict += " ]"
            }
            objects[id] = dict + " >>"
        }
        objects[pagesID] = "<< /Type /Pages /Count \(pages.count) /Kids [\(pageIDs.map { "\($0) 0 R" }.joined(separator: " "))] >>"
        var catalogDict = "<< /Type /Catalog /Pages \(pagesID) 0 R"
        if !outline.isEmpty {
            let root = alloc()
            // children are written right after their parent
            func build(_ items: [Outline], parent: Int) -> (first: Int, last: Int, count: Int) {
                let ids = items.map { _ in alloc() }
                var total = 0
                for (i, item) in items.enumerated() {
                    var dict = "<< /Title \(Self.string(item.title)) /Parent \(parent) 0 R /Dest [\(pageIDs[item.page]) 0 R /XYZ 0 792 0]"
                    if i > 0 { dict += " /Prev \(ids[i - 1]) 0 R" }
                    if i < items.count - 1 { dict += " /Next \(ids[i + 1]) 0 R" }
                    total += 1
                    if !item.children.isEmpty {
                        let sub = build(item.children, parent: ids[i])
                        dict += " /First \(sub.first) 0 R /Last \(sub.last) 0 R /Count \(sub.count)"
                        total += sub.count
                    }
                    objects[ids[i]] = dict + " >>"
                }
                return (ids.first!, ids.last!, total)
            }
            let top = build(outline, parent: root)
            objects[root] = "<< /Type /Outlines /First \(top.first) 0 R /Last \(top.last) 0 R /Count \(top.count) >>"
            catalogDict += " /Outlines \(root) 0 R"
        }
        if let direction { catalogDict += " /ViewerPreferences << /Direction /\(direction) >>" }
        if let pageLabels { catalogDict += " /PageLabels \(pageLabels)" }
        objects[catalog] = catalogDict + " >>"
        var info: Int?
        if title != nil || author != nil {
            let id = alloc()
            var dict = "<<"
            if let title { dict += " /Title \(Self.string(title))" }
            if let author { dict += " /Author \(Self.string(author))" }
            objects[id] = dict + " >>"
            info = id
        }
        var out = Data("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets: [Int: Int] = [:]
        for id in 1..<next {
            offsets[id] = out.count
            if let stream = streams[id] {
                let bytes = Data(stream.utf8)
                out.append(Data("\(id) 0 obj\n<< /Length \(bytes.count) >>\nstream\n".utf8))
                out.append(bytes)
                out.append(Data("\nendstream\nendobj\n".utf8))
            } else {
                out.append(Data("\(id) 0 obj\n\(objects[id]!)\nendobj\n".utf8))
            }
        }
        let xref = out.count
        var table = "xref\n0 \(next)\n0000000000 65535 f \n"
        for id in 1..<next { table += String(format: "%010d 00000 n \n", offsets[id]!) }
        table += "trailer\n<< /Size \(next) /Root \(catalog) 0 R" + (info.map { " /Info \($0) 0 R" } ?? "") + " >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(Data(table.utf8))
        return out
    }
}
