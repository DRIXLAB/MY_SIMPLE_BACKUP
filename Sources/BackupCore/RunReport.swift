import Foundation

/// Compte rendu d'un élément pendant et après une sauvegarde.
public struct SourceReport: Identifiable, Equatable, Codable, Sendable {
    public enum Status: String, Equatable, Codable, Sendable {
        case pending, running, success, warning, failed, cancelled
    }

    public let id: String
    public let label: String
    /// Symbole SF affiché dans le journal.
    public let symbol: String
    public var status: Status = .pending
    /// Résumé figé dans la langue du moment (anciennes entrées de l'historique uniquement) ;
    /// désormais recalculé dans la langue courante par `displaySummary` à partir des compteurs.
    public var summary: String?
    /// Erreur bloquante (dossier introuvable, accès refusé…).
    public var message: String?
    /// Éléments non copiés, chemin relatif et raison (tronqué dans l'historique).
    public var issues: [String] = []
    /// Nombre réel d'éléments non copiés, même si `issues` a été tronqué.
    public var issueCount = 0
    public var copiedFiles = 0
    public var copiedBytes: Int64 = 0
    public var startedAt: Date?
    public var finishedAt: Date?
    // Compteurs ajoutés après coup : optionnels pour que l'historique existant reste lisible.
    public var sourceFiles: Int?
    public var deletedItems: Int?
    public var skippedItems: Int?
    /// Nombre d'applications inventoriées (élément « Liste des applications »).
    public var applicationCount: Int?

    /// Résumé dans la langue courante (« 12 345 fichiers · 42 copiés · 1,2 Go »).
    public var displaySummary: String? {
        switch status {
        case .pending, .running:
            return nil
        case .cancelled:
            return startedAt == nil
                ? tr("Non sauvegardé", "Not backed up")
                : tr("Interrompu — les fichiers déjà copiés sont complets",
                     "Interrupted — files already copied are complete")
        case .success, .warning, .failed:
            if let apps = applicationCount {
                return L10n.count(apps, "application", "applications", "application", "applications")
                    + "  ·  " + AppInventory.fileName
            }
            guard let files = sourceFiles else { return summary }
            var parts = [L10n.count(files, "fichier", "fichiers", "file", "files")]
            parts.append(copiedFiles == 0
                ? tr("aucun nouveau fichier", "no new files")
                : L10n.count(copiedFiles, "copié", "copiés", "copied", "copied"))
            if let deleted = deletedItems, deleted > 0 {
                parts.append(L10n.count(deleted, "supprimé", "supprimés", "deleted", "deleted"))
            }
            if let skipped = skippedItems, skipped > 0 {
                parts.append(L10n.count(skipped, "ignoré", "ignorés", "skipped", "skipped"))
            }
            if copiedBytes > 0 { parts.append(L10n.bytes(copiedBytes)) }
            return parts.joined(separator: "  ·  ")
        }
    }

    public init(id: String, label: String, symbol: String) {
        self.id = id
        self.label = label
        self.symbol = symbol
    }
}

