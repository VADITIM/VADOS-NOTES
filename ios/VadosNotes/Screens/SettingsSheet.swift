import NotesCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsModule<Content: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                MicroLabel(text: label)
                Spacer()
                if let detail {
                    MicroLabel(text: detail, color: Palette.textMuted)
                }
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Squircle.panel.fill(Palette.panel).background(Squircle.panel.fill(Palette.panelSolid)))
        .overlay(Squircle.panel.stroke(Palette.border, lineWidth: 1))
    }
}

struct LinkButton: View {
    let glyph: String
    let title: String
    var tint: Color = Palette.textBody
    var isOn = false
    var isEnabled = true
    let action: () -> Void

    static let height: CGFloat = 62
    private static let shape = Squircle(radius: 20)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                GlyphView(name: glyph, color: isOn ? tint : Palette.textMuted, size: 24)
                Text(title.uppercased())
                    .font(Typography.monoBold(12))
                    .tracking(1.5)
                    .foregroundColor(isOn ? tint : Palette.textBody)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .background(Self.shape.fill(isOn ? tint.opacity(0.16) : Palette.sunken))
            .overlay(Self.shape.stroke(Palette.border, lineWidth: 1))
            .overlay(Self.shape.stroke(tint, lineWidth: 2).padding(1).opacity(isOn ? 1 : 0))
            .contentShape(Self.shape)
        }
        .buttonStyle(PressableStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isOn)
    }
}

struct SettingsSlider: View {
    let title: String
    let share: Double
    let caption: String
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 14) {
            SizeSlider(orientation: .horizontal, share: share, previewDiameter: 0, previewColor: .clear, length: 220, onChange: onChange)
            VStack(alignment: .leading, spacing: 4) {
                MicroLabel(text: title, color: Palette.textMuted)
                Text(caption)
                    .font(Typography.monoBold(13))
                    .foregroundColor(Palette.textBright)
            }
        }
    }
}

struct ModulePop: ViewModifier, Animatable {
    var scale: CGFloat
    let isScaling: Bool

    private static let smallestScale: CGFloat = 0.001

    var animatableData: CGFloat {
        get { scale }
        set { scale = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(isScaling ? max(Self.smallestScale, scale) : 1)
            .opacity(min(1, max(0, scale)))
    }
}

struct SettingsSheet: View {
    private enum Module: CaseIterable {
        case ascii
        case transfer
        case paper
        case pen
        case sync
        case delete
    }

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var preferences: Preferences
    @State private var owner = ""
    @State private var repository = ""
    @State private var branch = "main"
    @State private var token = ""
    @State private var hasStoredToken = false
    @State private var isAsciiWheelOpen = false
    @State private var isImporting = false
    @State private var isDeleteArmed = false
    @State private var importFailure: String?
    @State private var moduleScales: [Module: CGFloat] = [:]
    @Environment(\.accessibilityReduceMotion) private var isMotionReduced

    private static let asciiOpacityRange = Tokens.shared.background.opacityRange
    private static let smoothingRange = Tokens.shared.ink.smoothingRange
    private static let armedSeconds = 2.4

    private var pageContext: (notebookId: String, pageId: String)? {
        if case .page(let notebookId, let pageId) = navigator.route {
            return (notebookId, pageId)
        }
        return nil
    }

    private var page: Page? {
        pageContext.flatMap { library.page($0.pageId) }
    }

    private var isPageEditable: Bool {
        guard let pageContext, page != nil else { return false }
        return !library.isReadOnly(pageContext.pageId)
    }

    private static func share(_ value: Double, _ range: [Double]) -> Double {
        (value - range[0]) / (range[1] - range[0])
    }

    private static func value(_ share: Double, _ range: [Double]) -> Double {
        range[0] + (range[1] - range[0]) * share
    }

