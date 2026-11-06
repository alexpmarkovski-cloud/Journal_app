// A table inside a page. Text systems have no table that works on both devices, so a table is
// an "attachment": one special character in the text that holds open a blank space. A small
// SwiftUI grid is then placed over that space. Each cell is its own plain text field.
//
// Apple's way to do this is an attachment "view provider", but in testing its view was never
// loaded and a placeholder icon appeared instead. So TableOverlays places the grids by hand.

import JournalCore
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformView = UIView
#else
import AppKit
typealias PlatformView = NSView
#endif

final class TableModel: ObservableObject {
    @Published var table: TableData
    var onChange: () -> Void = {}
    var onSizeChange: () -> Void = {}

    init(table: TableData) {
        self.table = table
    }

    func setCell(row: Int, column: Int, to text: String) {
        table.rows[row][column] = text
        onChange()
    }

    func addRow() {
        table.rows.append(Array(repeating: "", count: table.columnCount))
        changedShape()
    }

    func addColumn() {
        for row in table.rows.indices {
            table.rows[row].append("")
        }
        changedShape()
    }

    func removeLastRow() {
        guard table.rows.count > 1 else { return }
        table.rows.removeLast()
        changedShape()
    }

    func removeLastColumn() {
        guard table.columnCount > 1 else { return }
        for row in table.rows.indices {
            table.rows[row].removeLast()
        }
        changedShape()
    }

    private func changedShape() {
        onSizeChange()
        onChange()
    }
}

final class TableAttachment: NSTextAttachment {
    static let rowHeight: CGFloat = 36
    static let controlsHeight: CGFloat = 32

    let model: TableModel

    var table: TableData { model.table }

    init(table: TableData) {
        model = TableModel(table: table)
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = false
    }

    required init?(coder: NSCoder) {
        fatalError("Tables are saved in the page format, not archived")
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        CGRect(x: 0, y: 0, width: max(proposedLineFragment.width - 2, 100), height: height)
    }

    var height: CGFloat {
        gridHeight + Self.controlsHeight
    }

    // The extra 2 stops the outer borders from being clipped.
    var gridHeight: CGFloat {
        CGFloat(table.rows.count) * Self.rowHeight + 2
    }

    // A blank image, because with none the text system draws a placeholder icon.
    #if canImport(UIKit)
    override func image(
        for bounds: CGRect,
        attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> UIImage? {
        UIImage()
    }
    #else
    override func image(
        for bounds: CGRect,
        attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSImage? {
        NSImage(size: NSSize(width: 1, height: 1))
    }
    #endif
}

// Keeps a grid sitting exactly over each table's blank space. Runs after every layout.
@MainActor
final class TableOverlays {
    private struct Overlay {
        let view: PlatformView
        // On iPhone this keeps the SwiftUI view alive. On Mac the view does that itself.
        let owner: AnyObject?
    }

    private var overlays: [ObjectIdentifier: Overlay] = [:]

    func update(in textView: PlatformView, storage: NSTextStorage, layoutManager: NSTextLayoutManager?, origin: CGPoint) {
        guard let layoutManager, let content = layoutManager.textContentManager else { return }
        var seen = Set<ObjectIdentifier>()
        let documentStart = content.documentRange.location

        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? TableAttachment,
                  let location = content.location(documentStart, offsetBy: range.location),
                  let end = content.location(documentStart, offsetBy: NSMaxRange(range)),
                  let upToTable = NSTextRange(location: documentStart, end: end) else { return }

            // Text further up may only have estimated heights until it's laid out, and an
            // estimate would put the grid in the wrong place.
            layoutManager.ensureLayout(for: upToTable)
            guard let fragment = layoutManager.textLayoutFragment(for: location) else { return }

            let id = ObjectIdentifier(attachment)
            seen.insert(id)
            let overlay = overlays[id] ?? makeOverlay(for: attachment, in: textView)
            overlays[id] = overlay
            let frame = fragment.frameForTextAttachment(at: location)
            overlay.view.frame = CGRect(
                x: origin.x + fragment.layoutFragmentFrame.minX + frame.minX,
                y: origin.y + fragment.layoutFragmentFrame.minY + frame.minY,
                width: frame.width,
                height: attachment.height
            )
        }

        // Any grid left over belongs to a table that was deleted.
        for (id, overlay) in overlays where !seen.contains(id) {
            overlay.view.removeFromSuperview()
            overlays[id] = nil
        }
    }

    private func makeOverlay(for attachment: TableAttachment, in textView: PlatformView) -> Overlay {
        let content = TableBlockView(model: attachment.model)
        #if canImport(UIKit)
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        textView.addSubview(host.view)
        return Overlay(view: host.view, owner: host)
        #else
        let view = NSHostingView(rootView: content)
        textView.addSubview(view)
        return Overlay(view: view, owner: nil)
        #endif
    }
}

struct TableBlockView: View {
    @ObservedObject var model: TableModel

    private static let minimumColumnWidth: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    grid(columnWidth: columnWidth(available: geometry.size.width - 3))
                        .padding(1)
                }
            }
            .frame(height: CGFloat(model.table.rows.count) * TableAttachment.rowHeight + 2)
            controls
                .frame(height: TableAttachment.controlsHeight)
        }
    }

    private func columnWidth(available: CGFloat) -> CGFloat {
        let columns = max(CGFloat(model.table.columnCount), 1)
        return max(available / columns, Self.minimumColumnWidth)
    }

    private func grid(columnWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(model.table.rows.indices, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(model.table.rows[row].indices, id: \.self) { column in
                        cell(row: row, column: column)
                            .frame(width: columnWidth, height: TableAttachment.rowHeight)
                            .overlay(Rectangle().stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
                    }
                }
            }
        }
    }

    private func cell(row: Int, column: Int) -> some View {
        TextField("", text: Binding(
            get: { model.table.rows[safe: row]?[safe: column] ?? "" },
            set: { model.setCell(row: row, column: column, to: $0) }
        ))
        .textFieldStyle(.plain)
        .font(row == 0 ? Font.body.weight(.semibold) : Font.body)
        .padding(.horizontal, 8)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button("Add row", systemImage: "plus") { model.addRow() }
            Button("Add column", systemImage: "plus") { model.addColumn() }
            Menu("Remove", systemImage: "minus") {
                Button("Remove last row") { model.removeLastRow() }
                Button("Remove last column") { model.removeLastColumn() }
            }
            .fixedSize()
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
