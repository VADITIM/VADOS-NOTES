import NotesCore
import UIKit

enum NoteExport {
    private static let pointsPerMillimetre: CGFloat = 72 / 25.4

    @MainActor
    static func pdf(of page: Page, title: String, options: RenderOptions) -> URL? {
        let size = CGSize(width: CGFloat(PaperGeometry.width(of: page.extent)) * pointsPerMillimetre, height: CGFloat(PaperGeometry.height(of: page.extent)) * pointsPerMillimetre)
        let bounds = CGRect(origin: .zero, size: size)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let name = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name.isEmpty ? "Note" : name).pdf")
        var exportOptions = options
        exportOptions.pixelScale = 4
        do {
            try renderer.writePDF(to: url) { rendererContext in
                rendererContext.beginPage()
                let camera = CanvasCamera(scale: pointsPerMillimetre, offset: .zero)
                PageRenderer.draw(page, in: rendererContext.cgContext, camera: camera, visibleRect: bounds, options: exportOptions, cache: StrokePathCache())
            }
            return url
        } catch {
            return nil
        }
    }

    @MainActor
    static func share(_ url: URL) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard var presenter = scene?.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = presenter.view
        controller.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        controller.popoverPresentationController?.permittedArrowDirections = []
        presenter.present(controller, animated: true)
    }
}
