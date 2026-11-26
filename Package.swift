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
			dependencies: ["GazeCore"],
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
	]
)
