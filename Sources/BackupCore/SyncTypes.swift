import Foundation

/// Options d'une synchronisation `source/ → destination/` (équivalent de `rsync -a --safe-links`).
public struct SyncOptions: Sendable {
    /// Supprime de la destination les éléments absents de la source (équivalent `--delete`).
    public var deleteExtraneous: Bool
    /// Tolérance sur les dates de modification, en secondes (FAT/HFS+ arrondissent les dates).
    public var modifyWindow: TimeInterval
    /// Taille des blocs lus/écrits pendant la copie d'un fichier.
    public var chunkSize: Int

    public init(deleteExtraneous: Bool = false, modifyWindow: TimeInterval = 2, chunkSize: Int = 4 << 20) {
        self.deleteExtraneous = deleteExtraneous
        self.modifyWindow = modifyWindow
        self.chunkSize = chunkSize
    }
}

/// Problème non bloquant rencontré sur un élément : la synchronisation continue.
public struct SyncIssue: Sendable, Equatable, CustomStringConvertible {
    /// Chemin relatif à la racine de la source (vide = racine).
    public let path: String
    public let message: String

    public var description: String { path.isEmpty ? message : tr("\(path) : \(message)", "\(path): \(message)") }
}

public struct SyncStats: Sendable, Equatable {
    /// Nombre de fichiers ordinaires présents dans la source.
    public var sourceFiles = 0
    public var copiedFiles = 0
    public var copiedBytes: Int64 = 0
    /// Éléments supprimés de la destination (option `deleteExtraneous`), sous-dossiers comptés pour un.
    public var deletedItems = 0
    /// Liens symboliques non sûrs et fichiers spéciaux (sockets, FIFO…) ignorés.
    public var skippedItems = 0
    public var issues: [SyncIssue] = []

    public init() {}
}

public struct SyncProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Comparaison source/destination ; `filesTotal` compte les fichiers vus.
        case scanning
        case transferring
    }

    public var phase: Phase
    public var bytesDone: Int64 = 0
    public var bytesTotal: Int64 = 0
    public var filesDone = 0
    public var filesTotal = 0
    /// Chemin relatif de l'élément en cours.
    public var currentPath: String?

    /// Avancement de la phase de transfert, entre 0 et 1.
    public var fraction: Double {
        if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
        if filesTotal > 0 { return Double(filesDone) / Double(filesTotal) }
        return phase == .transferring ? 1 : 0
    }
}

public enum SyncError: Error, Equatable, LocalizedError {
    case sourceNotFound(String)
    case sourceNotDirectory(String)
    case sourceUnreadable(String, String)
    /// Source et destination identiques ou imbriquées : refus pour ne rien écraser.
    case overlappingPaths(source: String, destination: String)
    /// La destination a disparu pendant la sauvegarde (disque débranché).
    case destinationUnavailable(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let p): return tr("Dossier introuvable : \(p)", "Folder not found: \(p)")
        case .sourceNotDirectory(let p): return tr("La source n'est pas un dossier : \(p)", "The source is not a folder: \(p)")
        case .sourceUnreadable(let p, let reason): return tr("Lecture impossible de \(p) (\(reason))", "Cannot read \(p) (\(reason))")
        case .overlappingPaths(let s, let d):
            return tr("SÉCURITÉ : la source (\(s)) et la destination (\(d)) se recouvrent — abandon.",
                      "SAFETY: the source (\(s)) and the destination (\(d)) overlap — aborted.")
        case .destinationUnavailable(let p):
            return tr("Le disque de destination n'est plus accessible (débranché ?) : \(p)",
                      "The destination disk is no longer available (unplugged?): \(p)")
        case .cancelled: return tr("Sauvegarde annulée.", "Backup cancelled.")
        }
    }
}

/// Signal d'annulation partagé entre le thread principal et le thread de sauvegarde.
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
