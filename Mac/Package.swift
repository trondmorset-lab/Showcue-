// swift-tools-version:5.9
// ShowCue for macOS. Åpne denne fila i Xcode og trykk ▶ (Run), eller kjør ./build-app.sh for å lage ShowCue.app.
import PackageDescription

let package = Package(
    name: "ShowCue",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ShowCue", targets: ["ShowCue"]),
    ],
    targets: [
        .executableTarget(
            name: "ShowCue",
            path: "Sources/ShowCue",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("PDFKit"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "ShowCueTests",
            dependencies: ["ShowCue"],
            path: "Tests/ShowCueTests"
        ),
    ]
)
