import NotesCore
import SwiftUI

struct NotebookScreen: View {
    let notebookId: String

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 18)]

    var body: some View {
        let pages = library.pages(in: notebookId)
        let title = library.notebook(notebookId)?.title ?? "Notebook"
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                TopBar(title: title, label: "\(pages.count) page\(pages.count == 1 ? "" : "s")", onBack: { navigator.go(.library) }) {
                    SyncBadge(sync: library.sync)
                }
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                            PageTile(notebookId: notebookId, page: page, number: index + 1)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .padding(.bottom, 140)
                }
            }
            PopBar(groups: [[
                PopBarItem(id: "notebook-back", glyph: .back, tint: Palette.navigation, action: { navigator.go(.library) }),
                PopBarItem(id: "new-page", glyph: .plus, tint: Palette.create, isActive: true, action: addPage),
            ]])
            .padding(.bottom, 24)
        }
    }

    private func addPage() {
        let page = library.createPage(in: notebookId)
        navigator.go(.page(notebookId: notebookId, pageId: page.id))
    }
}

private struct PageTile: View {
    let notebookId: String
    let page: Page
    let number: Int

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var menu: MenuController
    @State private var isShown = false

    var body: some View {
        HoldableButton(pressedScale: 0.97, action: open, onHold: showMenu) {
            VStack(alignment: .leading, spacing: 10) {
                PageThumbnail(page: page)
                    .aspectRatio(CGFloat(PaperGeometry.width(of: page.extent) / PaperGeometry.height(of: page.extent)), contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(Squircle(radius: 6))
                HStack {
                    MicroLabel(text: String(format: "%02d", number), color: Palette.textBright)
                    Spacer()
                    if page.extent.cellCount > 1 {
                        MicroLabel(text: "\(page.extent.columns)×\(page.extent.rows)")
                    }
                }
            }
            .padding(12)
            .background(Squircle.tile.fill(Palette.panelSolid))
            .overlay(Squircle.tile.stroke(Palette.border, lineWidth: 1))
        }
        .opacity(isShown ? 1 : 0)
        .offset(y: isShown ? 0 : 14)
        .scaleEffect(isShown ? 1 : 0.94)
        .onAppear {
            withAnimation(Motion.powerTwoOut(240, delay: min(number - 1, 16) * 12)) {
                isShown = true
            }
        }
    }

    private func open() {
        navigator.go(.page(notebookId: notebookId, pageId: page.id))
    }

    private func showMenu(_ frame: CGRect) {
        let slots = MenuSlot.fromTokens(Tokens.shared.menus.pageTile, title: Self.title, perform: { action in
            switch action {
            case "open":
                open()
            case "new_page":
                let created = library.createPage(in: notebookId)
                navigator.go(.page(notebookId: notebookId, pageId: created.id))
            case "delete_page":
                library.deletePage(page.id)
            default:
                break
            }
        })
        menu.present(slots, around: frame, title: "Page \(number)")
    }

    private static func title(_ action: String) -> String {
        switch action {
        case "open": return "Open"
        case "new_page": return "New page"
        case "delete_page": return "Delete"
        default: return action
        }
    }
}
