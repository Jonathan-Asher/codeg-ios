// swift-tools-version: 6.0
//
// BlueTTSKit: on-device Hebrew/English text-to-speech (BlueTTS 2.5 + RenikudPlus G2P).
//
// Products
//   BlueTTSKit     MIT. Normalizer, auto <en> tagger, RenikudPlus G2P, BlueTTS synthesis.
//                  English phonemization is pluggable (`EnglishPhonemizer`).
//   BlueTTSEspeak  GPL-3.0-or-later. espeak-ng 1.52.0 compiled from source plus its
//                  English data, wrapped as an `EnglishPhonemizer`. Linking it makes the
//                  combined binary GPL-3; see README "Licensing".
//   OnnxRuntime    MIT. ONNX Runtime 1.30.0 and its Objective-C bindings (module
//                  `OnnxRuntimeBindings`), for other on-device models in the same app.
//   bluetts-cli    macOS-only benchmarking / golden-file tool (not for the app).

import PackageDescription

let package = Package(
    name: "BlueTTSKit",
    platforms: [
        .iOS("26.0"),
        .macOS(.v15),
    ],
    products: [
        .library(name: "BlueTTSKit", targets: ["BlueTTSKit"]),
        .library(name: "BlueTTSEspeak", targets: ["BlueTTSEspeak"]),
        // ONNX Runtime 1.30.0 itself (module `OnnxRuntimeBindings`), for other
        // packages in the app (SherpaOnnx, SmartTurn), so the app links one
        // runtime.
        .library(name: "OnnxRuntime", targets: ["OnnxRuntimeBindings"]),
        .executable(name: "bluetts-cli", targets: ["bluetts-cli"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "BlueTTSKit",
            dependencies: ["OnnxRuntimeBindings"]
        ),
        // ONNX Runtime 1.30.0: the official CocoaPods C/C++ archive (the same artifact
        // microsoft/onnxruntime-swift-package-manager wraps) plus its Objective-C
        // bindings, vendored unchanged from microsoft/onnxruntime v1.30.0 (MIT).
        // The official SPM repo stops at 1.24.2, whose int8 kernels flip three
        // RenikudPlus near-ties relative to the 1.30.0 reference; see README.
        // download.onnxruntime.ai stopped serving the archive on 2026-11-20, so
        // it comes from this repository's release onnxruntime-c-1.30.0: the same
        // contents (from the original, sha256 e6f1670c…a2ea), repacked.
        .binaryTarget(
            name: "onnxruntime",
            url: "https://github.com/Jonathan-Asher/codeg-ios/releases/download/onnxruntime-c-1.30.0/onnxruntime-c-1.30.0-xcframework.zip",
            checksum: "3a28547032843838807cf2aba617579ac4a12e77215f5f1baf86a0271953f1c0"
        ),
        .target(
            name: "OnnxRuntimeBindings",
            dependencies: ["onnxruntime"],
            path: "Sources/OnnxRuntimeBindings",
            exclude: ["LICENSE"],
            cxxSettings: [.define("SPM_BUILD")],
            linkerSettings: [
                // The 1.30 archive's CoreML EP references Network.framework (nw_path_*).
                .linkedFramework("CoreML"),
                .linkedFramework("Network"),
            ]
        ),
        .target(
            name: "CEspeakNG",
            path: "Sources/CEspeakNG",
            exclude: ["COPYING", "ucd-tools/COPYING"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("libespeak-ng"),
                .headerSearchPath("compat"),
                .headerSearchPath("private"),
                .headerSearchPath("ucd-tools/include"),
                .define("LIBESPEAK_NG_EXPORT", to: "1"),
                .define("PATH_ESPEAK_DATA", to: "\"\""),
            ]
        ),
        .target(
            name: "BlueTTSEspeak",
            dependencies: ["BlueTTSKit", "CEspeakNG"],
            resources: [.copy("Resources/espeak-ng-data")]
        ),
        .executableTarget(
            name: "bluetts-cli",
            dependencies: ["BlueTTSKit", "BlueTTSEspeak"]
        ),
        .testTarget(
            name: "BlueTTSKitTests",
            dependencies: ["BlueTTSKit", "BlueTTSEspeak"],
            resources: [.copy("Golden")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
