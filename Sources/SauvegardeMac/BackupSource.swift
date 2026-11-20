import BackupCore
import Foundation

/// Application dont l'ouverture pendant la sauvegarde risque de produire une copie incohérente.
struct WatchedApp: Hashable {
    let frenchName: String
    let englishName: String
    let bundleID: String

    var name: String { tr(frenchName, englishName) }
}

/// Élément proposé à la sauvegarde. Pour ajouter une source, ajouter une entrée dans `all`.
struct BackupSource: Identifiable, Hashable {
    enum Kind: Hashable {
        /// Dossier synchronisé dans `<destination>/<nom du dossier>/`.
        case folder(URL)
        /// Inventaire écrit dans `<destination>/applications.txt`.
        case appList
    }

    let id: String
    let frenchLabel: String
    let englishLabel: String
    /// Symbole SF affiché dans le journal.
    let symbol: String
    let kind: Kind
    let watchedApps: [WatchedApp]
    let isDefault: Bool

    var label: String { tr(frenchLabel, englishLabel) }

    /// Nom affiché d'un élément du journal, dans la langue courante (l'historique enregistre
    /// le nom dans la langue du moment de la sauvegarde).
    static func label(for report: SourceReport) -> String {
        all.first { $0.id == report.id }?.label ?? report.label
    }

    var folderURL: URL? {
        if case .folder(let url) = kind { return url }
        return nil
    }

    static let all: [BackupSource] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            BackupSource(id: "documents", frenchLabel: "Documents", englishLabel: "Documents", symbol: "doc.fill",
                         kind: .folder(home.appendingPathComponent("Documents")),
                         watchedApps: [], isDefault: true),
            BackupSource(id: "pictures", frenchLabel: "Images", englishLabel: "Pictures", symbol: "photo.fill",
                         kind: .folder(home.appendingPathComponent("Pictures")),
                         watchedApps: [WatchedApp(frenchName: "Photos", englishName: "Photos", bundleID: "com.apple.Photos")],
                         isDefault: true),
            BackupSource(id: "music", frenchLabel: "Musique", englishLabel: "Music", symbol: "music.note",
                         kind: .folder(home.appendingPathComponent("Music")),
                         watchedApps: [WatchedApp(frenchName: "Musique", englishName: "Music", bundleID: "com.apple.Music")],
                         isDefault: true),
            BackupSource(id: "movies", frenchLabel: "Vidéos", englishLabel: "Movies", symbol: "film.fill",
                         kind: .folder(home.appendingPathComponent("Movies")),
                         watchedApps: [WatchedApp(frenchName: "iMovie", englishName: "iMovie", bundleID: "com.apple.iMovieApp")],
                         isDefault: true),
            BackupSource(id: "applist", frenchLabel: "Liste des applications",
                         englishLabel: "Application list", symbol: "square.grid.2x2.fill",
                         kind: .appList, watchedApps: [], isDefault: true),
        ]
    }()
}
