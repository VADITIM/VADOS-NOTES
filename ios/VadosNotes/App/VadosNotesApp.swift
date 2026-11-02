import SwiftUI

@main
struct VadosNotesApp: App {
    @StateObject private var library = Library.open()

    init() {
        UserFonts.registerStored()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
        }
    }
}
