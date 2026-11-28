#if canImport(AppleArchive) && os(macOS)
import Foundation

/// Restauration d'un élément sauvegardé dans iCloud (sa chaîne en cours), à une étape donnée.
///
/// Principe : les journaux (petits, chiffrés) donnent l'état à restaurer et l'étape qui contient la
/// dernière version de chaque élément (`RestorePlan`). Seules ces étapes sont lues, **morceau par
/// morceau** : chaque morceau est téléchargé (`fetch`), déchiffré dans un dossier provisoire caché
/// à l'intérieur de la destination (même volume : les fichiers voulus y sont simplement déplacés,
/// sans copie), puis libéré (`release`). Un morceau illisible n'arrête pas la restauration : ses
/// fichiers sont signalés comme non restaurés. La destination doit être vide : on ne restaure
/// jamais par-dessus des fichiers existants.
public final class ICloudChainRestore {
    /// Élément sauvegardé trouvé dans un dossier de sauvegarde iCloud (« Documents »…).
    public struct Element: Equatable, Identifiable {
        public var id: String { name }
        /// Nom du sous-dossier (nom du dossier d'origine).
        public let name: String
        public let folder: URL
        /// Étapes validées de la chaîne en cours.
        public let steps: [ChainLayout.Step]
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case noBackup(String)
        case destinationNotEmpty(String)
        case unreadableJournals(String)

        public var errorDescription: String? {
            switch self {
            case .noBackup(let name):
                return tr("Aucune sauvegarde valide trouvée pour « \(name) ».", "No valid backup found for “\(name)”.")
            case .destinationNotEmpty(let path):
                return tr("Le dossier de restauration doit être vide ou nouveau : \(path)",
                          "The restore folder must be empty or new: \(path)")
            case .unreadableJournals(let reason):
                return tr("Impossible de lire les sauvegardes : mot de passe incorrect ou archives endommagées (\(reason)).",
                          "Cannot read the backups: wrong password or damaged archives (\(reason)).")
            }
        }
    }

    public struct Progress: Equatable {
        public var partsDone = 0
        public var partsTotal = 0
        public var filesRestored = 0
        public var bytesRestored: Int64 = 0
    }

    public struct Outcome: Equatable {
        public var restoredFiles = 0
        public var restoredBytes: Int64 = 0
        /// Éléments non restaurés (morceau illisible, fichier absent des archives…).
        public var issues: [SyncIssue] = []
    }

    /// Éléments d'un dossier de sauvegarde iCloud ayant une chaîne valide, triés par nom.
    public static func elements(in backupFolder: URL) -> [Element] {
        ChainLayout.names(in: backupFolder).sorted().compactMap { name in
            let folder = backupFolder.appendingPathComponent(name, isDirectory: true)
            guard let chain = ChainLayout.currentChain(in: folder) else { return nil }
            return Element(name: name, folder: folder, steps: chain.steps)
        }
    }

    let element: Element
    let password: String
    let fetch: (URL) throws -> Void
    let release: (URL) -> Void
    private let fm = FileManager.default

    /// - Parameters:
    ///   - fetch: rend un fichier lisible localement (téléchargement iCloud).
    ///   - release: appelé après la lecture d'un morceau (libération de sa copie locale).
    public init(element: Element, password: String,
                fetch: @escaping (URL) throws -> Void = { _ in },
                release: @escaping (URL) -> Void = { _ in }) {
        self.element = element
        self.password = password
        self.fetch = fetch
        self.release = release
    }

