#!/usr/bin/env python3
"""Build the camera-permission fixture with fake system authorization."""
from pathlib import Path
import hashlib
import json
import sys

root = Path(__file__).resolve().parents[4]
destination = Path(sys.argv[1])
capture = (root / "Sources/GazeApp/Setup/SetupCaptureStep.swift").read_text()
assert capture.count("AVCaptureDevice.") == 4
destination.write_text(capture.replace("AVCaptureDevice.", "FixtureCameraAuthorization."))
destination.with_suffix(".json").write_text(json.dumps({
    "source": "Sources/GazeApp/Setup/SetupCaptureStep.swift",
    "sha256": hashlib.sha256(capture.encode()).hexdigest(),
    "replacement": "AVCaptureDevice static permission calls replaced by FixtureCameraAuthorization; view and actions unchanged",
    "camera": "Tests/Scripts/AppIntegration/SettingsInteraction/Stubs.swift"
}, indent=2) + "\n")
