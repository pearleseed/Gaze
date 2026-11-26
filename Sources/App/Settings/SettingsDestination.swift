import SwiftUI

private struct SearchDestinationHighlight: ViewModifier {
	let section: String
	let highlightedSection: String?
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	func body(content: Content) -> some View {
		content.overlay {
			RoundedRectangle(cornerRadius: Theme.cornerRadius)
				.fill(Theme.selection)
				.opacity(highlightedSection == section ? 1 : 0)
				.animation(reduceMotion ? nil : Theme.Motion.quick, value: highlightedSection == section)
				.allowsHitTesting(false)
				.accessibilityHidden(true)
		}
	}
}

extension View {
	func settingsDestination(_ section: String, highlightedSection: String?) -> some View {
		id(section)
			.modifier(SearchDestinationHighlight(section: section, highlightedSection: highlightedSection))
	}
}