    /// Changements de chaque étape, dans l'ordre. Échoue vite si le mot de passe est incorrect.
    public func journals(isCancelled: () -> Bool = { false }) throws -> [ChainDelta] {
        var result: [ChainDelta] = []
        for step in element.steps {
            if isCancelled() { throw SyncError.cancelled }
            let temporary = fm.temporaryDirectory.appendingPathComponent("msb-journal-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temporary) }
            do {
                try EncryptedArchive.extract(from: step.url.appendingPathComponent(ChainLayout.journalFolder),
                                             to: temporary, password: password, beforeReading: fetch)
                let data = try Data(contentsOf: temporary.appendingPathComponent(ChainLayout.journalFileName))
                result.append(try JSONDecoder().decode(ChainDelta.self, from: data))
            } catch let error as ICloudDrive.Failure {
                throw error == .cancelled ? SyncError.cancelled : error
            } catch {
                throw Failure.unreadableJournals(step.url.lastPathComponent)
            }
        }
        return result
    }

    /// Restaure l'état de l'élément tel qu'à l'étape `upTo` dans `destination` (vide ou nouveau).
    public func restore(upTo step: Int, journals: [ChainDelta], to destination: URL,
                        isCancelled: () -> Bool = { false },
                        progress: (Progress) -> Void = { _ in }) throws -> Outcome {
        guard !element.steps.isEmpty, step >= 0, step < min(element.steps.count, journals.count) else {
            throw Failure.noBackup(element.name)
        }
        // La restauration n'écrit jamais dans les sauvegardes elles-mêmes.
        try SyncEngine.checkNoOverlap(source: element.folder, destination: destination)
        try prepareDestination(destination)

        let plan = RestorePlan(deltas: Array(journals.prefix(step + 1)))
        var outcome = Outcome()
        var current = Progress()

        // Morceaux à lire pour chaque étape utile (une étape sans fichiers n'a pas de « donnees »).
        var readers: [(step: Int, reader: EncryptedArchive.Reader?, error: Error?)] = []
        for number in plan.neededSteps {
            let data = element.steps[number].url.appendingPathComponent(ChainLayout.dataFolder)
            do {
                let reader = try EncryptedArchive.Reader(partsDirectory: data, password: password, beforeReading: fetch)
                readers.append((number, reader, nil))
                current.partsTotal += reader.parts.count
            } catch let error as ICloudDrive.Failure where error == .cancelled {
                throw SyncError.cancelled
            } catch {
                readers.append((number, nil, error))
            }
        }
        progress(current)

        // Éléments à restaurer qui ne sont pas des dossiers, retirés au fur et à mesure.
        var remaining = Set(plan.items.values.filter { $0.kind != .directory }.map(\.path))
        let staging = destination.appendingPathComponent(".msb-restauration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }

        for entry in readers {
            let stepName = element.steps[entry.step].url.lastPathComponent
            guard let reader = entry.reader else {
                outcome.issues.append(SyncIssue(path: stepName, message: entry.error?.localizedDescription ?? "?"))
                continue
            }
            let wanted = plan.paths(fromStep: entry.step)
            for part in reader.parts {
                if isCancelled() { throw SyncError.cancelled }
                // Un dossier provisoire neuf par morceau : rien ne reste d'un morceau précédent.
                let partStaging = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
                defer { try? fm.removeItem(at: partStaging) }
                do {
                    try fetch(part)
                    try reader.extract(part, to: partStaging)
                } catch let error as ICloudDrive.Failure where error == .cancelled {
                    throw SyncError.cancelled
                } catch {
                    outcome.issues.append(SyncIssue(path: stepName + "/" + part.lastPathComponent,
                                                    message: error.localizedDescription))
                    release(part)
                    current.partsDone += 1
                    progress(current)
                    continue
                }
                release(part)

                // Déplace les éléments voulus (dernière version) depuis le dossier provisoire.
                let extracted = (try? ArchivePlan.scan(partStaging).items) ?? []
                for item in extracted where item.kind != .directory && wanted.contains(item.path) && remaining.contains(item.path) {
                    let target = destination.appendingPathComponent(item.path)
                    do {
                        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(at: partStaging.appendingPathComponent(item.path), to: target)
                        remaining.remove(item.path)
                        outcome.restoredFiles += 1
                        outcome.restoredBytes += item.size
                        current.filesRestored += 1
                        current.bytesRestored += item.size
                    } catch {
                        outcome.issues.append(SyncIssue(path: item.path, message: error.localizedDescription))
                    }
                }
                current.partsDone += 1
                progress(current)
            }
        }

        // Dossiers (y compris vides) de l'état restauré, puis leurs dates d'origine (les
        // déplacements de fichiers ci-dessus les ont modifiées).
        let directories = plan.items.values.filter { $0.kind == .directory }
        for item in directories {
            try? fm.createDirectory(at: destination.appendingPathComponent(item.path), withIntermediateDirectories: true)
        }
        for item in directories {
            try? fm.setAttributes([.modificationDate: item.modificationDate],
                                  ofItemAtPath: destination.appendingPathComponent(item.path).path)
        }
        for path in remaining.sorted() {
            outcome.issues.append(SyncIssue(path: path, message: tr("non restauré (absent des archives lisibles)",
                                                                    "not restored (missing from readable archives)")))
        }
        return outcome
    }

    /// La destination doit être nouvelle ou vide (on ignore « .DS_Store »).
    private func prepareDestination(_ destination: URL) throws {
        if fm.fileExists(atPath: destination.path) {
            let contents = ((try? fm.contentsOfDirectory(atPath: destination.path)) ?? [])
                .filter { $0 != ".DS_Store" }
            guard contents.isEmpty else { throw Failure.destinationNotEmpty(destination.path) }
        } else {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        }
    }
}
#endif
