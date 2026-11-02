import NotesCore
import SwiftUI
import UniformTypeIdentifiers

enum TransferMode: String {
    case export
    case `import`
}

struct TransferSheet: View {
    let pageId: String

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var preferences: Preferences
    @State private var mode: TransferMode
    @State private var document: ImportedDocument?
    @State private var documentName: String?
    @State private var importFailure: String?
    @State private var isPicking = false
    @State private var exportSelection: Set<CellPosition> = []
    @State private var importSelection: Set<CellPosition> = []
    @State private var painting: (isSelecting: Bool, last: CellPosition)?
    @State private var images: [CellPosition: UIImage] = [:]
    @State private var renderedKey = ""
    @State private var importRevision = 0
    @State private var isExporting = false

    private static let contentShare: CGFloat = 0.75
    private static let largestCellWidth: CGFloat = 150
    private static let rowLabelWidth: CGFloat = 36
    private static let spacing: CGFloat = 10
    private static let cellShape = Squircle(radius: 8)

    init(pageId: String, initialMode: TransferMode) {
        self.pageId = pageId
        _mode = State(initialValue: initialMode)
    }

    private var page: Page? {
        library.page(pageId)
    }

    private var isEditable: Bool {
        !library.isReadOnly(pageId)
    }

    private var selection: Set<CellPosition> {
        mode == .export ? exportSelection : importSelection
    }

    private var ordered: [CellPosition] {
        selection.sorted(by: CellPosition.readingOrder)
    }

    private var capacity: Int {
        mode == .export ? Int.max : document?.pages.count ?? 0
    }

    private var extent: Extent {
        let current = page?.extent ?? .single
        if mode == .import, let document {
            let added = (document.pages.count + current.columns - 1) / current.columns
            return Extent(columns: current.columns, rows: current.rows + added)
        }
        return current
    }

    private var previewPage: Page? {
        guard var shown = page else { return nil }
        guard mode == .import, let document else { return shown }
        let now = Date()
        shown.extent = extent
        shown.elements += ordered.prefix(document.pages.count).enumerated().map { index, cell in
            library.importElement(asset: document.asset, index: index, size: document.pages[index], now: now, row: cell.row, column: cell.column)
        }
        return shown
    }

    var body: some View {
        let _ = library.revision
        GeometryReader { proxy in
            ScrollView {
                module(width: proxy.size.width * Self.contentShare)
                    .frame(width: proxy.size.width * Self.contentShare)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                    .background(Color.clear.contentShape(Rectangle()).onTapGesture { navigator.show(nil) })
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            do {
                document = try ImportImages.importDocument(from: url, into: library)
                documentName = url.lastPathComponent
                importFailure = nil
                placeAfterNote()
            } catch {
                document = nil
                importSelection = []
                importFailure = ImportError.message(for: error)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ImportImages.didRender)) { _ in
            importRevision += 1
        }
        .onAppear {
            selectAll()
            if mode == .import {
                isPicking = true
            }
        }
    }

    private func module(width: CGFloat) -> some View {
        let cells = ordered
        let isImport = mode == .import
        return SettingsModule(label: page.map { library.noteTitle($0) } ?? "Note", detail: isImport ? "Each number is the PDF page placed in that cell" : "Each number is a page of the exported PDF") {
            HStack(spacing: 18) {
                Segmented(options: [SegmentOption(value: TransferMode.export, title: "Export"), SegmentOption(value: TransferMode.import, title: "Import")], selected: mode) { picked in
                    guard picked != .import || isEditable else { return }
                    withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
                        mode = picked
                    }
                    if picked == .import && document == nil {
                        isPicking = true
                    }
                }
                HStack(spacing: 12) {
                    LinkButton(glyph: "check", title: "All", tint: Palette.view) {
                        if mode == .export {
                            selectAll()
                        } else {
                            placeAfterNote()
                        }
                    }
                    LinkButton(glyph: "close", title: "None", tint: Palette.view) {
                        if mode == .export {
                            exportSelection = []
                        } else {
                            importSelection = []
                        }
                    }
                }
            }
            if isImport {
                fileChoice
                    .transition(.popTogether)
            }
            grid(width: width - 36)
            SlabButton(title: isImport ? "Import \(cells.count) of \(document?.pages.count ?? 0)" : "Export \(cells.count) page\(cells.count == 1 ? "" : "s")", color: Palette.importAsset, isEnabled: !cells.isEmpty && !isExporting, action: submit)
        }
    }

