import CoreGraphics
import Foundation
import PDFBookCore
import PDFKit

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A mark the application draws over the pages of a `PDFReaderSession`: a highlight, an underline, a line through
/// the text or a frame around it, at a place written as a `PDFFragment`.
///
/// Overlays live in memory only. They are drawn with PDFKit annotations that are added to the pages of the open
/// document and never saved: the file is not touched, and nothing else that reads it (the text, a search, a second
/// document on the same file) sees them.
nonisolated public struct PDFOverlay: Identifiable, Hashable, Sendable {
    public enum Style: Hashable, Sendable {
        /// The rectangles filled with the colour (a marker pen). Give the colour an alpha below 1.
        case highlight
        /// A line under each rectangle.
        case underline
        /// A line through each rectangle.
        case strikethrough
        /// A frame around each rectangle.
        case outline
    }

    /// A colour in sRGB, each component 0...1.
    public struct Color: Hashable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double
        public var alpha: Double

        public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
    }

    /// The application's name for the overlay: what a tap on it reports.
    public var id: String
    /// Where it is drawn: one mark per rectangle. A fragment that names a whole page draws nothing, and so do the
    /// parts on pages the document does not have.
    public var fragment: PDFFragment
    public var color: Color
    public var style: Style

    public init(id: String, fragment: PDFFragment, color: Color, style: Style = .highlight) {
        self.id = id
        self.fragment = fragment
        self.color = color
        self.style = style
    }
}

extension PDFOverlay.Color {
    #if canImport(UIKit)
    var platformColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
    #else
    var platformColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
    #endif
}

extension PDFOverlay {
    /// The width of the frame of an `outline`, in points of the page.
    static let outlineWidth: CGFloat = 1.5

    /// The PDFKit annotations that draw the overlay, with the page each belongs on. The text marks are one annotation
    /// per page with one quadrilateral per rectangle; a frame is one square annotation per rectangle.
    func annotations(in pdf: PDFDocument) -> [(page: PDFPage, annotation: PDFAnnotation)] {
        var result: [(page: PDFPage, annotation: PDFAnnotation)] = []
        for part in fragment.parts where !part.rects.isEmpty && part.page <= pdf.pageCount {
            guard let page = pdf.page(at: part.page - 1) else { continue }
            let geometry = PDFBookDocument.geometry(of: page)
            switch style {
            case .outline:
                for rect in part.rects {
                    let annotation = PDFAnnotation(bounds: geometry.page(rect.cgRect), forType: .square, withProperties: nil)
                    let border = PDFBorder()
                    border.lineWidth = Self.outlineWidth
                    annotation.border = border
                    annotation.color = color.platformColor
                    result.append((page, annotation))
                }
            case .highlight, .underline, .strikethrough:
                // The corners in the order PDFKit reads a quadrilateral (top left, top right, bottom left, bottom
                // right of the text as it is displayed), so that the line of an underline lies under the text on a
                // rotated page too. A rectangle taller than wide is a column of vertical text (the same rule as
                // `PDFTextStore.core(of:)`): its text runs down, and its "bottom" is the right side, where the side
                // line of vertical Japanese goes; the line of a strikethrough then runs down its middle
                let quads = part.rects.map { rect -> [CGPoint] in
                    let box = rect.cgRect
                    let corners = box.height > box.width
                        ? [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.minX, y: box.maxY),
                           CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)]
                        : [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                           CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
                    return corners.map(geometry.page)
                }
                let points = quads.flatMap { $0 }
                guard let first = points.first else { continue }
                var bounds = CGRect(origin: first, size: .zero)
                for point in points.dropFirst() { bounds = bounds.union(CGRect(origin: point, size: .zero)) }
                let subtype: PDFAnnotationSubtype = switch style {
                case .underline: .underline
                case .strikethrough: .strikeOut
                default: .highlight
                }
                let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
                // quadrilateral points are relative to the annotation's bounds
                annotation.quadrilateralPoints = points.map { point in
                    let relative = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
                    #if canImport(UIKit)
                    return NSValue(cgPoint: relative)
                    #else
                    return NSValue(point: relative)
                    #endif
                }
                annotation.color = color.platformColor
                result.append((page, annotation))
            }
        }
        return result
    }

    /// How far outside a rectangle a tap still counts as on it, in points of the page (a line of small print is a
    /// narrow target for a finger).
    static let hitSlop: CGFloat = 3

    /// The rectangles of `fragment` on a page that a point of that page is on (displayed-page coordinates); empty
    /// when the point is on none.
    static func rects(of fragment: PDFFragment, onPage page: Int, hitBy point: CGPoint) -> [CGRect] {
        let rects = fragment.parts.filter { $0.page == page }.flatMap(\.rects).map(\.cgRect)
        guard rects.contains(where: { $0.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point) }) else { return [] }
        return rects
    }
}
