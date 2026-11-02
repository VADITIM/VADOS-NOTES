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
    @State private var importRevision = 0
    @State private var isExporting = false
    @State private var shownParts: Set<TransferPart> = []

    private static let space = "transfer"
    private static let contentShare: CGFloat = 0.75
    private static let largestCellWidth: CGFloat = 150
    private static let stripWidth: CGFloat = 150
    private static let rowLabelWidth: CGFloat = 36
    private static let spacing: CGFloat = 10
    private static let dragSlop: CGFloat = 6
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
            library.importElement(asset: document.asset, index: placement.index, size: document.pages[placement.index], now: now, row: placement.cell.row, column: placement.cell.column)
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
                module(width: proxy.size.width * Self.contentShare)
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

    private func module(width: CGFloat) -> some View {
        let isImport = mode == .import
        let chosen = placements.count
        let gridWidth = width - 36 - Self.stripWidth - 18
        return SettingsModule(label: page.map { library.noteTitle($0) } ?? "Note") {
            HStack(spacing: 14) {
                Segmented(options: [SegmentOption(value: TransferMode.view, title: "View all"), SegmentOption(value: TransferMode.export, title: "Export"), SegmentOption(value: TransferMode.import, title: "Import")], selected: mode) { picked in
                    guard picked != .import || isEditable else { return }
                    withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
                        mode = picked
                    }
                    if picked == .import && document == nil {
                        isPicking = true
                    }
                }
                Segmented(options: [SegmentOption(value: false, title: "Normal"), SegmentOption(value: true, title: "Inverted")], selected: preferences.invertsPdfPages) { isInverted in
                    preferences.setInvertsPdfPages(isInverted)
                }
                if mode != .view {
                    SlabButton(title: isImport ? "Import \(chosen) of \(document?.pages.count ?? 0)" : "Export \(chosen) page\(chosen == 1 ? "" : "s")", color: Palette.importAsset, isEnabled: chosen > 0 && !isExporting, action: submit)
                        .transition(.popTogether)
                }
            }
            .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: mode)
            .modifier(rising(.header))
            HStack(alignment: .top, spacing: 18) {
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
        let available = width - Self.rowLabelWidth - Self.spacing * CGFloat(shape.columns)
        let cellWidth = max(24, min(Self.largestCellWidth, available / CGFloat(max(1, shape.columns))))
        let cellHeight = cellWidth * CGFloat(PaperGeometry.cellHeight / PaperGeometry.cellWidth)
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
        .frame(maxWidth: .infinity)
        .onAppear { renderCells(cellSize: CGSize(width: cellWidth, height: cellHeight)) }
        .onChange(of: renderKey(cellWidth: cellWidth)) { _, _ in
            renderCells(cellSize: CGSize(width: cellWidth, height: cellHeight))
        }
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
        "\(document?.asset ?? "")|\(importRevision)|\(preferences.paperStyle.rawValue)|\(preferences.showsGuides)|\(preferences.invertsPdfPages)"
    }

    private func renderKey(cellWidth: CGFloat) -> String {
        let shown = mode == .import ? ordered.map { "\($0.cell.column).\($0.cell.row).\($0.index)" }.joined(separator: ",") : ""
        return "\(mode.rawValue)|\(shown)|\(document?.asset ?? "")|\(library.revision)|\(importRevision)|\(Int(cellWidth))|\(preferences.paperStyle.rawValue)|\(preferences.showsGuides)|\(preferences.invertsPdfPages)"
    }

    private func renderOptions() -> RenderOptions {
        RenderOptions(showsGuides: preferences.showsGuides, showsDividers: false, paperStyle: preferences.paperStyle, pixelScale: UIScreen.main.scale)
    }

    private func renderCells(cellSize: CGSize) {
        guard let shown = previewPage, cellSize.width > 0 else { return }
        let options = renderOptions()
        var rendered: [CellPosition: UIImage] = [:]
        for row in 0..<shown.extent.rows {
            for column in 0..<shown.extent.columns {
                let cell = CellPosition(column: column, row: row)
                rendered[cell] = PageRenderer.cellThumbnail(of: shown, cell: cell, size: cellSize, options: options)
            }
        }
        images = rendered
    }

    private func renderSources(size: CGSize) {
        guard var shown = page, let document else { return }
        let options = renderOptions()
        let now = Date()
        var rendered: [Int: UIImage] = [:]
        shown.extent = .single
        for index in document.pages.indices {
            shown.elements = [library.importElement(asset: document.asset, index: index, size: document.pages[index], now: now, row: 0, column: 0)]
            rendered[index] = PageRenderer.cellThumbnail(of: shown, cell: CellPosition(column: 0, row: 0), size: size, options: options)
        }
        sourceImages = rendered
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
