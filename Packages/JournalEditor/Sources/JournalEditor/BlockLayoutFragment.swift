// Draws what isn't text: bullets, numbers, checkboxes, quote bars, code backgrounds and dividers.
//
// Each paragraph is laid out as one "layout fragment". This subclass draws its decoration, then
// lets the text draw on top. Because a bullet is drawn and not typed, it can't be selected or
// deleted by accident, and it never ends up in the saved text.

import CoreText
import JournalCore

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

final class BlockLayoutFragment: NSTextLayoutFragment {
    static func decorates(_ kind: BlockKind) -> Bool {
        switch kind {
        case .bullet, .dash, .numbered, .checklist, .quote, .code, .divider: true
        default: false
        }
    }

    private var block: BlockInfo? {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 else { return nil }
        return EditorEngine.blockAttribute(paragraph.attributedString, at: 0)
    }

    private var firstLineFont: PlatformFont {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
              let font = paragraph.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont else {
            return PlatformFont.systemFont(ofSize: EditorStyle.bodySize)
        }
        return font
    }

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    // A paragraph's frame starts at its indent, but bullets sit left of that and code backgrounds
    // span the page. This allows drawing across the whole width.
    override var renderingSurfaceBounds: CGRect {
        let frame = layoutFragmentFrame
        return super.renderingSurfaceBounds.union(CGRect(x: -frame.minX, y: 0, width: containerWidth, height: frame.height))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let block {
            context.saveGState()
            // Decorations are measured from the page's left edge, not the paragraph's indent.
            let pageEdge = CGPoint(x: point.x - layoutFragmentFrame.minX, y: point.y)
            decorate(block, at: pageEdge, in: context)
            context.restoreGState()
        }
        super.draw(at: point, in: context)
    }

    private func decorate(_ block: BlockInfo, at point: CGPoint, in context: CGContext) {
        let height = layoutFragmentFrame.height
        let color = EditorStyle.secondaryColor
        let indent = EditorStyle.listIndent(for: block)

        switch block.contentKind {
        case .code:
            context.setFillColor(EditorStyle.textColor.withAlphaComponent(0.07).cgColor)
            context.fill(CGRect(x: point.x + indent, y: point.y, width: containerWidth - indent, height: height))
        case .quote:
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: point.x + indent + 2, y: point.y + 1, width: 3, height: height - 2))
        default:
            break
        }

        switch block.kind {
        case .divider:
            context.setFillColor(color.withAlphaComponent(0.5).cgColor)
            context.fill(CGRect(x: point.x, y: point.y + height / 2, width: containerWidth, height: 1))
        case .bullet, .dash, .numbered:
            drawMarker(for: block, at: point, in: context, color: color)
        case .checklist:
            drawCheckbox(for: block, at: point, in: context, color: color)
        default:
            break
        }
    }

    private var firstLineMidY: CGFloat {
        guard let line = textLineFragments.first else { return layoutFragmentFrame.height / 2 }
        return line.typographicBounds.midY
    }

    private func drawMarker(for block: BlockInfo, at point: CGPoint, in context: CGContext, color: PlatformColor) {
        let text = EditorStyle.marker(for: block)
        let font = PlatformFont.systemFont(ofSize: firstLineFont.pointSize)
        let marker = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: block.kind == .numbered ? color : EditorStyle.textColor,
        ])
        let size = marker.size()
        let origin = CGPoint(
            x: point.x + EditorStyle.listIndent(for: block) - size.width - 6,
            y: point.y + firstLineMidY - size.height / 2
        )
        withTextDrawing(in: context) { marker.draw(at: origin) }
    }

    private func drawCheckbox(for block: BlockInfo, at point: CGPoint, in context: CGContext, color: PlatformColor) {
        let box = BlockLayoutFragment.checkboxRect(for: block, firstLineMidY: firstLineMidY).offsetBy(dx: point.x, dy: point.y)
        let shape = CGPath(roundedRect: box, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
        context.addPath(shape)
        if block.isChecked {
            context.setFillColor(color.cgColor)
            context.fillPath()
            context.setStrokeColor(backgroundColor.cgColor)
            context.setLineWidth(1.8)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: box.minX + box.width * 0.24, y: box.minY + box.height * 0.52))
            context.addLine(to: CGPoint(x: box.minX + box.width * 0.43, y: box.minY + box.height * 0.72))
            context.addLine(to: CGPoint(x: box.minX + box.width * 0.77, y: box.minY + box.height * 0.3))
            context.strokePath()
        } else {
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1.3)
            context.strokePath()
        }
    }

    private var backgroundColor: PlatformColor {
        #if canImport(UIKit)
        .systemBackground
        #else
        .textBackgroundColor
        #endif
    }

    static func checkboxRect(for block: BlockInfo, firstLineMidY: CGFloat) -> CGRect {
        let size: CGFloat = 16
        return CGRect(x: EditorStyle.listIndent(for: block) - size - 7, y: firstLineMidY - size / 2, width: size, height: size)
    }

    // True if a point lands on this paragraph's checkbox. x is from the page's left edge, and y
    // is from the paragraph's top.
    func checkboxContains(_ point: CGPoint) -> Bool {
        guard let block, block.kind == .checklist else { return false }
        // A generous target, because a finger is bigger than the box.
        return BlockLayoutFragment.checkboxRect(for: block, firstLineMidY: firstLineMidY).insetBy(dx: -8, dy: -8).contains(point)
    }

    private func withTextDrawing(in context: CGContext, _ draw: () -> Void) {
        #if canImport(UIKit)
        UIGraphicsPushContext(context)
        draw()
        UIGraphicsPopContext()
        #else
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        #endif
    }
}
