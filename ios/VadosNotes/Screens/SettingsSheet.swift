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

struct SettingsSheet: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var preferences: Preferences
    @State private var owner = ""
    @State private var repository = ""
    @State private var branch = "main"
    @State private var token = ""
    @State private var hasStoredToken = false
    @State private var isAsciiWheelOpen = false
    @State private var isFontListOpen = false

    private static let asciiOpacityRange = Tokens.shared.background.opacityRange
    private static let smoothingRange = Tokens.shared.ink.smoothingRange
    private static let asciiSliderLength: CGFloat = 220
    private static let contentShare: CGFloat = 0.75

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
                    .frame(width: proxy.size.width * Self.contentShare)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                    .background(Color.clear.contentShape(Rectangle()).onTapGesture { navigator.show(nil) })
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .onAppear {
            owner = library.sync.settings.owner
            repository = library.sync.settings.repository
            branch = library.sync.settings.branch
            hasStoredToken = Keychain.readToken() != nil
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
            .zIndex(1)
        }
    }

    private var firstColumn: some View {
        VStack(spacing: 18) {
            asciiModule
            syncModule
        }
    }

    private var secondColumn: some View {
        VStack(spacing: 18) {
            paperModule
            penModule
            textModule
                .zIndex(1)
        }
    }

    private var asciiModule: some View {
        SettingsModule(label: "ASCII") {
            Segmented(options: [SegmentOption(value: true, title: "On"), SegmentOption(value: false, title: "Off")], selected: preferences.showsAsciiBackground) { isOn in
                preferences.setShowsAsciiBackground(isOn)
            }
            let current = preferences.asciiBackgroundColor.uppercased()
            HStack(spacing: 12) {
                WheelButton(isOpen: isAsciiWheelOpen, orientation: .horizontal) {
                    withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
                        isAsciiWheelOpen.toggle()
                    }
                }
                SizeSlider(orientation: .horizontal, share: Self.share(preferences.asciiBackgroundOpacity, Self.asciiOpacityRange), previewDiameter: 0, previewColor: .clear, length: Self.asciiSliderLength) { share in
                    preferences.setAsciiBackgroundOpacity(Self.value(share, Self.asciiOpacityRange))
                }
            }
            if isAsciiWheelOpen {
                ColorPanel(color: current) { hex in
                    preferences.setAsciiBackgroundColor(hex)
                }
                .transition(.popTogether)
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

    private var textModule: some View {
        SettingsModule(label: "Text") {
            FontDropdown(isOpen: $isFontListOpen)
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
}

struct FontDropdown: View {
    @Binding var isOpen: Bool

    @EnvironmentObject private var preferences: Preferences
    @State private var query = ""
    @State private var families: [String] = []
    @State private var isImportingFont = false
    @State private var isPickingSystemFont = false
    @State private var failure: String?

    private static let listHeight: CGFloat = 300
    private static let triggerHeight: CGFloat = 52
    private static let shape = Squircle(radius: 14)

    private var shown: [String] {
        families.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Button {
            withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
                isOpen.toggle()
            }
            if isOpen {
                query = ""
                families = UserFonts.families
            }
        } label: {
            HStack(spacing: 12) {
                Text(preferences.writingFont)
                    .font(.custom(preferences.writingFont, fixedSize: 17))
                    .foregroundColor(Palette.textBright)
                    .lineLimit(1)
                Spacer()
                GlyphView(name: "back", color: Palette.textMuted, size: 18)
                    .rotationEffect(.degrees(isOpen ? 90 : -90))
            }
            .padding(.horizontal, 16)
            .frame(height: Self.triggerHeight)
            .background(Self.shape.fill(Palette.sunkenDeep))
            .overlay(Self.shape.stroke(Palette.border, lineWidth: 1))
            .contentShape(Self.shape)
        }
        .buttonStyle(PressableStyle())
        .overlay(alignment: .topLeading) {
            if isOpen {
                popover
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: Self.triggerHeight + 8)
                    .transition(.popTogether)
            }
        }
        .fileImporter(isPresented: $isImportingFont, allowedContentTypes: [.font]) { result in
            guard case .success(let url) = result else { return }
            do {
                let added = try UserFonts.add(from: url)
                families = UserFonts.families
                failure = nil
                if let first = added.first {
                    choose(first)
                }
            } catch {
                failure = "Not a readable font"
            }
        }
        .sheet(isPresented: $isPickingSystemFont) {
            SystemFontPicker { family in
                isPickingSystemFont = false
                guard let family else { return }
                families = UserFonts.families
                choose(family)
            }
            .ignoresSafeArea()
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("", text: $query, prompt: Text("Search fonts").foregroundColor(Palette.textFaint))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .modifier(FieldStyle())
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown, id: \.self) { family in
                            row(family)
                                .id(family)
                        }
                        if shown.isEmpty {
                            MicroLabel(text: "No font matches", color: Palette.textFaint)
                                .padding(14)
                        }
                    }
                }
                .frame(height: Self.listHeight)
                .scrollIndicators(.hidden)
                .onAppear {
                    reader.scrollTo(preferences.writingFont, anchor: .center)
                }
            }
            HStack(spacing: 12) {
                LinkButton(glyph: "import", title: "Add font", tint: Palette.importAsset) {
                    isImportingFont = true
                }
                LinkButton(glyph: "text", title: "Installed", tint: Palette.importAsset) {
                    isPickingSystemFont = true
                }
            }
            if let failure {
                MicroLabel(text: failure, color: Palette.destructive)
            }
        }
        .padding(12)
        .background(Squircle.panel.fill(Palette.panelSolid))
        .overlay(Squircle.panel.stroke(Palette.borderStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    private func row(_ family: String) -> some View {
        let isSelected = family == preferences.writingFont
        return Button {
            choose(family)
        } label: {
            Text(family)
                .font(.custom(family, fixedSize: 16))
                .foregroundColor(isSelected ? Palette.textBright : Palette.textBody)
                .lineLimit(1)
                .padding(.vertical, 9)
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Palette.accent)
                        .frame(width: 2)
                        .opacity(isSelected ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func choose(_ family: String) {
        preferences.setWritingFont(family)
        withAnimation(Motion.powerTwoIn(Motion.stateMilliseconds)) {
            isOpen = false
        }
    }
}
