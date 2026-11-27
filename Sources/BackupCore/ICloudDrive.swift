#if os(macOS)
import Foundation

/// Outils iCloud Drive, avec les API publiques de macOS uniquement.
///
/// On ne peut pas forcer l'envoi d'un fichier vers iCloud : macOS l'envoie de lui-même dès qu'il est
/// écrit dans iCloud Drive. On peut en revanche **suivre** l'envoi (`uploadState`), **attendre** qu'il
/// soit terminé, puis **libérer la copie locale** (`evict`, le fichier reste dans iCloud) ; et à la
/// restauration, **demander le téléchargement** (`download`).
public enum ICloudDrive {
    public enum Failure: Error, Equatable, LocalizedError {
        case notInICloudDrive(String)
        case uploadFailed(String, String)
        case downloadFailed(String, String)
        case timedOut(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .notInICloudDrive(let path):
                return tr("Ce dossier n'est pas dans iCloud Drive : \(path)", "This folder is not in iCloud Drive: \(path)")
            case .uploadFailed(let path, let reason):
                return tr("Envoi vers iCloud impossible pour \(path) (\(reason))", "Upload to iCloud failed for \(path) (\(reason))")
            case .downloadFailed(let path, let reason):
                return tr("Téléchargement depuis iCloud impossible pour \(path) (\(reason))", "Download from iCloud failed for \(path) (\(reason))")
            case .timedOut(let path):
                return tr("Délai dépassé en attendant iCloud pour \(path)", "Timed out waiting for iCloud for \(path)")
            case .cancelled:
                return tr("Opération annulée.", "Operation cancelled.")
            }
        }
    }

    public enum UploadState: Equatable {
        /// Le fichier n'est pas géré par iCloud Drive.
        case notUbiquitous
        case waiting
        case uploading
        case uploaded
        case failed(String)
    }

    /// Racine d'iCloud Drive (« iCloud Drive » dans le Finder).
    public static var rootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// iCloud Drive est-il activé sur ce Mac ?
    public static var isAvailable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Vrai si `url` est dans iCloud Drive (ou en est la racine).
    public static func contains(_ url: URL) -> Bool {
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    // MARK: Envoi

    public static func uploadState(of url: URL) -> UploadState {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
            .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey,
        ]) else { return .notUbiquitous }
        guard values.isUbiquitousItem == true else { return .notUbiquitous }
        if let error = values.ubiquitousItemUploadingError { return .failed(error.localizedDescription) }
        if values.ubiquitousItemIsUploaded == true { return .uploaded }
        if values.ubiquitousItemIsUploading == true { return .uploading }
        return .waiting
    }

    /// Attend que le fichier soit entièrement envoyé vers iCloud.
    /// - Parameters:
    ///   - timeout: `nil` pour attendre indéfiniment (par exemple sans réseau).
    ///   - onWait: appelé à chaque vérification avec l'état courant (affichage « En attente d'iCloud »).
    public static func waitUntilUploaded(
        _ url: URL,
        timeout: TimeInterval? = nil,
        pollInterval: TimeInterval = 2,
        isCancelled: () -> Bool = { false },
        onWait: (UploadState) -> Void = { _ in }
    ) throws {
        let start = Date()
        while true {
            if isCancelled() { throw Failure.cancelled }
            let state = uploadState(of: url)
            switch state {
            case .uploaded:
                return
            case .notUbiquitous:
                throw Failure.notInICloudDrive(url.path)
            case .failed(let reason):
                throw Failure.uploadFailed(url.lastPathComponent, reason)
            case .waiting, .uploading:
                onWait(state)
            }
            if let timeout, Date().timeIntervalSince(start) > timeout {
                throw Failure.timedOut(url.lastPathComponent)
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    // MARK: Copie locale

    /// Le contenu du fichier est-il présent sur ce Mac ?
    public static func isDownloaded(_ url: URL) -> Bool {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let status = (try? fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus else {
            // Fichier non géré par iCloud : son contenu est forcément local.
            return true
        }
        return status == .current || status == .downloaded
    }

    /// Libère la copie locale d'un fichier déjà envoyé (il reste dans iCloud et dans le Finder).
    public static func evict(_ url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
    }

    /// Demande le téléchargement du fichier et attend qu'il soit disponible localement.
    public static func download(
        _ url: URL,
        timeout: TimeInterval? = nil,
        pollInterval: TimeInterval = 1,
        isCancelled: () -> Bool = { false }
    ) throws {
        if isDownloaded(url) { return }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            throw Failure.downloadFailed(url.lastPathComponent, error.localizedDescription)
        }
        let start = Date()
        while !isDownloaded(url) {
            if isCancelled() { throw Failure.cancelled }
            var fresh = url
            fresh.removeAllCachedResourceValues()
            if let error = (try? fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey]))?
                .ubiquitousItemDownloadingError {
                throw Failure.downloadFailed(url.lastPathComponent, error.localizedDescription)
            }
            if let timeout, Date().timeIntervalSince(start) > timeout {
                throw Failure.timedOut(url.lastPathComponent)
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }
}
#endif
