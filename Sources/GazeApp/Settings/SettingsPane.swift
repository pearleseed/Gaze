enum SettingsPane: String, CaseIterable, Hashable, Identifiable {
	case face, movements, security, attempts, apps, notch, general, about, credits

	static let toolbarPanes: [Self] = [.face, .security, .apps, .notch, .general, .about]

	var id: String { rawValue }

	var title: String {
		switch self {
		case .general: return "General"
		case .notch: return "Notch"
		case .face: return "Unlock"
		case .movements: return "Movements"
		case .security: return "Security"
		case .attempts: return "Unlock Attempts"
		case .apps: return "App Lock"
		case .credits: return "Credits"
		case .about: return "About"
		}
	}

	var symbol: String {
		switch self {
		case .general: return "gearshape"
		case .notch: return "macbook"
		case .face: return "faceid"
		case .movements: return "figure.run"
		case .security: return "lock.shield"
		case .attempts: return "clock.arrow.circlepath"
		case .apps: return "lock.app.dashed"
		case .credits: return "heart.fill"
		case .about: return "info.circle"
		}
	}
}
