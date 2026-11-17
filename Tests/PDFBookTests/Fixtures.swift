import CoreGraphics
import Foundation
import PDFKit

/// A temporary folder that is removed when the value goes away.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("pdfbook-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ data: Data, named name: String) throws -> URL {
        let file = url.appendingPathComponent(name)
        try data.write(to: file)
        return file
    }
}

enum Fixture {
    /// Eight pages of fourteen lines; an outline Introduction (page 1) / Methods (page 3) with Setup (page 4) below it /
    /// Results (page 6); on page 1 a link to page 5 and a link to a URL.
    static func paper(direction: String? = nil) -> MiniPDF {
        var pages = (1 ... 8).map { number in
            MiniPDF.Page(lines: ["Chapter page \(number): the quick brown fox."] + (2 ... 14).map { "Page \(number) line \($0): lorem ipsum dolor sit amet" })
        }
        pages[0].links = [.init(rect: CGRect(x: 72, y: 690, width: 200, height: 16), toPage: 4),
                          .init(rect: CGRect(x: 72, y: 666, width: 200, height: 16), url: "https://example.com/")]
        pages[2].lines[3] = "A phrase that wraps at the end of this"
        pages[2].lines[4] = "line continues here"
        return MiniPDF(pages: pages, title: "Prototype Paper", author: "A. Author",
                       outline: [.init(title: "Introduction", page: 0),
                                 .init(title: "Methods", page: 2, children: [.init(title: "Setup", page: 3)]),
                                 .init(title: "Results", page: 5)],
                       direction: direction)
    }

    /// The paper, protected with a user password.
    static func locked(password: String, in folder: TemporaryFolder) throws -> URL {
        let plain = try folder.write(paper().data(), named: "plain.pdf")
        let url = folder.url.appendingPathComponent("locked.pdf")
        guard let document = PDFDocument(url: plain),
              document.write(to: url, withOptions: [.userPasswordOption: password, .ownerPasswordOption: "owner-\(password)"])
        else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}
