// swift-tools-version: 6.4
// pdfbook: reading PDFs as books on iOS 27+ / macOS 26+, on top of PDFKit.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ApproachableConcurrency"),
]

let package = Package(
    name: "pdfbook",
    platforms: [
        .iOS("27.0"),
        .macOS("26.0"),
    ],
    products: [
        // Foundation / CoreGraphics only: the fragment grammar (`page=` / `highlight=`), page coordinates, the text
        // model, positions. No PDFKit, no UI.
        .library(name: "PDFBookCore", targets: ["PDFBookCore"]),
        // PDFKit and SwiftUI: documents, the reader session and its view. Re-exports PDFBookCore.
        .library(name: "PDFBook", targets: ["PDFBook"]),
    ],
    targets: [
        .target(
            name: "PDFBookCore",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "PDFBook",
            dependencies: ["PDFBookCore"],
            swiftSettings: swiftSettings + [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "PDFBookCoreTests",
            dependencies: ["PDFBookCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "PDFBookTests",
            dependencies: ["PDFBook", "PDFBookCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
