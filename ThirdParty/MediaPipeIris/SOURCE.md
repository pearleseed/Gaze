# MediaPipe Iris landmarks

`IrisLandmarks.mlmodelc` is the compiled build of Google's MediaPipe Iris landmark
model (Copyright Google LLC, Apache 2.0, https://github.com/google-ai-edge/mediapipe),
via the PyTorch port at
https://github.com/cedriclmenard/irislandmarks.pytorch (Apache 2.0, LICENSE here),
converted to Core ML with coremltools 9.0. Input: a 64x64 RGB eye crop scaled to 0...1.
Outputs: `iris` (5 points: centre then four edge points) and `contour` (71 eye points),
each (x, y, z) in crop pixels.
