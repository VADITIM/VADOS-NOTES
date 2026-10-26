import NotesCore
import SwiftUI

struct LibraryScreen: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var menu: MenuController

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 18)]

    var body: some View {
        let notebooks = library.notebooks
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                TopBar(title: "Notes", label: "\(notebooks.count) notebook\(notebooks.count == 1 ? "" : "s")") {
                    SyncBadge(sync: library.sync)
                }
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(Array(notebooks.enumerated()), id: \.element.id) { index, notebook in
                            NotebookTile(notebook: notebook, pageCount: library.pages(in: notebook.id).count, firstPage: library.pages(in: notebook.id).first, rank: index)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .padding(.bottom, 140)
                }
            }
            PopBar(groups: [[
                PopBarItem(id: "new-notebook", glyph: .plus, tint: Palette.create, isActive: true, action: { navigator.show(.newNotebook) }),
            ]])
            .padding(.bottom, 24)
        }
    }
}

private struct NotebookTile: View {
    let notebook: Notebook
    let pageCount: Int
    let firstPage: Page?
    let rank: Int

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var menu: MenuController
    @State private var isShown = false

    var body: some View {
        HoldableButton(pressedScale: 0.97, action: open, onHold: showMenu) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    Squircle.tile.fill(Palette.sunkenDeep)
                    if let firstPage {
                        PageThumbnail(page: firstPage)
                            .padding(10)
                    }
                }
                .aspectRatio(1.25, contentMode: .fit)
                HStack(alignment: .top, spacing: 10) {
                    Rectangle()
                        .fill(Palette.accent)
                        .frame(width: 4, height: 28)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(notebook.title)
                            .font(Typography.heading(19))
                            .foregroundColor(Palette.textBright)
                            .lineLimit(1)
                        MicroLabel(text: "\(pageCount) page\(pageCount == 1 ? "" : "s")")
                    }
                }
            }
            .padding(14)
            .background(Squircle.panel.fill(Palette.panelSolid))
            .overlay(Squircle.panel.stroke(Palette.border, lineWidth: 1))
        }
        .opacity(isShown ? 1 : 0)
        .offset(y: isShown ? 0 : 14)
        .scaleEffect(isShown ? 1 : 0.94)
        .onAppear {
            withAnimation(Motion.powerTwoOut(240, delay: min(rank, 16) * 12)) {
                isShown = true
            }
        }
    }

    private func open() {
        navigator.go(.notebook(notebook.id))
    }

    private func showMenu(_ frame: CGRect) {
        let slots = MenuSlot.fromTokens(Tokens.shared.menus.notebook, title: Self.title, perform: { action in
            switch action {
            case "open": open()
            case "rename": navigator.show(.rename(notebookId: notebook.id, title: notebook.title))
            case "delete_notebook": library.deleteNotebook(notebook.id)
            default: break
            }
        })
        menu.present(slots, around: frame, title: notebook.title)
    }

    private static func title(_ action: String) -> String {
        switch action {
        case "open": return "Open"
        case "rename": return "Rename"
        case "delete_notebook": return "Delete"
        default: return action
        }
    }
}

struct PageThumbnail: View {
    let page: Page
    @AppStorage("showsGuides") private var showsGuides = true
    @State private var image: UIImage?
    @State private var renderedKey: String?

    private var key: String {
        "\(page.id)-\(page.updated.timeIntervalSince1970)-\(page.extent.columns)x\(page.extent.rows)-\(showsGuides)"
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear { render(size: proxy.size) }
            .onChange(of: key) { _, _ in render(size: proxy.size) }
        }
    }

    private func render(size: CGSize) {
        guard renderedKey != key, size.width > 0, size.height > 0 else { return }
        renderedKey = key
        image = PageRenderer.thumbnail(of: page, size: size, showsGuides: showsGuides)
    }
}
