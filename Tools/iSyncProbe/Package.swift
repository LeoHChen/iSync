// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "iSyncProbe",
    platforms: [.macOS(.v14)],
    targets: [
        // Homebrew's libimobiledevice, found through pkg-config. Its .pc file
        // pulls in libplist, and libusbmuxd is linked through libimobiledevice.
        .systemLibrary(
            name: "CIMobileDevice",
            pkgConfig: "libimobiledevice-1.0",
            providers: [.brew(["libimobiledevice", "libplist", "libusbmuxd"])]
        ),
        .executableTarget(
            name: "iSyncProbe",
            dependencies: ["CIMobileDevice"],
            linkerSettings: [
                .linkedFramework("ImageCaptureCore"),
                .linkedFramework("AVFoundation"),
                .linkedLibrary("sqlite3"),
                // Gives the bare executable an identity so ImageCaptureCore
                // treats it like an app.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Support/Info.plist",
                ]),
            ]
        ),
    ]
)
