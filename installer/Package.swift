// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Yapinplugger",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Yapinplugger", targets: ["Yapinplugger"])],
    targets: [
        .target(name: "InstallerCore"),
        .executableTarget(name: "Yapinplugger", dependencies: ["InstallerCore"], path: "Sources/YapperCordInstaller", swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "InstallerCoreTests", dependencies: ["InstallerCore"])
    ],
    swiftLanguageModes: [.v6]
)