    var body: some View {
        let _ = library.revision
        let _ = preferences.revision
        GeometryReader { proxy in
            ScrollView {
                panels
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                    .background(Color.clear.contentShape(Rectangle()).onTapGesture { navigator.show(nil) })
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result, let pageContext else { return }
            do {
                let document = try ImportImages.importDocument(from: url, into: library)
                library.appendDocument(document, to: pageContext.pageId)
                importFailure = nil
                navigator.show(nil)
            } catch {
                importFailure = "Not a readable PDF"
            }
        }
        .onAppear {
            owner = library.sync.settings.owner
            repository = library.sync.settings.repository
            branch = library.sync.settings.branch
            hasStoredToken = Keychain.readToken() != nil
            popModules(isShown: true)
        }
        .onChange(of: navigator.isSheetLeaving) { _, isLeaving in
            popModules(isShown: !isLeaving)
        }
    }

    private func popped(_ module: Module) -> ModulePop {
        ModulePop(scale: moduleScales[module] ?? 0, isScaling: !isMotionReduced)
    }

    private func popModules(isShown: Bool) {
        let target: CGFloat = isShown ? 1 : 0
        guard !isMotionReduced else {
            withAnimation(isShown ? Motion.powerTwoOut(Motion.stateMilliseconds) : Motion.powerTwoIn(Motion.stateMilliseconds)) {
                for module in Module.allCases {
                    moduleScales[module] = target
                }
            }
            return
        }
        for (position, module) in Module.allCases.shuffled().enumerated() {
            withAnimation(Motion.settingsPop.delay(Motion.seconds(position * Motion.settingsStaggerMilliseconds))) {
                moduleScales[module] = target
            }
        }
    }

    private var panels: some View {
        VStack(spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    firstColumn
                    secondColumn
                }
                VStack(spacing: 18) {
                    firstColumn
                    secondColumn
                }
            }
            syncModule
                .modifier(popped(.sync))
            LinkButton(glyph: "trash", title: isDeleteArmed ? "Tap again to delete" : "Delete note", tint: Palette.destructive, isOn: isDeleteArmed, isEnabled: page != nil, action: deletePressed)
                .frame(maxWidth: 280)
                .modifier(popped(.delete))
        }
    }

    private var firstColumn: some View {
        VStack(spacing: 18) {
            asciiModule
                .modifier(popped(.ascii))
            HStack(spacing: 12) {
                LinkButton(glyph: "import", title: "Import", tint: Palette.importAsset, isEnabled: isPageEditable) {
                    isImporting = true
                }
                LinkButton(glyph: "export", title: "Export", tint: Palette.importAsset, isEnabled: page != nil, action: export)
            }
            .modifier(popped(.transfer))
            if let importFailure {
                MicroLabel(text: importFailure, color: Palette.destructive)
                    .modifier(popped(.transfer))
            }
        }
    }

    private var secondColumn: some View {
        VStack(spacing: 18) {
            paperModule
                .modifier(popped(.paper))
            penModule
                .modifier(popped(.pen))
        }
    }

