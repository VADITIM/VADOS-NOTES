import NotesCore
import SwiftUI
import UniformTypeIdentifiers

enum TransferMode: String {
    case view
    case export
    case `import`
}

private enum TransferTarget: Hashable {
    case cell(CellPosition)
    case page(Int)
}

private struct TransferFrames: PreferenceKey {
    static var defaultValue: [TransferTarget: CGRect] = [:]

    static func reduce(value: inout [TransferTarget: CGRect], nextValue: () -> [TransferTarget: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct TransferDrag {
    var source: TransferTarget
    var start: CGPoint
    var location: CGPoint
    var hasStart: Bool
    var isSelecting: Bool
    var isPainting = false
    var isLifted = false
    var lastPainted: CellPosition?
}

private struct PdfPageReference: Equatable {
    let asset: String
    let index: Int
}

private struct PdfGroup: Identifiable {
    let asset: String
    let name: String
    let sourceName: String?
    let accent: Color
    let elements: [Element]

    var id: String {
        asset
    }
}

private enum TransferPart: Int, CaseIterable {
    case header
    case strip
    case grid
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
    @State private var exportPlacements: [CellPosition: Int] = [:]
    @State private var importPlacements: [CellPosition: Int] = [:]
    @State private var drag: TransferDrag?
    @State private var frames: [TransferTarget: CGRect] = [:]
    @State private var images: [CellPosition: UIImage] = [:]
    @State private var sourceImages: [Int: UIImage] = [:]
    @State private var cellsKey = ""
    @State private var sourcesKey = ""
    @State private var importRevision = 0
    @State private var isExporting = false
    @State private var shownParts: Set<TransferPart> = []
    @State private var chosenPdfPage: PdfPageReference?

    private static let space = "transfer"
    private static let contentShare: CGFloat = 0.75
    private static let largestCellWidth: CGFloat = 150
    private static let stripWidth: CGFloat = 150
    private static let pdfColumnWidth: CGFloat = 120
    private static let pdfColumnReserve: CGFloat = 220
    private static let pdfDotSize: CGFloat = 9
    private static let rowLabelWidth: CGFloat = 36
    private static let spacing: CGFloat = 10
    private static let dragSlop: CGFloat = 6
    private static let cellShape = Squircle(radius: 8)
    private static let growDepth: CGFloat = 28

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

    private var isGrowable: Bool {
        mode == .view && isEditable && page != nil
    }

    private var noteImports: [Element] {
        page?.liveElements.filter { $0.type == .importPage } ?? []
    }

    private var hasPdfPages: Bool {
        !noteImports.isEmpty || (mode == .import && document != nil)
    }

    private var isShowingInverted: Bool {
        if mode == .import, let document {
            return !document.inverted.isEmpty && document.inverted.allSatisfy { $0 }
        }
        let imports = noteImports
        return !imports.isEmpty && imports.allSatisfy { ImportImages.shared.isInverted($0, isDark: preferences.paperStyle == .dark) }
    }

    private func setInverted(_ isInverted: Bool) {
        if var pending = document {
            pending.inverted = pending.pages.map { _ in isInverted }
            document = pending
        }
        library.setInverted(noteImports.map(\.id), on: pageId, to: isInverted)
    }

    private var placements: [CellPosition: Int] {
        switch mode {
        case .view: return [:]
        case .export: return exportPlacements
        case .import: return importPlacements
        }
    }

    private var ordered: [PagePlacement] {
        placements.map { PagePlacement(cell: $0.key, index: $0.value) }.sorted { $0.index < $1.index }
    }

    private var capacity: Int {
        mode == .export ? Int.max : document?.pages.count ?? 0
    }

    private var total: Int {
        switch mode {
        case .view: return extent.columns * extent.rows
        case .export: return placements.count
        case .import: return document?.pages.count ?? 0
        }
    }

    private var stripCount: Int {
        switch mode {
        case .view: return total
        case .export: return placements.count
        case .import: return document?.pages.count ?? 0
        }
    }

    private func cell(at position: Int) -> CellPosition {
        CellPosition(column: position % extent.columns, row: position / extent.columns)
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
        shown.elements += ordered.map { placement in
            library.importElement(asset: document.asset, index: placement.index, size: document.pages[placement.index], now: now, row: placement.cell.row, column: placement.cell.column, isInverted: document.isInverted(placement.index))
        }
        return shown
    }

    private var hovered: TransferTarget? {
        guard let drag, drag.isLifted else { return nil }
        guard let target = target(at: drag.location), target != drag.source else { return nil }
        if case .page = target, mode != .view {
            guard mode == .export, case .page = drag.source else { return nil }
        }
        return target
    }

    var body: some View {
        let _ = library.revision
        GeometryReader { proxy in
            ScrollView {
                module(width: proxy.size.width * Self.contentShare, height: proxy.size.height)
                    .frame(width: proxy.size.width * Self.contentShare)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                    .background(Color.clear.contentShape(Rectangle()).onTapGesture { navigator.show(nil) })
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDisabled(drag?.isLifted == true)
        }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            do {
                document = try ImportImages.importDocument(from: url, into: library)
                documentName = url.lastPathComponent
                importFailure = nil
                sourceImages = [:]
                placeAfterNote()
            } catch {
                document = nil
                importPlacements = [:]
                importFailure = ImportError.message(for: error)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ImportImages.didRender)) { _ in
            importRevision += 1
        }
        .onAppear {
            selectAll()
            showParts(true)
            if mode == .import {
                isPicking = true
            }
        }
        .onChange(of: navigator.isSheetLeaving) { _, isLeaving in
            if isLeaving {
                showParts(false)
            }
        }
    }

    private func showParts(_ isShown: Bool) {
        guard isShown else {
            withAnimation(Motion.powerTwoIn(Motion.overlayLeaveMilliseconds)) {
                shownParts = []
            }
            return
        }
        for part in TransferPart.allCases {
            withAnimation(Motion.powerTwoOut(Motion.overlayEnterMilliseconds, delay: Motion.riseDelayMilliseconds + part.rawValue * Motion.chromeStaggerMilliseconds)) {
                _ = shownParts.insert(part)
            }
        }
    }

    private func rising(_ part: TransferPart) -> some ViewModifier {
        RisingPart(isShown: shownParts.contains(part))
    }

    private func module(width: CGFloat, height: CGFloat) -> some View {
        let isImport = mode == .import
        let chosen = placements.count
        let groups = mode == .view ? pdfGroups : []
        let gridWidth = width - 36 - Self.stripWidth - 18 - (groups.isEmpty ? 0 : Self.pdfColumnWidth + 18)
        return SettingsModule(label: page.map { library.noteTitle($0) } ?? "Note") {
            HStack(spacing: 14) {
                Segmented(options: [SegmentOption(value: TransferMode.view, title: "View all"), SegmentOption(value: TransferMode.export, title: "Export"), SegmentOption(value: TransferMode.import, title: "Import")], selected: mode) { picked in
                    guard picked != .import || isEditable else { return }
                    withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
                        mode = picked
                        chosenPdfPage = nil
                    }
                    if picked == .import && document == nil {
                        isPicking = true
                    }
                }
                if hasPdfPages {
                    Segmented(options: [SegmentOption(value: false, title: "Normal"), SegmentOption(value: true, title: "Inverted")], selected: isShowingInverted) { isInverted in
                        setInverted(isInverted)
                    }
                    .transition(.popTogether)
                }
                if mode != .view {
                    SlabButton(title: isImport ? "Import \(chosen) of \(document?.pages.count ?? 0)" : "Export \(chosen) page\(chosen == 1 ? "" : "s")", color: Palette.importAsset, isEnabled: chosen > 0 && !isExporting, action: submit)
                        .transition(.popTogether)
                }
            }
            .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: mode)
            .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: hasPdfPages)
            .modifier(rising(.header))
            HStack(alignment: .top, spacing: 18) {
                if !groups.isEmpty {
                    pdfColumn(groups, height: max(Self.pdfColumnWidth * 2, height - Self.pdfColumnReserve))
                        .modifier(rising(.strip))
                        .transition(.popTogether)
                }
                strip
                    .frame(width: Self.stripWidth)
                    .modifier(rising(.strip))
                grid(width: gridWidth)
                    .modifier(rising(.grid))
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(TransferFrames.self) { frames = $0 }
        .overlay(ghost)
    }

    @ViewBuilder
    private var ghost: some View {
        if let drag, drag.isLifted, let frame = frames[drag.source], let image = image(for: drag.source) {
            Image(uiImage: image)
                .resizable()
                .frame(width: frame.width, height: frame.height)
                .clipShape(Self.cellShape)
                .overlay(Self.cellShape.stroke(Palette.accent, lineWidth: 2.5))
                .shadow(color: .black.opacity(0.55), radius: 20, y: 18)
                .scaleEffect(CGFloat(Motion.scales.holdPop))
                .position(x: frame.midX + drag.location.x - drag.start.x, y: frame.midY + drag.location.y - drag.start.y)
                .allowsHitTesting(false)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    private var fileChoice: some View {
        Button {
            isPicking = true
        } label: {
            HStack(spacing: 10) {
                GlyphView(name: "note_add", color: Palette.importAsset, size: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(documentName ?? "Choose PDF")
                        .font(Typography.monoBold(13))
                        .foregroundColor(Palette.textBright)
                        .lineLimit(1)
                    MicroLabel(text: importFailure ?? document.map { "\($0.pages.count) page\($0.pages.count == 1 ? "" : "s")" } ?? "No file chosen", color: importFailure == nil ? Palette.textLabel : Palette.destructive)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 52)
            .background(Squircle(radius: 16).fill(Palette.sunkenDeep))
            .overlay(Squircle(radius: 16).stroke(Palette.importAsset.opacity(0.45), lineWidth: 1.5))
            .contentShape(Squircle(radius: 16))
        }
        .buttonStyle(PressableStyle())
    }

    private var strip: some View {
        let pageHeight = Self.stripWidth * CGFloat(PaperGeometry.cellHeight / PaperGeometry.cellWidth)
        let count = stripCount
        return VStack(spacing: Self.spacing) {
            if mode == .import {
                fileChoice
                    .transition(.popTogether)
            } else if count == 0 {
                MicroLabel(text: "No pages", color: Palette.textMuted)
                    .padding(.vertical, 12)
            }
            ForEach(0..<count, id: \.self) { index in
                stripPage(index, isPlaced: cellHolding(index, in: placements) != nil)
                    .frame(width: Self.stripWidth, height: pageHeight)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: TransferFrames.self, value: [.page(index): proxy.frame(in: .named(Self.space))])
                    })
                    .gesture(stripGesture(index))
                    .simultaneousGesture(TapGesture().onEnded {
                        if mode == .view, chosenPdfPage != nil {
                            placeChosenPdfPage(on: cell(at: index))
                        }
                    })
            }
        }
        .onAppear { renderSources(size: CGSize(width: Self.stripWidth, height: pageHeight)) }
        .onChange(of: sourceKey) { _, _ in
            renderSources(size: CGSize(width: Self.stripWidth, height: pageHeight))
        }
    }

    private func stripPage(_ index: Int, isPlaced: Bool) -> some View {
        let target = TransferTarget.page(index)
        return pageTile(image: image(for: target), label: "\(index + 1)/\(total)", isSelected: isPlaced, isNew: false, target: target)
    }

    private func pageTile(image: UIImage?, label: String?, isSelected: Bool, isNew: Bool, target: TransferTarget) -> some View {
        let isLifted = drag?.isLifted == true && drag?.source == target
        let isHovered = hovered == target
        return ZStack(alignment: .bottomTrailing) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .opacity(isSelected || mode == .view ? 1 : 0.55)
            } else {
                Palette.sunkenDeep
            }
            if let label {
                Text(label)
                    .font(Typography.monoBold(11))
                    .tracking(0.5)
                    .foregroundColor(isSelected ? Palette.ground : Palette.textBody)
                    .frame(minWidth: 24, minHeight: 22)
                    .padding(.horizontal, 7)
                    .background(Capsule().fill(isSelected ? Palette.accent : Palette.sunkenDeep))
                    .padding(6)
                    .transition(.popTogether)
            }
        }
        .clipShape(Self.cellShape)
        .overlay(Self.cellShape.stroke(isHovered ? Palette.importAsset : isSelected ? Palette.accent : Palette.border, style: StrokeStyle(lineWidth: isSelected || isHovered ? 2.5 : 1.5, dash: isNew && !isSelected ? [5, 4] : [])))
        .scaleEffect(isHovered ? 1.04 : isSelected ? 0.96 : 1)
        .opacity(isLifted ? 0.3 : 1)
        .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isSelected)
        .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isHovered)
        .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isLifted)
    }

    private func grid(width: CGFloat) -> some View {
        let shape = extent
        let isGrowing = isGrowable
        let growReach = isGrowing ? Self.growDepth + Self.spacing : 0
        let available = width - Self.rowLabelWidth - Self.spacing * CGFloat(shape.columns) - growReach
        let cellWidth = max(24, min(Self.largestCellWidth, available / CGFloat(max(1, shape.columns))))
        let cellHeight = cellWidth * CGFloat(PaperGeometry.cellHeight / PaperGeometry.cellWidth)
        let cellsWidth = cellWidth * CGFloat(shape.columns) + Self.spacing * CGFloat(shape.columns - 1)
        let cellsHeight = cellHeight * CGFloat(shape.rows) + Self.spacing * CGFloat(shape.rows - 1)
        let firstNewRow = page?.extent.rows ?? shape.rows
        let count = total
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
                    .disabled(mode == .view)
                }
            }
            VStack(alignment: .leading, spacing: Self.spacing) {
                HStack(alignment: .top, spacing: Self.spacing) {
                    cells(shape: shape, cellWidth: cellWidth, cellHeight: cellHeight, firstNewRow: firstNewRow, count: count)
                    if isGrowing {
                        growButton(glyph: "add_column", label: "Add column") {
                            library.expand(pageId, columns: true)
                        }
                        .frame(width: Self.growDepth, height: cellsHeight)
                        .transition(.popTogether)
                    }
                }
                if isGrowing {
                    growButton(glyph: "add_row", label: "Add row") {
                        library.expand(pageId, columns: false)
                    }
                    .frame(width: cellsWidth, height: Self.growDepth)
                    .transition(.popTogether)
                }
            }
            .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isGrowing)
        }
        .frame(maxWidth: .infinity)
        .onAppear { renderCells(cellSize: CGSize(width: cellWidth, height: cellHeight)) }
        .onChange(of: renderKey(cellWidth: cellWidth)) { _, _ in
            renderCells(cellSize: CGSize(width: cellWidth, height: cellHeight))
        }
    }

    private func growButton(glyph: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.landed()
            action()
        } label: {
            GlyphView(name: glyph, color: Palette.create, size: 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Self.cellShape.fill(Palette.sunkenDeep))
                .overlay(Self.cellShape.stroke(Palette.borderControl, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .contentShape(Self.cellShape)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }

    private func cells(shape: Extent, cellWidth: CGFloat, cellHeight: CGFloat, firstNewRow: Int, count: Int) -> some View {
        VStack(spacing: Self.spacing) {
            ForEach(0..<shape.rows, id: \.self) { row in
                HStack(spacing: Self.spacing) {
                    ForEach(0..<shape.columns, id: \.self) { column in
                        let cell = CellPosition(column: column, row: row)
                        let index = mode == .view ? row * shape.columns + column : placements[cell]
                        pageTile(image: images[cell], label: index.map { "\($0 + 1)/\(count)" }, isSelected: mode != .view && index != nil, isNew: row >= firstNewRow, target: .cell(cell))
                            .frame(width: cellWidth, height: cellHeight)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: TransferFrames.self, value: [.cell(cell): proxy.frame(in: .named(Self.space))])
                            })
                    }
                }
            }
        }
        .gesture(gridGesture)
    }

    private var gridGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard var current = drag else {
                    beginGridDrag(at: value.startLocation)
                    return
                }
                current.location = value.location
                drag = current
                if current.isLifted {
                    return
                }
                if current.isPainting {
                    if case .cell(let cell) = target(at: value.location), cell != current.lastPainted {
                        drag?.lastPainted = cell
                        paint(cell, isSelecting: true)
                    }
                    return
                }
                if hypot(value.location.x - current.start.x, value.location.y - current.start.y) > Self.dragSlop {
                    lift()
                }
            }
            .onEnded { _ in
                guard let current = drag else { return }
                if current.isLifted {
                    drop()
                } else if !current.isPainting, mode != .view, case .cell(let cell) = current.source {
                    paint(cell, isSelecting: false)
                } else if mode == .view, chosenPdfPage != nil, case .cell(let cell) = current.source {
                    placeChosenPdfPage(on: cell)
                }
                drag = nil
            }
    }

    private func beginGridDrag(at location: CGPoint) {
        guard case .cell(let cell) = target(at: location) else { return }
        let isCarryable = mode == .view || placements[cell] != nil
        drag = TransferDrag(source: .cell(cell), start: location, location: location, hasStart: true, isSelecting: !isCarryable)
        guard !isCarryable else { return }
        drag?.isPainting = true
        drag?.lastPainted = cell
        paint(cell, isSelecting: true)
    }

    private func stripGesture(_ index: Int) -> some Gesture {
        LongPressGesture(minimumDuration: Motion.seconds(Motion.tileDragHoldMilliseconds))
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .onChanged { value in
                guard case .second(true, let moved) = value else { return }
                if drag == nil {
                    let centre = frames[.page(index)].map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero
                    drag = TransferDrag(source: .page(index), start: centre, location: centre, hasStart: false, isSelecting: false)
                    lift()
                }
                guard let moved else { return }
                if drag?.hasStart == false {
                    drag?.start = moved.startLocation
                    drag?.hasStart = true
                }
                drag?.location = moved.location
            }
            .onEnded { _ in
                if drag?.isLifted == true {
                    drop()
                }
                drag = nil
            }
    }

    private func lift() {
        Haptics.tick()
        withAnimation(Motion.backOut(Motion.stateMilliseconds)) {
            drag?.isLifted = true
        }
    }

    private func viewedCell(_ target: TransferTarget) -> CellPosition {
        switch target {
        case .cell(let cell): return cell
        case .page(let position): return cell(at: position)
        }
    }

    private func drop() {
        guard let current = drag else { return }
        if mode == .view {
            if let target = hovered {
                Haptics.landed()
                library.swapCells(pageId, viewedCell(current.source), viewedCell(target))
            }
            withAnimation(Motion.powerTwoIn(Motion.stateMilliseconds)) {
                drag = nil
            }
            return
        }
        let index: Int?
        switch current.source {
        case .cell(let cell): index = placements[cell]
        case .page(let page): index = page
        }
        if let index, let target = hovered {
            Haptics.landed()
            switch target {
            case .cell(let cell): assign(index, to: cell)
            case .page(let other): swap(index, other)
            }
        }
        withAnimation(Motion.powerTwoIn(Motion.stateMilliseconds)) {
            drag = nil
        }
    }

    private func target(at location: CGPoint) -> TransferTarget? {
        frames.first { $0.value.contains(location) }?.key
    }

    private func image(for target: TransferTarget) -> UIImage? {
        switch target {
        case .cell(let cell):
            return images[cell]
        case .page(let index):
            if mode == .view {
                return images[cell(at: index)]
            }
            if mode == .import {
                return sourceImages[index]
            }
            return cellHolding(index, in: placements).flatMap { images[$0] }
        }
    }

    private var sourceKey: String {
        "\(document?.asset ?? "")|\(importRevision)|\(preferences.paperStyle.rawValue)|\(preferences.showsGuides)|\(document?.inverted ?? [])"
    }

    private func renderKey(cellWidth: CGFloat) -> String {
        let shown = mode == .import ? ordered.map { "\($0.cell.column).\($0.cell.row).\($0.index)" }.joined(separator: ",") : ""
        return "\(mode.rawValue)|\(shown)|\(document?.asset ?? "")|\(library.revision)|\(importRevision)|\(Int(cellWidth))|\(preferences.paperStyle.rawValue)|\(preferences.showsGuides)|\(document?.inverted ?? [])"
    }

    private func renderOptions() -> RenderOptions {
        RenderOptions(showsGuides: preferences.showsGuides, showsDividers: false, paperStyle: preferences.paperStyle, pixelScale: UIScreen.main.scale)
    }

    private func renderCells(cellSize: CGSize) {
        guard let shown = previewPage, cellSize.width > 0 else { return }
        let options = renderOptions()
        let key = renderKey(cellWidth: cellSize.width)
        cellsKey = key
        Thumbnails.shared.perform { () -> [CellPosition: UIImage] in
            var rendered: [CellPosition: UIImage] = [:]
            for row in 0..<shown.extent.rows {
                for column in 0..<shown.extent.columns {
                    let cell = CellPosition(column: column, row: row)
                    rendered[cell] = PageRenderer.cellThumbnail(of: shown, cell: cell, size: cellSize, options: options)
                }
            }
            return rendered
        } completion: { rendered in
            guard cellsKey == key else { return }
            images = rendered
        }
    }

    private func renderSources(size: CGSize) {
        guard var shown = page, let document else { return }
        let options = renderOptions()
        let now = Date()
        var sources: [Int: Page] = [:]
        shown.extent = .single
        for index in document.pages.indices {
            shown.elements = [library.importElement(asset: document.asset, index: index, size: document.pages[index], now: now, row: 0, column: 0, isInverted: document.isInverted(index))]
            sources[index] = shown
        }
        let key = sourceKey
        sourcesKey = key
        Thumbnails.shared.perform {
            sources.mapValues { PageRenderer.cellThumbnail(of: $0, cell: CellPosition(column: 0, row: 0), size: size, options: options) }
        } completion: { rendered in
            guard sourcesKey == key else { return }
            sourceImages = rendered
        }
    }

    private var pdfGroups: [PdfGroup] {
        guard let page else { return [] }
        let imports = page.elements.filter { $0.type == .importPage && $0.asset != nil }.sorted(by: Element.isOrderedBefore)
        var assets: [String] = []
        for element in imports {
            if let asset = element.asset, !assets.contains(asset) {
                assets.append(asset)
            }
        }
        let accents = Tokens.shared.imports.accents
        return assets.enumerated().map { position, asset in
            let elements = imports.filter { $0.asset == asset }
            let sourceName = elements.lazy.compactMap(\.sourceName).first
            return PdfGroup(asset: asset, name: sourceName ?? "PDF \(position + 1)", sourceName: sourceName, accent: Color(hex: accents[position % accents.count]), elements: elements)
        }
    }

    private func pdfPageSizes(_ group: PdfGroup) -> [[Double]] {
        if let sizes = ImportImages.shared.pageSizes(of: group.asset), !sizes.isEmpty {
            return sizes
        }
        let count = (group.elements.compactMap(\.sourcePage).max() ?? 0) + 1
        return (0..<count).map { index in
            group.elements.first { $0.sourcePage == index }?.sourceSizeMillimetres ?? [PaperGeometry.cellWidth, PaperGeometry.cellHeight]
        }
    }

    private func isInverted(_ group: PdfGroup) -> Bool {
        let live = group.elements.filter { !$0.deleted }
        guard !live.isEmpty else { return group.elements.last?.inverted ?? false }
        let isDark = preferences.paperStyle == .dark
        return live.allSatisfy { ImportImages.shared.isInverted($0, isDark: isDark) }
    }

    private func setInverted(_ group: PdfGroup, to isInverted: Bool) {
        Haptics.tick()
        library.setInverted(group.elements.filter { !$0.deleted }.map(\.id), on: pageId, to: isInverted)
    }

    private func pdfColumn(_ groups: [PdfGroup], height: CGFloat) -> some View {
        let _ = importRevision
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(groups) { group in
                    pdfGroup(group)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(drag?.isLifted == true)
        .frame(width: Self.pdfColumnWidth, height: height, alignment: .top)
    }

    private func pdfGroup(_ group: PdfGroup) -> some View {
        let sizes = pdfPageSizes(group)
        let isShownInverted = isInverted(group)
        let used = Set(group.elements.filter { !$0.deleted }.compactMap(\.sourcePage))
        return VStack(alignment: .leading, spacing: Self.spacing) {
            HStack(spacing: 6) {
                Capsule()
                    .fill(group.accent)
                    .frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name)
                        .font(Typography.monoBold(11))
                        .foregroundColor(Palette.textBright)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    MicroLabel(text: "\(used.count)/\(sizes.count)", color: group.accent)
                }
                Spacer(minLength: 0)
                Button {
                    setInverted(group, to: !isShownInverted)
                } label: {
                    GlyphView(name: "invert", color: isShownInverted ? Palette.ground : group.accent, size: 15)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(isShownInverted ? group.accent : Palette.sunkenDeep))
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .disabled(used.isEmpty || !isEditable)
                .accessibilityLabel(isShownInverted ? "Original PDF" : "Invert PDF")
            }
            ForEach(sizes.indices, id: \.self) { index in
                pdfPage(group, index: index, size: sizes[index], count: sizes.count, isShownInverted: isShownInverted, isUsed: used.contains(index))
            }
        }
    }

    private func pdfPage(_ group: PdfGroup, index: Int, size: [Double], count: Int, isShownInverted: Bool, isUsed: Bool) -> some View {
        let reference = PdfPageReference(asset: group.asset, index: index)
        let isChosen = chosenPdfPage == reference
        let height = Self.pdfColumnWidth * CGFloat(PaperGeometry.cellHeight / PaperGeometry.cellWidth)
        return ZStack {
            Palette.sunkenDeep
            if let image = pdfImage(group.asset, index: index, size: size, isShownInverted: isShownInverted) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(CGFloat(size[0] / max(1, size[1])), contentMode: .fit)
                    .padding(4)
            }
        }
        .frame(width: Self.pdfColumnWidth, height: height)
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(isUsed ? Palette.create : Palette.destructive)
                .frame(width: Self.pdfDotSize, height: Self.pdfDotSize)
                .overlay(Circle().stroke(Palette.ground, lineWidth: 1.5))
                .padding(7)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(index + 1)/\(count)")
                .font(Typography.monoBold(10))
                .foregroundColor(Palette.ground)
                .padding(.horizontal, 6)
                .frame(minHeight: 18)
                .background(Capsule().fill(group.accent))
                .padding(5)
        }
        .clipShape(Self.cellShape)
        .overlay(Self.cellShape.stroke(isChosen ? Palette.accent : group.accent, lineWidth: isChosen ? 3 : 1.5))
        .scaleEffect(isChosen ? 1.04 : 1)
        .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isChosen)
        .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isUsed)
        .contentShape(Self.cellShape)
        .onTapGesture {
            choose(reference)
        }
        .accessibilityLabel("\(group.name) page \(index + 1), \(isUsed ? "in the note" : "not in the note")")
    }

    private func pdfImage(_ asset: String, index: Int, size: [Double], isShownInverted: Bool) -> CGImage? {
        let element = Element(id: "\(asset)-\(index)", type: .importPage, layer: .importLayer, order: 0, asset: asset, sourcePage: index, sourceSizeMillimetres: size, inverted: isShownInverted, updated: .distantPast, device: "")
        let pixels = Double(Self.pdfColumnWidth * UIScreen.main.scale)
        return ImportImages.shared.image(for: element, pixelsPerMillimetre: pixels / PaperGeometry.cellWidth, isDark: preferences.paperStyle == .dark, rendersNewLevel: false)
    }

    private func choose(_ reference: PdfPageReference) {
        guard isEditable else { return }
        Haptics.tick()
        withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
            chosenPdfPage = chosenPdfPage == reference ? nil : reference
        }
    }

    private func placeChosenPdfPage(on cell: CellPosition) {
        guard let chosen = chosenPdfPage, isEditable, let group = pdfGroups.first(where: { $0.asset == chosen.asset }) else { return }
        let sizes = pdfPageSizes(group)
        guard sizes.indices.contains(chosen.index) else { return }
        Haptics.landed()
        library.placeImportPage(asset: chosen.asset, sourcePage: chosen.index, size: sizes[chosen.index], sourceName: group.sourceName, isInverted: isInverted(group), on: pageId, at: cell)
        withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
            chosenPdfPage = nil
        }
    }

    private func cellHolding(_ index: Int, in chosen: [CellPosition: Int]) -> CellPosition? {
        chosen.first { $0.value == index }?.key
    }

    private func nextIndex(in chosen: [CellPosition: Int]) -> Int? {
        let used = Set(chosen.values)
        var index = 0
        while used.contains(index) {
            index += 1
        }
        return index < capacity ? index : nil
    }

    private func compact(_ chosen: inout [CellPosition: Int]) {
        guard mode == .export else { return }
        for (index, entry) in chosen.sorted(by: { $0.value < $1.value }).enumerated() {
            chosen[entry.key] = index
        }
    }

    private func selectAll() {
        guard let page else { return }
        let cells = (0..<page.extent.rows).flatMap { row in (0..<page.extent.columns).map { CellPosition(column: $0, row: row) } }
        exportPlacements = Dictionary(uniqueKeysWithValues: cells.sorted(by: CellPosition.readingOrder).enumerated().map { ($1, $0) })
    }

    private func placeAfterNote() {
        guard let page, let document else {
            importPlacements = [:]
            return
        }
        importPlacements = Dictionary(uniqueKeysWithValues: document.pages.indices.map { index in
            (CellPosition(column: index % page.extent.columns, row: page.extent.rows + index / page.extent.columns), index)
        })
    }

    private func update(_ change: (inout [CellPosition: Int]) -> Void) {
        withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
            if mode == .export {
                change(&exportPlacements)
            } else {
                change(&importPlacements)
            }
        }
    }

    private func assign(_ index: Int, to target: CellPosition) {
        update { chosen in
            let source = cellHolding(index, in: chosen)
            let occupant = chosen[target]
            if let source {
                chosen[source] = nil
            }
            if let occupant, let source, source != target {
                chosen[source] = occupant
            }
            chosen[target] = index
        }
    }

    private func swap(_ first: Int, _ second: Int) {
        update { chosen in
            guard let firstCell = cellHolding(first, in: chosen), let secondCell = cellHolding(second, in: chosen) else { return }
            chosen[firstCell] = second
            chosen[secondCell] = first
        }
    }

    private func toggleRow(_ row: Int, columns: Int) {
        let cells = (0..<columns).map { CellPosition(column: $0, row: row) }
        let isFull = cells.allSatisfy { placements[$0] != nil }
        update { chosen in
            for cell in cells {
                if isFull {
                    chosen[cell] = nil
                } else if chosen[cell] == nil, let index = nextIndex(in: chosen) {
                    chosen[cell] = index
                }
            }
            compact(&chosen)
        }
        Haptics.tick()
    }

    private func paint(_ cell: CellPosition, isSelecting: Bool) {
        update { chosen in
            if isSelecting, chosen[cell] == nil, let index = nextIndex(in: chosen) {
                chosen[cell] = index
            } else if !isSelecting, chosen[cell] != nil {
                chosen[cell] = nil
                compact(&chosen)
            }
        }
        Haptics.tick()
    }

    private func submit() {
        guard let page, !ordered.isEmpty else { return }
        if mode == .export {
            isExporting = true
            let options = RenderOptions(showsGuides: preferences.showsGuides, showsDividers: preferences.showsDividers, paperStyle: preferences.paperStyle, pixelScale: 4)
            if let url = NoteExport.pdf(of: page, title: library.noteTitle(page), cells: ordered.map(\.cell), options: options) {
                NoteExport.share(url)
            }
            isExporting = false
            navigator.show(nil)
            return
        }
        guard let document else { return }
        Haptics.landed()
        library.placeDocument(document, to: pageId, placements: ordered)
        navigator.show(nil)
    }
}

private struct RisingPart: ViewModifier {
    let isShown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown ? 0 : 16)
    }
}
