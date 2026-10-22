import AppKit

@MainActor
enum CommanderAppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var menuTitle: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

@MainActor
enum CommanderAppearancePreference {
    private static let defaultsKey = "CommanderAppearanceMode"

    static var mode: CommanderAppearanceMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let value = CommanderAppearanceMode(rawValue: raw) else {
                return .system
            }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func applyToApplication() {
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
