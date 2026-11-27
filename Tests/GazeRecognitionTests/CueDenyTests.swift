import CoreGraphics
import CoreVideo
import Foundation
import GazeRecognition
import Testing

@Suite("Passive Deny Cues — Device Bezel & Glare")
struct CueDenyTests {
	private func denyBuffer(width: Int, height: Int, grey: CGFloat) throws -> CVPixelBuffer {
		var buffer: CVPixelBuffer?
		let status = CVPixelBufferCreate(
			kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer
		)
		#expect(status == kCVReturnSuccess)
		let locked = try #require(buffer)
		CVPixelBufferLockBaseAddress(locked, [])
		defer { CVPixelBufferUnlockBaseAddress(locked, []) }
		let context = try #require(
			CGContext(
				data: CVPixelBufferGetBaseAddress(locked),
				width: width,
				height: height,
				bitsPerComponent: 8,
				bytesPerRow: CVPixelBufferGetBytesPerRow(locked),
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
			)
		)
		context.setFillColor(red: grey, green: grey, blue: grey, alpha: 1)
		context.fill(CGRect(x: 0, y: 0, width: width, height: height))
		return locked
	}

	private func denyPaintRect(_ buffer: CVPixelBuffer, _ rect: CGRect, grey: CGFloat) throws {
		CVPixelBufferLockBaseAddress(buffer, [])
		defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
		let context = try #require(
			CGContext(
				data: CVPixelBufferGetBaseAddress(buffer),
				width: CVPixelBufferGetWidth(buffer),
				height: CVPixelBufferGetHeight(buffer),
				bitsPerComponent: 8,
				bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
			)
		)
		context.setFillColor(red: grey, green: grey, blue: grey, alpha: 1)
		context.fill(rect)
	}

	@Test func deviceBezelFiresOnlyOnEnclosingScreenRectangle() throws {
		var bezel = DeviceBezelGate()
		let spoof = try denyBuffer(width: 224, height: 224, grey: 0.5)
		try denyPaintRect(spoof, CGRect(x: 20, y: 20, width: 184, height: 184), grey: 1)
		let face = CGRect(x: 70, y: 70, width: 84, height: 84)
		#expect(DeviceBezelGate.measure(crop: spoof, faceRect: face) >= DeviceBezelGate.fireLevel)
		let f1 = bezel.record(frame: spoof, faceRect: face)
		let f2 = bezel.record(frame: spoof, faceRect: face)
		let f3 = bezel.record(frame: spoof, faceRect: face)
		#expect(!f1)
		#expect(!f2)
		#expect(f3)

		// Head-sized outline must not fire.
		var outlineBezel = DeviceBezelGate()
		let outline = try denyBuffer(width: 224, height: 224, grey: 0.5)
		try denyPaintRect(outline, CGRect(x: 64, y: 64, width: 96, height: 96), grey: 1)
		for _ in 0..<4 {
			let fired = outlineBezel.record(frame: outline, faceRect: face)
			#expect(!fired)
		}

		// Background rectangle running off edge of view must not fire.
		var backgroundBezel = DeviceBezelGate()
		let background = try denyBuffer(width: 224, height: 224, grey: 0.5)
		try denyPaintRect(background, CGRect(x: 0, y: 30, width: 190, height: 194), grey: 1)
		for _ in 0..<4 {
			let fired = backgroundBezel.record(frame: background, faceRect: face)
			#expect(!fired)
		}

		// Rectangle beside the face must not fire.
		var besideBezel = DeviceBezelGate()
		let beside = try denyBuffer(width: 224, height: 224, grey: 0.5)
		try denyPaintRect(beside, CGRect(x: 124, y: 10, width: 96, height: 150), grey: 1)
		for _ in 0..<5 {
			let fired = besideBezel.record(frame: beside, faceRect: face)
			#expect(!fired)
		}
	}

	@Test func flatGreyAndSmallOrDimFacesNeverFireGlareOrBezel() throws {
		let face = CGRect(x: 70, y: 70, width: 84, height: 84)
		var quietBezel = DeviceBezelGate()
		var quietGlare = GlareCue()
		let flat = try denyBuffer(width: 224, height: 224, grey: 0.5)
		for _ in 0..<3 {
			let b = quietBezel.record(frame: flat, faceRect: face)
			let g = quietGlare.record(frame: flat, faceRect: face)
			#expect(!b)
			#expect(!g)
		}
		#expect(!quietBezel.fired && !quietGlare.fired)

		// Below 50 px of face, glare cue abstains.
		var small = GlareCue()
		let bright = try denyBuffer(width: 224, height: 224, grey: 1)
		let tinyFace = CGRect(x: 92, y: 92, width: 40, height: 40)
		for _ in 0..<3 {
			let fired = small.record(frame: bright, faceRect: tinyFace)
			#expect(!fired)
		}
		#expect(!small.fired && small.confidence == 0)

		// Dim face with small bright reflection abstains.
		var dim = GlareCue()
		let dark = try denyBuffer(width: 224, height: 224, grey: 0.15)
		let dimFace = CGRect(x: 37, y: 37, width: 150, height: 150)
		try denyPaintRect(dark, CGRect(x: 100, y: 100, width: 30, height: 30), grey: 1)
		for _ in 0..<5 {
			let fired = dim.record(frame: dark, faceRect: dimFace)
			#expect(!fired)
		}
		#expect(!dim.fired && dim.confidence == 0)
	}
}
