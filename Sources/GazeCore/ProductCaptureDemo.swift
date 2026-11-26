import Foundation

/// Lets the product-capture tool photograph a finished setup instead of a fresh install.
///
/// Always false in the shipping app: the switch exists only when the capture tool builds
/// these sources with `-D PRODUCT_CAPTURE`, and even then only with `--demo-state`.
package enum ProductCaptureDemo {
	package static var isOn: Bool {
		#if PRODUCT_CAPTURE
		CommandLine.arguments.contains("--demo-state")
		#else
		false
		#endif
	}
}
