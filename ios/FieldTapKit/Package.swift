// swift-tools-version: 6.2
// FieldTapKit: everything in the FieldTap iOS app that is not a view. One target per work package, so each
// package owner edits only their own folder; see ios/README.md for who owns what. After WP0 nobody edits
// this file: ask for a change in the integration report instead.
//
// FT_HARNESS reaches only the app module (Harness is an app build configuration), so nothing in here may
// depend on it. Code that only the DEBUG/Harness hooks call (LaunchPlan, ScreenReport) is plain logic and
// is dead-stripped from a Release app that never references it.
import PackageDescription

let package = Package(
    name: "FieldTapKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(
            name: "FieldTapKit",
            targets: ["FTModel", "FTCore", "FTSignalling", "FTPresentation", "FTCapture", "FTPhy", "FTJourney", "FTApp"]
        ),
    ],
    targets: [
        // Shared value types, time base, masking and the golden-JSON codec (WP0; Journey*/Phy*/Capture* files
        // belong to WP5/WP4/WP3).
        .target(name: "FTModel"),
        // HDLC, DIAG log packets, log codes, spectrum, formatting, the streaming sysdiagnose scanner (WP0).
        .target(name: "FTCore", dependencies: ["FTModel"], linkerSettings: [.linkedLibrary("z")]),
        // Call-flow decoders: LTE/NR RRC, NAS, cell info (WP2).
        .target(name: "FTSignalling", dependencies: ["FTModel", "FTCore"]),
        // Ladder rows, procedure groups and the strings the call-flow screens show (WP6).
        .target(name: "FTPresentation", dependencies: ["FTModel", "FTCore"]),
        // QDSS deframer, sysdiagnose importer, capture store, profile stub reader (WP3).
        .target(name: "FTCapture", dependencies: ["FTModel", "FTCore"]),
        // PHY/MAC decoders, series queries, availability catalogue (WP4).
        .target(name: "FTPhy", dependencies: ["FTModel", "FTCore"]),
        // Journey lanes, markers, findings, KPI tiles (WP5). Reads PHY series through FTPhy's PhyQuery.
        .target(name: "FTJourney", dependencies: ["FTModel", "FTCore", "FTPhy"]),
        // App state and orchestration that is testable without a view: AppModel, CaptureSession, Analyzer,
        // FixtureLoader, LaunchPlan, ScreenReport (WP0).
        .target(
            name: "FTApp",
            dependencies: ["FTModel", "FTCore", "FTSignalling", "FTPresentation", "FTCapture", "FTPhy", "FTJourney"]
        ),
        // Fixture lookup, FT_REQUIRE_FIXTURES and JSON assertions for every test target (WP0).
        .target(name: "FTTestSupport", dependencies: ["FTModel", "FTCore"]),

        .testTarget(name: "FTModelTests", dependencies: ["FTModel", "FTCore", "FTTestSupport"],
                    resources: [.copy("TestData")]),
        .testTarget(name: "FTCoreTests", dependencies: ["FTCore", "FTModel", "FTTestSupport"],
                    resources: [.copy("TestData")]),
        .testTarget(name: "FTSignallingTests", dependencies: ["FTSignalling", "FTModel", "FTCore", "FTTestSupport"],
                    resources: [.copy("TestData")]),
        .testTarget(name: "FTPresentationTests", dependencies: ["FTPresentation", "FTModel", "FTCore", "FTTestSupport"],
                    resources: [.copy("TestData")]),
        .testTarget(name: "FTCaptureTests", dependencies: ["FTCapture", "FTModel", "FTCore", "FTTestSupport"],
                    resources: [.copy("TestData")]),
        .testTarget(name: "FTPhyTests", dependencies: ["FTPhy", "FTModel", "FTCore", "FTTestSupport"],
                    resources: [.copy("TestData")]),
        .testTarget(name: "FTJourneyTests", dependencies: ["FTJourney", "FTPhy", "FTModel", "FTCore", "FTTestSupport"],
                    resources: [.copy("TestData")]),
        .testTarget(name: "FTAppTests", dependencies: ["FTApp", "FTModel", "FTCore", "FTCapture", "FTTestSupport"],
                    resources: [.copy("TestData")]),
    ]
)