    private var asciiModule: some View {
        SettingsModule(label: "ASCII") {
            Segmented(options: [SegmentOption(value: true, title: "On"), SegmentOption(value: false, title: "Off")], selected: preferences.showsAsciiBackground) { isOn in
                preferences.setShowsAsciiBackground(isOn)
            }
            let current = preferences.asciiBackgroundColor.uppercased()
            let colors = Tokens.shared.background.colors
            HStack(spacing: 2) {
                WheelButton(isOpen: isAsciiWheelOpen || !colors.map { $0.uppercased() }.contains(current), orientation: .horizontal) {
                    withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
                        isAsciiWheelOpen.toggle()
                    }
                }
                ForEach(colors, id: \.self) { color in
                    SwatchButton(color: Color(hex: color), isSelected: color.uppercased() == current, orientation: .horizontal, onSelect: { preferences.setAsciiBackgroundColor(color) })
                }
            }
            if isAsciiWheelOpen {
                ColorPanel(color: current) { hex in
                    preferences.setAsciiBackgroundColor(hex)
                }
                .transition(.popTogether)
            }
            SettingsSlider(title: "Opacity", share: Self.share(preferences.asciiBackgroundOpacity, Self.asciiOpacityRange), caption: "\(Int((preferences.asciiBackgroundOpacity * 100).rounded()))%") { share in
                preferences.setAsciiBackgroundOpacity(Self.value(share, Self.asciiOpacityRange))
            }
            Segmented(options: [SegmentOption(value: false, title: "Still"), SegmentOption(value: true, title: "Moving")], selected: preferences.isAsciiBackgroundMoving) { isMoving in
                preferences.setAsciiBackgroundMoving(isMoving)
            }
            if preferences.isAsciiBackgroundMoving {
                Segmented(options: [SegmentOption(value: true, title: "Both"), SegmentOption(value: false, title: "Exclude canvas")], selected: preferences.doesAsciiBackgroundMoveInCanvas) { movesInCanvas in
                    preferences.setAsciiBackgroundMovesInCanvas(movesInCanvas)
                }
                .transition(.popTogether)
            }
        }
        .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isAsciiWheelOpen)
        .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: preferences.isAsciiBackgroundMoving)
    }

    private var paperModule: some View {
        SettingsModule(label: "Paper") {
            Segmented(options: [SegmentOption(value: PaperStyle.dark, title: "Dark"), SegmentOption(value: PaperStyle.light, title: "White")], selected: preferences.paperStyle) { style in
                preferences.setPaperStyle(style)
            }
            Rectangle()
                .fill(Palette.borderStrong)
                .frame(width: 48, height: 1)
                .frame(maxWidth: .infinity)
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    LinkButton(glyph: "add_row", title: "Row", tint: Palette.create, isEnabled: isPageEditable) {
                        if let pageContext {
                            library.expand(pageContext.pageId, columns: false)
                        }
                    }
                    LinkButton(glyph: "add_column", title: "Column", tint: Palette.create, isEnabled: isPageEditable) {
                        if let pageContext {
                            library.expand(pageContext.pageId, columns: true)
                        }
                    }
                }
                GridRow {
                    LinkButton(glyph: "guides", title: "Grid", tint: Palette.view, isOn: preferences.showsGuides) {
                        preferences.setShowsGuides(!preferences.showsGuides)
                    }
                    LinkButton(glyph: "cell_lines", title: "Divider", tint: Palette.view, isOn: preferences.showsDividers) {
                        preferences.setShowsDividers(!preferences.showsDividers)
                    }
                }
            }
        }
    }

    private var penModule: some View {
        SettingsModule(label: "Pen") {
            SettingsSlider(title: "Smoothing", share: Self.share(preferences.inkSmoothing, Self.smoothingRange), caption: String(format: "%.1f", preferences.inkSmoothing)) { share in
                preferences.setInkSmoothing(Self.value(share, Self.smoothingRange))
            }
        }
    }

    private var syncModule: some View {
        SettingsModule(label: "GitHub sync", detail: "\(library.sync.status.label) · \(library.store.journal.entries.count) queued") {
            HStack(spacing: 10) {
                TextField("", text: $owner, prompt: Text("Owner").foregroundColor(Palette.textFaint))
                    .modifier(FieldStyle())
                Text("/")
                    .font(Typography.mono(18))
                    .foregroundColor(Palette.textFaint)
                TextField("", text: $repository, prompt: Text("Repository").foregroundColor(Palette.textFaint))
                    .modifier(FieldStyle())
                Text("|")
                    .font(Typography.mono(18))
                    .foregroundColor(Palette.textFaint)
                TextField("", text: $branch, prompt: Text("Branch").foregroundColor(Palette.textFaint))
                    .modifier(FieldStyle())
            }
            SecureField("", text: $token, prompt: Text(hasStoredToken ? "Token stored in Keychain" : "Fine-grained token").foregroundColor(Palette.textFaint))
                .modifier(FieldStyle())
            if case .failed(let message) = library.sync.status {
                Text(message)
                    .font(Typography.mono(11))
                    .foregroundColor(Palette.destructive)
                    .lineLimit(3)
            }
            if !library.store.blockedPaths.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(library.store.blockedPaths.keys.sorted(), id: \.self) { path in
                        MicroLabel(text: "\(library.store.blockedPaths[path]?.rawValue ?? "") · \(path)", color: Palette.destructive)
                    }
                }
            }
            SlabButton(title: "Save", color: Palette.create, isEnabled: !owner.isEmpty && !repository.isEmpty && !branch.isEmpty) {
                let settings = SyncSettings(
                    owner: owner.trimmingCharacters(in: .whitespaces),
                    repository: repository.trimmingCharacters(in: .whitespaces),
                    branch: branch.trimmingCharacters(in: .whitespaces)
                )
                library.sync.configure(settings, token: token.isEmpty ? nil : token)
                navigator.show(nil)
            }
        }
    }

    private func export() {
        guard let page else { return }
        let options = RenderOptions(showsGuides: preferences.showsGuides, showsDividers: preferences.showsDividers, paperStyle: preferences.paperStyle, pixelScale: 4)
        guard let url = NoteExport.pdf(of: page, title: library.noteTitle(page), options: options) else { return }
        NoteExport.share(url)
    }

    private func deletePressed() {
        guard let pageContext else { return }
        guard isDeleteArmed else {
            Haptics.tick()
            isDeleteArmed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.armedSeconds) {
                isDeleteArmed = false
            }
            return
        }
        Haptics.landed()
        library.deletePage(pageContext.pageId)
        navigator.show(nil)
        navigator.go(.notebook(pageContext.notebookId))
    }
}
