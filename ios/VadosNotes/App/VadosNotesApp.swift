import SwiftUI

@main
struct VadosNotesApp: App {
    @StateObject private var library = Library.open()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
        }
    }
}
