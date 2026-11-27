// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "Gaze",
	platforms: [
		.macOS("26.0"),
	],
	products: [
		.library(name: "GazeCore", targets: ["GazeCore"]),
		.library(name: "GazeTourKit", targets: ["GazeTourKit"]),
		.library(name: "GazeDesign", targets: ["GazeDesign"]),
		.library(name: "GazeCamera", targets: ["GazeCamera"]),
		.library(name: "GazeRecognition", targets: ["GazeRecognition"]),
		.library(name: "GazeLockScreen", targets: ["GazeLockScreen"]),
		.library(name: "GazeSecurity", targets: ["GazeSecurity"]),
		.library(name: "GazeUpdates", targets: ["GazeUpdates"]),
		.library(name: "GazeApp", targets: ["GazeApp"]),
	],
	dependencies: [
		.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
	],
	targets: [
		.target(
			name: "GazeCore",
			dependencies: [],
			swiftSettings: [.swiftLanguageMode(.v6)]
		),
		.target(
			name: "GazeTourKit",
			dependencies: [],
			swiftSettings: [.swiftLanguageMode(.v6)]
		),
		.target(
			name: "GazeDesign",
			dependencies: ["GazeCore"],
			swiftSettings: [.swiftLanguageMode(.v6)]
		),
		.target(
			name: "GazeCamera",
			dependencies: ["GazeCore"],
			swiftSettings: [.swiftLanguageMode(.v6)]
		),
		.target(
			name: "GazeRecognition",
			dependencies: ["GazeCore", "GazeCamera"],
			swiftSettings: [.swiftLanguageMode(.v6)]
		),
		.target(
			name: "GazeLockScreen",
			dependencies: ["GazeCore", "GazeDesign", "GazeRecognition"],
			swiftSettings: [.swiftLanguageMode(.v6)]
		),
		.target(
			name: "GazeSecurity",
			dependencies: ["GazeCore", "GazeCamera", "GazeRecognition", "GazeLockScreen"],
			swiftSettings: [.swiftLanguageMode(.v6)]
		),
		.target(
			name: "GazeUpdates",
			dependencies: [
				"GazeCore",
				.product(name: "Sparkle", package: "Sparkle"),
			],
			swiftSettings: [.swiftLanguageMode(.v6)]
		),
		.target(
			name: "GazeApp",
			dependencies: [
				"GazeCore",
				"GazeDesign",
				"GazeTourKit",
				"GazeCamera",
				"GazeRecognition",
				"GazeLockScreen",
				"GazeSecurity",
				"GazeUpdates",
			],
			swiftSettings: [.swiftLanguageMode(.v6)]
		),
		.testTarget(
			name: "GazeUpdatesTests",
			dependencies: ["GazeUpdates", "GazeCore"],
			swiftSettings: [.swiftLanguageMode(.v6)]
		),
		.testTarget(
			name: "GazeCameraTests",
			dependencies: ["GazeCamera", "GazeCore", "GazeRecognition"],
			swiftSettings: [.swiftLanguageMode(.v6)]
		),
		.testTarget(
			name: "GazeRecognitionTests",
			dependencies: ["GazeRecognition", "GazeCamera", "GazeCore", "GazeSecurity", "GazeApp"],
			swiftSettings: [.swiftLanguageMode(.v6)]
		),
		.testTarget(
			name: "GazeCoreTests",
			dependencies: ["GazeCore", "GazeCamera", "GazeRecognition", "GazeSecurity", "GazeUpdates", "GazeApp"],
			path: "Tests/GazeCoreTests",
			swiftSettings: [.swiftLanguageMode(.v6)]
		),
		.testTarget(
			name: "GazeSecurityTests",
			dependencies: ["GazeSecurity", "GazeCore", "GazeCamera", "GazeRecognition", "GazeLockScreen", "GazeUpdates"],
			path: "Tests/GazeSecurityTests",
			swiftSettings: [.swiftLanguageMode(.v6)]
		),
		.testTarget(
			name: "GazeUITests",
			dependencies: ["GazeApp", "GazeDesign", "GazeLockScreen", "GazeCore", "GazeTourKit", "GazeRecognition", "GazeSecurity"],
			path: "Tests/GazeUITests",
			swiftSettings: [.swiftLanguageMode(.v6)]
		),
	]
)
