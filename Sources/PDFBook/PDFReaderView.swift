import SwiftUI

/// Shows the PDF of a `PDFReaderSession`.
///
/// ```swift
/// let document = try PDFBookDocument(url: url)
/// let session = PDFReaderSession(document: document)
/// session.onEvent = { event in … }
/// PDFReaderView(session: session)
/// ```
///
/// A session has one view: show it in one place at a time.
public struct PDFReaderView: View {
    private let session: PDFReaderSession
    private var actions: [PDFSelectionAction] = []
    private var insets: (top: CGFloat, bottom: CGFloat) = (0, 0)

    public init(session: PDFReaderSession) {
        self.session = session
    }

    /// The menu of a text selection. With any action, the system's items (Copy, Look Up, …) are not shown.
    public func selectionActions(_ actions: [PDFSelectionAction]) -> PDFReaderView {
        var view = self
        view.actions = actions
        return view
    }

    /// In the scroll layout, how much of the view's top and bottom is covered by something else (bars over a page that
    /// fills the screen): the document starts and ends clear of it, and positions are measured from below the top one.
    public func contentInsets(top: CGFloat, bottom: CGFloat) -> PDFReaderView {
        var view = self
        view.insets = (max(0, top), max(0, bottom))
        return view
    }

    public var body: some View {
        Representable(session: session, actions: actions, top: insets.top, bottom: insets.bottom)
            // another session is another view
            .id(ObjectIdentifier(session))
    }
}

#if canImport(UIKit)

private struct Representable: UIViewRepresentable {
    let session: PDFReaderSession
    let actions: [PDFSelectionAction]
    let top: CGFloat
    let bottom: CGFloat

    func makeUIView(context: Context) -> ReaderPDFView {
        session.view
    }

    func updateUIView(_ view: ReaderPDFView, context: Context) {
        view.selectionActions = actions
        session.setContentInsets(top: top, bottom: bottom)
    }
}

#else

private struct Representable: NSViewRepresentable {
    let session: PDFReaderSession
    let actions: [PDFSelectionAction]
    let top: CGFloat
    let bottom: CGFloat

    func makeNSView(context: Context) -> ReaderPDFView {
        session.view
    }

    func updateNSView(_ view: ReaderPDFView, context: Context) {
        view.selectionActions = actions
        session.setContentInsets(top: top, bottom: bottom)
    }
}

#endif
