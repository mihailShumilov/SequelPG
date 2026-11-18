// swift-tools-version:5.9
import PackageDescription

// `sequelpg-uitest`: drives the real SequelPG app through the macOS
// accessibility API, in the background, without taking the mouse or focus.
let package = Package(
    name: "SequelPGUITest",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "sequelpg-uitest", targets: ["SequelPGUITest"])],
    targets: [.executableTarget(name: "SequelPGUITest", path: "Sources/SequelPGUITest")]
)
