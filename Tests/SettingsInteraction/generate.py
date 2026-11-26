#!/usr/bin/env python3
"""Build the camera-permission fixture with fake system authorization."""
from pathlib import Path
import hashlib
import json
import sys

root = Path(__file__).resolve().parents[2]
destination = Path(sys.argv[1])
capture = (root / "Sources/Setup/SetupCaptureStep.swift").read_text()
assert capture.count("AVCaptureDevice.") == 4
destination.write_text(capture.replace("AVCaptureDevice.", "FixtureCameraAuthorization."))
destination.with_suffix(".json").write_text(json.dumps({
    "source": "Sources/Setup/SetupCaptureStep.swift",
    "sha256": hashlib.sha256(capture.encode()).hexdigest(),
    "replacement": "AVCaptureDevice static permission calls replaced by FixtureCameraAuthorization; view and actions unchanged",
    "camera": "Tests/Onboarding/Stubs.swift"
}, indent=2) + "\n")
