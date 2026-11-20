import Foundation

/// Langue de l'interface, choisie dans l'application (indépendamment de celle du système).
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case french = "fr"
    case english = "en"

    public var id: String { rawValue }

    /// Nom affiché dans le sélecteur, dans sa propre langue.
    public var displayName: String {
        switch self {
        case .french: return "Français"
        case .english: return "English"
        }
    }

    /// Drapeau affiché dans le sélecteur.
    public var flag: String {
        switch self {
        case .french: return "🇫🇷"
        case .english: return "🇬🇧"
        }
    }

    public var locale: Locale {
        Locale(identifier: self == .french ? "fr_FR" : "en_US")
    }

    /// Français si c'est la langue préférée du système, anglais sinon.
    public static var systemDefault: AppLanguage {
        (Locale.preferredLanguages.first ?? "").hasPrefix("fr") ? .french : .english
    }
}

/// Traductions écrites dans le code : chaque texte existe dans les deux langues, côte à côte
/// (`tr("Annuler", "Cancel")`). Pas de fichiers .strings : l'app est assemblée à la main à partir
/// d'un exécutable SwiftPM, sans bundle de ressources, et un oubli de traduction est impossible.
public enum L10n {
    private static let lock = NSLock()
    private static var current: AppLanguage = .systemDefault

    /// Langue courante ; lue aussi depuis le thread de sauvegarde, d'où le verrou.
    public static var language: AppLanguage {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }

    // MARK: Formats

    /// Nombre avec séparateur de milliers (« 12 345 » / « 12,345 »).
    public static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = language.locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// « 3 fichiers » / « 3 files », avec les règles de pluriel de chaque langue
    /// (0 et 1 au singulier en français, 1 seul au singulier en anglais).
    public static func count(_ value: Int, _ frenchSingular: String, _ frenchPlural: String,
                             _ englishSingular: String, _ englishPlural: String) -> String {
        let word: String
        switch language {
        case .french: word = value <= 1 ? frenchSingular : frenchPlural
        case .english: word = value == 1 ? englishSingular : englishPlural
        }
        return "\(number(value)) \(word)"
    }

    /// Taille en unités décimales, comme le Finder (« 1,5 Go » / « 1.5 GB »).
    public static func bytes(_ value: Int64) -> String {
        let units = language == .french
            ? ["o", "Ko", "Mo", "Go", "To", "Po"]
            : ["bytes", "KB", "MB", "GB", "TB", "PB"]
        if value < 1000 {
            return "\(number(Int(value))) \(units[0])"
        }
        var amount = Double(value)
        var unit = 0
        while amount >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        let formatter = NumberFormatter()
        formatter.locale = language.locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = amount < 100 ? 1 : 0
        formatter.minimumFractionDigits = 0
        return "\(formatter.string(from: NSNumber(value: amount)) ?? String(amount)) \(units[unit])"
    }

    /// Durée courte : « 45 s », « 3 min 12 s », « 1 h 05 min » (identique dans les deux langues).
    public static func duration(seconds total: Int) -> String {
        let total = max(0, total)
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        if hours > 0 { return "\(hours) h " + String(format: "%02d", minutes) + " min" }
        if minutes > 0 { return "\(minutes) min \(seconds) s" }
        return "\(seconds) s"
    }

    public static func duration(from start: Date, to end: Date) -> String {
        duration(seconds: Int(end.timeIntervalSince(start)))
    }

    /// Date et heure (« 15 nov. 2026 à 14:03 » / « Nov 15, 2026 at 2:03 PM »).
    public static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// Texte dans la langue de l'interface.
public func tr(_ french: String, _ english: String) -> String {
    L10n.language == .french ? french : english
}
