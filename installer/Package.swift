// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YapperCordInstaller",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "YapperCordInstaller", targets: ["YapperCordInstaller"])],
    targets: [
        .target(name: "InstallerCore"),
        .executableTarget(name: "YapperCordInstaller", dependencies: ["InstallerCore"], swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "InstallerCoreTests", dependencies: ["InstallerCore"])
    ],
    swiftLanguageModes: [.v6]
)