/// Journal structuré d'une sauvegarde ; les sauvegardes terminées sont conservées par `HistoryStore`.
public struct RunReport: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let destination: URL
    public let deleteMode: Bool
    public var sources: [SourceReport]
    public var finishedAt: Date?
    public var cancelled = false

    public init(id: UUID = UUID(), startedAt: Date, destination: URL, deleteMode: Bool, sources: [SourceReport]) {
        self.id = id
        self.startedAt = startedAt
        self.destination = destination
        self.deleteMode = deleteMode
        self.sources = sources
    }

    public var isFinished: Bool { finishedAt != nil }

    /// Éléments terminés avec avertissement ou en échec.
    public var problemCount: Int {
        sources.filter { $0.status == .warning || $0.status == .failed }.count
    }

    public var running: SourceReport? { sources.first { $0.status == .running } }

    public var copiedFiles: Int { sources.reduce(0) { $0 + $1.copiedFiles } }
    public var copiedBytes: Int64 { sources.reduce(0) { $0 + $1.copiedBytes } }

    /// Titre de l'état global (« En cours », « Terminée », « 2 problèmes », « Annulée »).
    public var statusTitle: String {
        if !isFinished { return tr("En cours", "In progress") }
        if cancelled { return tr("Annulée", "Cancelled") }
        if problemCount == 0 { return tr("Terminée", "Completed") }
        return L10n.count(problemCount, "problème", "problèmes", "problem", "problems")
    }

    /// Version texte, pour « Copier le journal ».
    /// - Parameter label: nom affiché d'un élément (par défaut celui enregistré).
    public func plainText(duration: String, label: (SourceReport) -> String = { $0.label }) -> String {
        var lines = [
            tr("Sauvegarde du ", "Backup of ") + "\(L10n.dateTime(startedAt)) — \(statusTitle) (\(duration))",
            tr("Destination : ", "Destination: ") + destination.path,
        ]
        if deleteMode { lines.append(tr("Mode suppression activé", "Deletion mode enabled")) }
        for source in sources {
            let mark: String
            switch source.status {
            case .pending: mark = "·"
            case .running: mark = "…"
            case .success: mark = "✓"
            case .warning: mark = "⚠"
            case .failed: mark = "✗"
            case .cancelled: mark = "■"
            }
            lines.append("")
            lines.append("\(mark) \(label(source))")
            if let summary = source.displaySummary { lines.append("  \(summary)") }
            if let message = source.message { lines.append("  \(message)") }
            for issue in source.issues { lines.append("  - \(issue)") }
            let hidden = source.issueCount - source.issues.count
            if hidden > 0 {
                lines.append(tr("  … et \(hidden) autre(s) non conservé(s) dans l'historique",
                                "  … and \(hidden) more not kept in the history"))
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Historique des sauvegardes terminées, stocké en JSON (le plus récent en premier).
public struct HistoryStore: Sendable {
    public let fileURL: URL
    /// Nombre de sauvegardes conservées.
    public let maxRuns: Int
    /// Éléments non copiés conservés par élément sauvegardé, pour limiter la taille du fichier.
    public let maxIssuesPerSource: Int

    public init(fileURL: URL, maxRuns: Int = 100, maxIssuesPerSource: Int = 200) {
        self.fileURL = fileURL
        self.maxRuns = maxRuns
        self.maxIssuesPerSource = maxIssuesPerSource
    }

    /// `~/Library/Application Support/com.cepe.sauvegarde-mac/history.json`
    public static var `default`: HistoryStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return HistoryStore(fileURL: support.appendingPathComponent("com.cepe.sauvegarde-mac/history.json"))
    }

    /// Historique enregistré ; vide si le fichier est absent ou illisible.
    public func load() -> [RunReport] {
        loadReportingProblems().runs
    }

    /// Comme `load()`, mais un fichier illisible (abîmé, format d'une autre version) est d'abord
    /// déplacé à côté (`history.illisible-<horodatage>.json`) au lieu d'être écrasé à la
    /// prochaine sauvegarde ; `movedAside` indique alors où il se trouve.
    public func loadReportingProblems() -> (runs: [RunReport], movedAside: URL?) {
        guard let data = try? Data(contentsOf: fileURL) else { return ([], nil) }
        if let runs = try? Self.decoder.decode([RunReport].self, from: data) {
            return (runs.sorted { $0.startedAt > $1.startedAt }, nil)
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = fileURL.deletingLastPathComponent()
            .appendingPathComponent("history.illisible-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: aside)
            return ([], aside)
        } catch {
            return ([], nil)
        }
    }

    public func save(_ runs: [RunReport]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Self.encoder.encode(runs).write(to: fileURL, options: .atomic)
    }

    /// Nouvel historique avec `run` en tête, limites appliquées (sans écrire sur le disque).
    public func appending(_ run: RunReport, to history: [RunReport]) -> [RunReport] {
        var trimmed = run
        for i in trimmed.sources.indices {
            trimmed.sources[i].issueCount = max(trimmed.sources[i].issueCount, trimmed.sources[i].issues.count)
            trimmed.sources[i].issues = Array(trimmed.sources[i].issues.prefix(maxIssuesPerSource))
        }
        return Array(([trimmed] + history.filter { $0.id != run.id }).prefix(maxRuns))
    }

    /// `appending` puis enregistrement.
    @discardableResult
    public func append(_ run: RunReport, to history: [RunReport]) throws -> [RunReport] {
        let updated = appending(run, to: history)
        try save(updated)
        return updated
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // JSON compact : le fichier peut contenir des milliers de lignes d'erreurs.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