    private var fileChoice: some View {
        Button {
            isPicking = true
        } label: {
            HStack(spacing: 14) {
                GlyphView(name: "note_add", color: Palette.importAsset, size: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(documentName ?? "Choose PDF")
                        .font(Typography.monoBold(14))
                        .foregroundColor(Palette.textBright)
                        .lineLimit(1)
                    MicroLabel(text: importFailure ?? document.map { "\($0.pages.count) page\($0.pages.count == 1 ? "" : "s")" } ?? "No file chosen", color: importFailure == nil ? Palette.textLabel : Palette.destructive)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 60)
            .background(Squircle(radius: 16).fill(Palette.sunkenDeep))
            .overlay(Squircle(radius: 16).stroke(Palette.importAsset.opacity(0.45), lineWidth: 1.5))
            .contentShape(Squircle(radius: 16))
        }
        .buttonStyle(PressableStyle())
    }

    private func grid(width: CGFloat) -> some View {
        let shape = extent
        let available = width - Self.rowLabelWidth - Self.spacing * CGFloat(shape.columns)
        let cellWidth = max(24, min(Self.largestCellWidth, available / CGFloat(max(1, shape.columns))))
        let cellHeight = cellWidth * CGFloat(PaperGeometry.cellHeight / PaperGeometry.cellWidth)
        let positions = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0) })
        let firstNewRow = page?.extent.rows ?? shape.rows
        return HStack(alignment: .top, spacing: Self.spacing) {
            VStack(spacing: Self.spacing) {
                ForEach(0..<shape.rows, id: \.self) { row in
                    Button {
                        toggleRow(row, columns: shape.columns)
                    } label: {
                        Text(String(format: "%02d", row + 1))
                            .font(Typography.monoBold(12))
                            .tracking(1.5)
                            .foregroundColor(Palette.textMuted)
                            .frame(width: Self.rowLabelWidth, height: cellHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            VStack(spacing: Self.spacing) {
                ForEach(0..<shape.rows, id: \.self) { row in
                    HStack(spacing: Self.spacing) {
                        ForEach(0..<shape.columns, id: \.self) { column in
                            let cell = CellPosition(column: column, row: row)
                            cellView(cell, position: positions[cell], isNew: row >= firstNewRow)
                                .frame(width: cellWidth, height: cellHeight)
                        }
                    }
                }
            }
            .coordinateSpace(name: "transferCells")
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("transferCells"))
                .onChanged { value in
                    let column = Int(value.location.x / (cellWidth + Self.spacing))
                    let row = Int(value.location.y / (cellHeight + Self.spacing))
                    guard value.location.x >= 0, value.location.y >= 0, column < shape.columns, row < shape.rows else { return }
                    paint(CellPosition(column: column, row: row))
                }
                .onEnded { _ in
                    painting = nil
                })
        }
        .frame(maxWidth: .infinity)
        .onAppear { renderCells(cellSize: CGSize(width: cellWidth, height: cellHeight)) }
        .onChange(of: renderKey(cellWidth: cellWidth)) { _, _ in
            renderCells(cellSize: CGSize(width: cellWidth, height: cellHeight))
        }
    }

    private func cellView(_ cell: CellPosition, position: Int?, isNew: Bool) -> some View {
        let isSelected = position != nil
        return ZStack(alignment: .topLeading) {
            if let image = images[cell] {
                Image(uiImage: image)
                    .resizable()
                    .opacity(isSelected ? 1 : 0.55)
            } else {
                Palette.sunkenDeep
            }
            if let position {
                Text("\(position + 1)")
                    .font(Typography.monoBold(12))
                    .foregroundColor(Palette.ground)
                    .frame(minWidth: 24, minHeight: 24)
                    .padding(.horizontal, position >= 9 ? 4 : 0)
                    .background(Capsule().fill(Palette.accent))
                    .padding(6)
                    .transition(.popTogether)
            }
        }
        .clipShape(Self.cellShape)
        .overlay(Self.cellShape.stroke(isSelected ? Palette.accent : Palette.border, style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1.5, dash: isNew && !isSelected ? [5, 4] : [])))
        .scaleEffect(isSelected ? 0.96 : 1)
        .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isSelected)
    }

    private func renderKey(cellWidth: CGFloat) -> String {
        let cells = mode == .import ? ordered.map { "\($0.column).\($0.row)" }.joined(separator: ",") : ""
        return "\(mode.rawValue)|\(cells)|\(document?.asset ?? "")|\(page?.updated.timeIntervalSince1970 ?? 0)|\(importRevision)|\(Int(cellWidth))|\(preferences.paperStyle.rawValue)|\(preferences.showsGuides)"
    }

    private func renderCells(cellSize: CGSize) {
        guard let shown = previewPage, cellSize.width > 0 else { return }
        let options = RenderOptions(showsGuides: preferences.showsGuides, showsDividers: false, paperStyle: preferences.paperStyle, pixelScale: UIScreen.main.scale)
        var rendered: [CellPosition: UIImage] = [:]
        for row in 0..<shown.extent.rows {
            for column in 0..<shown.extent.columns {
                let cell = CellPosition(column: column, row: row)
                rendered[cell] = PageRenderer.cellThumbnail(of: shown, cell: cell, size: cellSize, options: options)
            }
        }
        images = rendered
    }

    private func selectAll() {
        guard let page else { return }
        exportSelection = Set((0..<page.extent.rows).flatMap { row in (0..<page.extent.columns).map { CellPosition(column: $0, row: row) } })
    }

    private func placeAfterNote() {
        guard let page, let document else {
            importSelection = []
            return
        }
        importSelection = Set(document.pages.indices.map { index in
            CellPosition(column: index % page.extent.columns, row: page.extent.rows + index / page.extent.columns)
        })
    }

    private func update(_ change: (inout Set<CellPosition>) -> Void) {
        withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
            if mode == .export {
                change(&exportSelection)
            } else {
                change(&importSelection)
            }
        }
    }

    private func toggleRow(_ row: Int, columns: Int) {
        let cells = (0..<columns).map { CellPosition(column: $0, row: row) }
        let isFull = cells.allSatisfy(selection.contains)
        let limit = capacity
        update { chosen in
            for cell in cells {
                if isFull {
                    chosen.remove(cell)
                } else if chosen.count < limit {
                    chosen.insert(cell)
                }
            }
        }
        Haptics.tick()
    }

    private func paint(_ cell: CellPosition) {
        if let painting, painting.last == cell {
            return
        }
        let isSelecting = painting?.isSelecting ?? !selection.contains(cell)
        painting = (isSelecting, cell)
        let limit = capacity
        update { chosen in
            if isSelecting && chosen.count < limit {
                chosen.insert(cell)
            } else if !isSelecting {
                chosen.remove(cell)
            }
        }
        Haptics.tick()
    }

    private func submit() {
        guard let page, !ordered.isEmpty else { return }
        if mode == .export {
            isExporting = true
            let options = RenderOptions(showsGuides: preferences.showsGuides, showsDividers: preferences.showsDividers, paperStyle: preferences.paperStyle, pixelScale: 4)
            if let url = NoteExport.pdf(of: page, title: library.noteTitle(page), cells: ordered, options: options) {
                NoteExport.share(url)
            }
            isExporting = false
            navigator.show(nil)
            return
        }
        guard let document else { return }
        Haptics.landed()
        library.placeDocument(document, to: pageId, cells: ordered)
        navigator.show(nil)
    }
}
