import Foundation

struct NoteView: Equatable {
    let scale: Double
    let centerX: Double
    let centerY: Double
}

enum SessionMemory {
    private static let viewsKey = "noteViews"
    private static let routeKey = "lastRoute"
    private static let viewLimit = 300
    private static let flushDelay: TimeInterval = 0.4
    private static var pending: [String: [Double]] = [:]
    private static var flushWork: DispatchWorkItem?

    private static var defaults: UserDefaults {
        .standard
    }

    private static func storedViews() -> [String: [Double]] {
        defaults.dictionary(forKey: viewsKey) as? [String: [Double]] ?? [:]
    }

    static func view(for pageId: String) -> NoteView? {
        guard let values = pending[pageId] ?? storedViews()[pageId], values.count >= 3, values[0] > 0 else { return nil }
        return NoteView(scale: values[0], centerX: values[1], centerY: values[2])
    }

    static func remember(_ view: NoteView, for pageId: String) {
        pending[pageId] = [view.scale, view.centerX, view.centerY, Date().timeIntervalSince1970]
        flushWork?.cancel()
        let work = DispatchWorkItem { flush() }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + flushDelay, execute: work)
    }

    static func flush() {
        flushWork?.cancel()
        flushWork = nil
        guard !pending.isEmpty else { return }
        var views = storedViews()
        views.merge(pending) { _, next in next }
        pending = [:]
        if views.count > viewLimit {
            let kept = views.sorted { ($0.value.last ?? 0) > ($1.value.last ?? 0) }.prefix(viewLimit)
            views = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        defaults.set(views, forKey: viewsKey)
    }

    static func rememberRoute(_ route: Route) {
        switch route {
        case .library:
            defaults.set(["kind": "library"], forKey: routeKey)
        case .notebook(let notebookId):
            defaults.set(["kind": "notebook", "notebook": notebookId], forKey: routeKey)
        case .page(let notebookId, let pageId):
            defaults.set(["kind": "page", "notebook": notebookId, "page": pageId], forKey: routeKey)
        }
    }

    static func lastRoute() -> Route? {
        guard let stored = defaults.dictionary(forKey: routeKey) as? [String: String] else { return nil }
        switch stored["kind"] {
        case "notebook":
            return stored["notebook"].map(Route.notebook)
        case "page":
            guard let notebookId = stored["notebook"], let pageId = stored["page"] else { return nil }
            return .page(notebookId: notebookId, pageId: pageId)
        default:
            return nil
        }
    }
}
