import AppKit
import BackupCore

/// Accès au système : permissions, applications ouvertes, tailles.
enum SystemInfo {
    /// Vrai si le contenu du dossier peut être listé (faux sans Full Disk Access pour les dossiers protégés).
    static func canRead(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    /// La base TCC de l'utilisateur n'est lisible qu'avec l'accès complet au disque.
    static var hasFullDiskAccess: Bool {
        let tcc = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        guard let handle = FileHandle(forReadingAtPath: tcc.path) else { return false }
        try? handle.close()
        return true
    }

    static func isRunning(_ app: WatchedApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Taille occupée sur le disque (équivalent `du -s`). Peut prendre du temps : à appeler hors du thread principal.
    static func allocatedSize(of url: URL) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return nil }

        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Taille dans la langue de l'interface (« 1,5 Go » / « 1.5 GB »).
    static func formatBytes(_ bytes: Int64) -> String {
        L10n.bytes(bytes)
    }
}
