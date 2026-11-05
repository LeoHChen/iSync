// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "iSyncCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "iSyncCore", targets: ["iSyncCore"]),
        .executable(name: "isync-check", targets: ["isync-check"]),
    ],
    targets: [
        // Homebrew's libimobiledevice. Its pkg-config file pulls in libplist,
        // and libimobiledevice links libusbmuxd itself.
        .systemLibrary(
            name: "CIMobileDevice",
            pkgConfig: "libimobiledevice-1.0",
            providers: [.brew(["libimobiledevice", "libplist", "libusbmuxd"])]
        ),
        .target(
            name: "iSyncCore",
            dependencies: ["CIMobileDevice"],
            // Xcode may not find Homebrew's pkg-config, so name the paths too.
            cSettings: [.unsafeFlags(["-I/opt/homebrew/include"])],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I/opt/homebrew/include"])],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib"]),
                .linkedLibrary("imobiledevice-1.0"),
                .linkedLibrary("plist-2.0"),
            ]
        ),
        // Runs the real engine against a connected iPhone from the command line.
        .executableTarget(name: "isync-check", dependencies: ["iSyncCore"]),
        .testTarget(name: "iSyncCoreTests", dependencies: ["iSyncCore"]),
    ]
)
