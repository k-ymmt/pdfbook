# pdfbook

Reading PDFs as books on iOS 27+ and macOS 26+, written in Swift 6 on top of PDFKit.

PDFKit draws the pages. The library adds what a reading app needs around it:

- Places written as URL fragments, `page=12` and `page=12&highlight=72,523,96,110&highlight=…` (the vocabulary of
  RFC 8118 §3, extended by repetition), with the conversion between a page's own coordinates and the coordinates of
  the page as it is displayed (crop box and rotation applied).
- A reading position (page, how far down the page, share of the whole document) that survives a new size, a change of
  layout and a restart.
- A reader session with events: position changes, moves with their cause (page turn, jump, link, scroll), scrolling,
  taps that did nothing else, selection changes, links that lead outside.
- Layouts: one vertical strip of pages, or one page / one spread at a time; right-to-left books.
- The text of a page in reading order: lines that wrap are joined, the columns of vertical Japanese text are put
  together and read from the right. Search over it finds phrases across line breaks.
- The outline with page numbers, the reading direction the file asks for, password-protected files, the title and a
  cover image without opening a reader.

It depends on Apple frameworks only and never writes to the PDF.

## Installation

Add the package with Swift Package Manager.

```swift
// Package.swift
dependencies: [
    .package(url: "<repository URL>", revision: "<commit>"),
    // or, for a local checkout: .package(path: "../pdfbook"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "PDFBook", package: "pdfbook")]),
]
```

| Product | Contents | Imports |
|---|---|---|
| `PDFBookCore` | `PDFFragment`, `PDFPageGeometry`, `PDFLineRects`, `PDFPageText`, `PDFOutlineIndex`, `PDFReadingPosition` | Foundation, CoreGraphics |
| `PDFBook` | `PDFBookDocument`, `PDFBookInfo`, `PDFReaderSession`, `PDFReaderView`; re-exports `PDFBookCore` | + PDFKit, SwiftUI |

Code that only reads or writes links to places in a PDF (an index, a command-line tool) can depend on `PDFBookCore`
alone.

## Showing a PDF

```swift
import PDFBook
import SwiftUI

struct Reader: View {
    @State private var session: PDFReaderSession

    init(url: URL) throws {
        let document = try PDFBookDocument(url: url)
        _session = State(initialValue: PDFReaderSession(document: document, layout: PDFReaderLayout(mode: .scroll)))
    }

    var body: some View {
        PDFReaderView(session: session)
            .onAppear {
                session.onEvent = { event in
                    if case .positionChanged(let position) = event { save(position) }
                }
            }
    }
}
```

- `PDFReaderSession.position` is `Codable`; pass a stored one as `initialPosition` to continue where the reader stopped.
- `session.layout` switches between `.scroll` and `.pages`, one page and two, left-to-right and right-to-left, while the
  reader stays at the same place. The zoom starts fitted to the view; the reader can change it, and it is not stored.
- `go(toPage:)`, `go(to:)` (a position, a `PDFFragment`, an outline entry), `show(_:)` (a search hit) move the reader and
  report a `.navigated` event with the cause `.jump` when the reader ends up somewhere else.
- In the paged layout a tap on the left or right quarter of the view turns the page (the other way round in a
  right-to-left book), as do the arrow keys, Space and Page Up / Down on macOS.
- `PDFReaderView.contentInsets(top:bottom:)` tells the scroll layout how much of the view is covered by bars.
- `PDFReaderView.selectionActions(_:)` replaces the system's menu of a text selection; an action receives the selection
  as a `PDFSelectedText` (its fragment and its text). `session.selectedText` reads the same at any time.

### Password-protected files

```swift
let document = try PDFBookDocument(url: url)
if document.isLocked {
    guard await document.unlock(password: entered) else { /* wrong password */ return }
}
```

A locked document has no title, outline or pages until it is unlocked. The library does not store passwords.

### Files that cannot be opened

`PDFBookDocument(url:)` throws `OpenError.unreadable` for a file that is not a PDF, is damaged or cut short, or is empty,
and `.noPages` for a PDF without pages.

A document reads its file from disk as needed. When the file is replaced while it is open by the usual atomic save (a
new file renamed over the old one), the open document keeps reading the old file; open it again to read the new one.

## Places as fragments

```swift
let page = PDFFragment(page: 12)                      // "page=12"
let range = PDFFragment("page=12&highlight=72,523,96,110&highlight=72,410,110,124")
range?.parts[0].rects[0].top                          // 96
```

- `page=<n>`: the physical page, the first page being 1.
- `highlight=<left>,<right>,<top>,<bottom>`: a rectangle on the page named by the `page=` before it, in points from the
  top-left corner of the page as displayed, y down. One rectangle per line of text, in reading order.
- A later `page=` switches the page, so a range can run over a page break:
  `page=12&highlight=…&page=13&highlight=…`.
- Parameters the type does not know (`zoom=`, an application's own) are skipped when reading and never written.
  Rectangles are written as integers rounded outward; real numbers are read.

`PDFPageGeometry(cropBox:rotation:)` converts between these coordinates and PDFKit's page coordinates
(`displayed(_:)`, `page(_:)`). `PDFLineRects.merged(_:)` turns the per-character rectangles PDFKit reports for vertical
text into one rectangle per column.

## Text, search, outline

```swift
for try await hit in document.search("reading order") {
    print(hit.page, hit.snippet)
}
await session.show(hit)                               // go there and mark the match

let excerpt = await document.excerpt(ofPage: 12)      // the first characters of the page
document.outline                                      // [PDFOutlineItem]: label, page, children
document.outlineIndex.entry(at: fragment)             // the outline entry a place belongs to
document.pageDirection                                // /ViewerPreferences /Direction, when the file has it
```

Text is read from a second `PDFDocument` on the same file inside an actor, so a search does not block the main actor.
A page without a text layer (a scan) has no text: its excerpt is empty and nothing is found on it.

## A title and a cover without a reader

```swift
let info = PDFBookInfo.read(fileAt: url)              // title, author, pageCount, isLocked
let cover = PDFBookInfo.cover(fileAt: url, maxPixelSize: 600)
```

Both can be called from any thread, and from a process with little memory (an app extension): the cover uses PDFKit's
page thumbnail, which stays within a few megabytes even when the first page is one large image.

## What it does not do

- It does not write annotations into the PDF or read the ones in it.
- It does not draw highlights yet; a place is only something to go to.
- No OCR: a scan without a text layer has no text to select or search.

## Tests

```bash
swift test
```

The tests build their PDFs by hand (`Tests/PDFBookTests/MiniPDF.swift`), so no fixture files are checked in.
