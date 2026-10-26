// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotesCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NotesCore", targets: ["NotesCore"]),
    ],
    targets: [
        .target(name: "NotesCore"),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore"]),
    ]
)
