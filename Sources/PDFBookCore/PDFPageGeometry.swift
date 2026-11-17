import CoreGraphics

/// How one page is displayed: its crop box (in the PDF's user space, origin bottom-left, y up) and its rotation.
/// Converts between that user space ("page coordinates", what PDFKit's `PDFPage` and `PDFSelection` use) and the
/// coordinates of `PDFFragment`: points from the top-left corner of the page as displayed, x right, y down.
public struct PDFPageGeometry: Hashable, Sendable {
    /// The crop box in user space, before rotation.
    public var cropBox: CGRect
    /// Clockwise rotation of the displayed page: 0, 90, 180 or 270.
    public var rotation: Int

    /// - Parameter rotation: any multiple of 90 (negative values and values past 360 are normalized; anything else
    ///   counts as the nearest lower multiple of 90).
    public init(cropBox: CGRect, rotation: Int) {
        self.cropBox = cropBox.standardized
        let turns = Int((Double(rotation) / 90).rounded(.down))
        self.rotation = ((turns % 4) + 4) % 4 * 90
    }

    /// The size of the page as displayed.
    public var displayedSize: CGSize {
        rotation % 180 == 0 ? cropBox.size : CGSize(width: cropBox.height, height: cropBox.width)
    }

    /// Page coordinates → displayed coordinates.
    public func displayed(_ point: CGPoint) -> CGPoint {
        let c = cropBox
        switch rotation {
        case 90: return CGPoint(x: point.y - c.minY, y: point.x - c.minX)
        case 180: return CGPoint(x: c.maxX - point.x, y: point.y - c.minY)
        case 270: return CGPoint(x: c.maxY - point.y, y: c.maxX - point.x)
        default: return CGPoint(x: point.x - c.minX, y: c.maxY - point.y)
        }
    }

    /// Displayed coordinates → page coordinates.
    public func page(_ point: CGPoint) -> CGPoint {
        let c = cropBox
        switch rotation {
        case 90: return CGPoint(x: point.y + c.minX, y: point.x + c.minY)
        case 180: return CGPoint(x: c.maxX - point.x, y: point.y + c.minY)
        case 270: return CGPoint(x: c.maxX - point.y, y: c.maxY - point.x)
        default: return CGPoint(x: point.x + c.minX, y: c.maxY - point.y)
        }
    }

    public func displayed(_ rect: CGRect) -> CGRect {
        Self.rect(displayed(CGPoint(x: rect.minX, y: rect.minY)), displayed(CGPoint(x: rect.maxX, y: rect.maxY)))
    }

    public func page(_ rect: CGRect) -> CGRect {
        Self.rect(page(CGPoint(x: rect.minX, y: rect.minY)), page(CGPoint(x: rect.maxX, y: rect.maxY)))
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
