// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WristNotesDiarization",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "WristNotesDiarization", targets: ["WristNotesDiarization"]),
        .executable(name: "SpeakerModelCheck", targets: ["SpeakerModelCheck"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: [])
    ],
    targets: [.target(name: "WristNotesDiarization", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
        path: ".", exclude: ["Tools"], sources: ["Sources/WristNotesDiarization"], resources: [.copy("Notices")]),
        .executableTarget(name: "SpeakerModelCheck", dependencies: ["WristNotesDiarization"], path: "Tools/SpeakerModelCheck")]
)
