#if canImport(AppleArchive) && os(macOS)
import Foundation

// MARK: - File d'envoi vers iCloud

/// Suit l'envoi vers iCloud des fichiers écrits dans iCloud Drive, puis libère leur copie locale.
///
/// Un thread traite les fichiers dans l'ordre : attente de l'envoi (`ICloudDrive.waitUntilUploaded`)
/// puis libération (`ICloudDrive.evict`). `waitForRoom` bloque l'écriture tant que trop d'octets
/// attendent l'envoi (contre-pression : l'espace local reste borné) ; `waitUntilEmpty` attend que
/// tout soit envoyé (« Terminée » ne s'affiche qu'à ce moment-là).
public final class ICloudUploadQueue {
    public struct Status: Equatable {
        /// Octets écrits localement, pas encore envoyés.
        public var pendingBytes: Int64
        /// Octets envoyés depuis la création de la file.
        public var uploadedBytes: Int64
        /// Vrai si iCloud n'envoie pas (pas de réseau, iCloud en pause…) depuis un moment.
        public var waitingForICloud: Bool
    }

    private struct Entry {
        let url: URL
        let size: Int64
        let evict: Bool
    }

    public let maxPendingBytes: Int64
    private let isCancelled: () -> Bool
    private let onStatus: (Status) -> Void
    private let condition = NSCondition()
    private var queue: [Entry] = []
    private var pendingBytes: Int64 = 0
    private var uploadedBytes: Int64 = 0
    private var waitingForICloud = false
    private var workerRunning = false
    private var failure: Error?

    public init(maxPendingBytes: Int64 = 5 << 30,
                isCancelled: @escaping () -> Bool = { false },
                onStatus: @escaping (Status) -> Void = { _ in }) {
        self.maxPendingBytes = maxPendingBytes
        self.isCancelled = isCancelled
        self.onStatus = onStatus
    }

    /// Confie un fichier à l'envoi. `evict` : libérer sa copie locale une fois envoyé.
    public func enqueue(_ url: URL, size: Int64, evict: Bool = true) {
        condition.lock()
        queue.append(Entry(url: url, size: size, evict: evict))
        pendingBytes += size
        let start = !workerRunning
        if start { workerRunning = true }
        condition.unlock()
        if start {
            let thread = Thread { [weak self] in self?.work() }
            thread.qualityOfService = .utility
            thread.start()
        }
        report()
    }

    /// Bloque tant que plus de `maxPendingBytes` attendent l'envoi.
    public func waitForRoom() throws {
        try wait { pendingBytes > maxPendingBytes }
    }

    /// Bloque jusqu'à ce que tout ait été envoyé (et libéré si demandé).
    public func waitUntilEmpty() throws {
        try wait { !queue.isEmpty || workerRunning }
    }

    public var status: Status {
        condition.lock()
        defer { condition.unlock() }
        return Status(pendingBytes: pendingBytes, uploadedBytes: uploadedBytes, waitingForICloud: waitingForICloud)
    }

    private func wait(while blocked: () -> Bool) throws {
        condition.lock()
        defer { condition.unlock() }
        while failure == nil, blocked() {
            if isCancelled() { throw ICloudDrive.Failure.cancelled }
            _ = condition.wait(until: Date().addingTimeInterval(1))
        }
        // L'erreur est rendue une seule fois : elle concerne l'élément en cours (dont l'étape est
        // alors supprimée), pas les suivants, qui repartent d'une file vide.
        if let error = failure {
            failure = nil
            throw error
        }
    }

    private func work() {
        while true {
            condition.lock()
            guard let entry = queue.first, failure == nil else {
                workerRunning = false
                condition.broadcast()
                condition.unlock()
                return
            }
            condition.unlock()

            do {
                var since = Date()
                try ICloudDrive.waitUntilUploaded(entry.url, isCancelled: isCancelled, onWait: { [weak self] state in
                    guard let self else { return }
                    // « En attente d'iCloud » après 30 s sans démarrage de l'envoi.
                    if state == .uploading { since = Date() }
                    let stuck = state == .waiting && Date().timeIntervalSince(since) > 30
                    self.condition.lock()
                    let changed = self.waitingForICloud != stuck
                    self.waitingForICloud = stuck
                    self.condition.unlock()
                    if changed { self.report() }
                })
                if entry.evict {
                    // Échec non bloquant : le fichier est dans iCloud, seule la place locale n'est pas rendue.
                    try? ICloudDrive.evict(entry.url)
                }
                condition.lock()
                queue.removeFirst()
                pendingBytes -= entry.size
                uploadedBytes += entry.size
                waitingForICloud = false
                condition.broadcast()
                condition.unlock()
                report()
            } catch {
                condition.lock()
                failure = error
                queue.removeAll()
                pendingBytes = 0
                waitingForICloud = false
                workerRunning = false
                condition.broadcast()
                condition.unlock()
                return
            }
        }
    }

    private func report() {
        onStatus(status)
    }
}

// MARK: - Étape de sauvegarde iCloud

/// Sauvegarde d'un dossier vers sa chaîne iCloud : archive complète la première fois (ou sur
/// demande), puis uniquement les changements. Voir l'organisation dans `ICloudChain.swift`.
///
/// Déroulement d'une étape : nettoyage des étapes inachevées → état précédent (cache local, sinon
/// reconstruit depuis les journaux) → inventaire et comparaison → archive des éléments changés
/// (`donnees/`) → journal chiffré des changements (`journal/`) → attente de l'envoi → marqueur
/// `termine` → mise à jour du cache. En cas d'erreur ou d'annulation, l'étape est supprimée.
public final class ICloudChainBackup {
    public struct Options {
        public var partSize: Int64 = 1 << 30
        public var iterations = EncryptedArchive.defaultIterations
        public var modifyWindow: TimeInterval = 2
        public init() {}
    }

    public enum Phase: Equatable { case scanning, archiving, uploading }

    public struct Progress: Equatable {
        public var phase: Phase
        /// Octets des éléments à archiver (fichiers nouveaux ou modifiés).
        public var bytesToArchive: Int64 = 0
        /// Nombre de morceaux écrits.
        public var partsWritten = 0
    }

    public struct Outcome: Equatable {
        /// Étape créée, ou `nil` s'il n'y avait aucun changement.
        public var step: Int?
        public var kind: ChainDelta.Kind?
        public var chainName: String
        public var changedFiles = 0
        public var changedBytes: Int64 = 0
        public var deletedItems = 0
        public var sourceFiles = 0
        public var issues: [SyncIssue] = []
    }

    /// État mémorisé localement après chaque étape validée (évite de relire les journaux).
    struct CachedState: Codable {
        var chain: String
        var lastStep: Int
        var items: [ArchiveItem]
    }

    let source: URL
    let destination: URL
    let cacheFile: URL
    let password: String
    let options: Options
    /// File d'envoi iCloud ; `nil` hors iCloud (tests sur un dossier local).
    let uploader: ICloudUploadQueue?
    /// Rend un fichier lisible localement avant lecture (téléchargement iCloud).
    let fetch: (URL) throws -> Void
    private let fm = FileManager.default

    /// - Parameters:
    ///   - destination: dossier de la source dans iCloud (ex. « <dossier choisi>/Documents »).
    ///   - cacheFile: fichier local de l'état mémorisé (hors iCloud).
    public init(source: URL, destination: URL, cacheFile: URL, password: String,
                options: Options = Options(), uploader: ICloudUploadQueue?,
                fetch: @escaping (URL) throws -> Void = { _ in }) {
        self.source = source
        self.destination = destination
        self.cacheFile = cacheFile
        self.password = password
        self.options = options
        self.uploader = uploader
        self.fetch = fetch
    }

    /// Exécute une étape.
    /// - Parameter startNewChain: repartir d'une nouvelle archive complète ; les anciennes chaînes
    ///   ne sont supprimées qu'une fois la nouvelle validée.
    public func run(startNewChain: Bool = false,
                    isCancelled: @escaping () -> Bool = { false },
                    progress: (Progress) -> Void = { _ in }) throws -> Outcome {
        // Sécurité, avant toute écriture ou tout nettoyage : jamais dans la source (dossier iCloud
        // choisi à l'intérieur de « Documents » synchronisé avec iCloud, par exemple).
        try SyncEngine.checkNoOverlap(source: source, destination: destination)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try removeIncompleteSteps()

        progress(Progress(phase: .scanning))
        let current = startNewChain ? nil : ChainLayout.currentChain(in: destination)
        let now = Date()
        let chainURL = current?.url ?? newChainURL(date: now)
        let stepNumber = current?.steps.count ?? 0
        let kind: ChainDelta.Kind = stepNumber == 0 ? .complete : .increment
        let previous = try current.map { try state(of: $0.url, steps: $0.steps) } ?? ChainState()
        let key = try chainKey(of: current?.steps.first)

        let scan = try ArchivePlan.scan(source, isCancelled: isCancelled)
        let diff = ChainDiff.compute(previous: previous, current: scan.items,
                                    unreadable: scan.issues.map(\.path), modifyWindow: options.modifyWindow)
        var outcome = Outcome(step: nil, kind: nil, chainName: chainURL.lastPathComponent,
                              sourceFiles: scan.items.filter { $0.kind == .file }.count, issues: scan.issues)
        if kind == .increment, diff.changed.isEmpty, diff.deleted.isEmpty {
            return outcome
        }

        let stepURL = chainURL.appendingPathComponent(
            ChainLayout.stepFolderName(step: stepNumber, kind: kind, date: now), isDirectory: true)
        do {
            try fm.createDirectory(at: stepURL, withIntermediateDirectories: true)
            var changed = diff.changed
            var bytesToArchive = changed.reduce(Int64(0)) { $0 + $1.size }
            var partsWritten = 0
            progress(Progress(phase: .archiving, bytesToArchive: bytesToArchive))

            if !changed.isEmpty {
                let dataURL = stepURL.appendingPathComponent(ChainLayout.dataFolder, isDirectory: true)
                let result = try EncryptedArchive.create(
                    from: source, items: changed, to: dataURL, password: password, key: key,
                    partSize: options.partSize, iterations: options.iterations,
                    beforeNewPart: { try self.uploader?.waitForRoom() },
                    onPartCompleted: { url, size in
                        self.uploader?.enqueue(url, size: size)
                        partsWritten += 1
                        progress(Progress(phase: .archiving, bytesToArchive: bytesToArchive, partsWritten: partsWritten))
                    },
                    isCancelled: isCancelled)
                // Éléments disparus entre l'inventaire et l'archivage : non enregistrés (ils
                // seront repris à la prochaine sauvegarde s'ils réapparaissent).
                let missing = Set(result.issues.map(\.path))
                changed.removeAll { missing.contains($0.path) }
                bytesToArchive = changed.reduce(Int64(0)) { $0 + $1.size }
                outcome.issues += result.issues
                enqueueSmallFile(dataURL.appendingPathComponent(EncryptedArchive.keyFileName))
            }

            let delta = ChainDelta(step: stepNumber, kind: kind, date: now, changed: changed, deleted: diff.deleted)
            try writeJournal(delta, in: stepURL, key: key)

            progress(Progress(phase: .uploading, bytesToArchive: bytesToArchive, partsWritten: partsWritten))
            try uploader?.waitUntilEmpty()

            // Marqueur écrit en dernier, une fois tout le reste envoyé : l'étape devient valide.
            let marker = stepURL.appendingPathComponent(ChainLayout.commitMarker)
            try Data().write(to: marker)
            enqueueSmallFile(marker)
            try uploader?.waitUntilEmpty()

            var state = previous
            state.apply(delta)
            saveCache(CachedState(chain: chainURL.lastPathComponent, lastStep: stepNumber,
                                  items: Array(state.items.values)))

            if startNewChain {
                for chain in ChainLayout.chains(in: destination) where chain.lastPathComponent != chainURL.lastPathComponent {
                    try? fm.removeItem(at: chain)
                }
            }

            outcome.step = stepNumber
            outcome.kind = kind
            outcome.changedFiles = delta.changedFileCount
            outcome.changedBytes = delta.changedBytes
            outcome.deletedItems = delta.deleted.count
            return outcome
        } catch {
            try? fm.removeItem(at: stepURL)
            if stepNumber == 0 { try? fm.removeItem(at: chainURL) }
            throw error
        }
    }

    // MARK: État précédent

    /// Cache local s'il correspond à la dernière étape validée, sinon relecture des journaux.
    func state(of chain: URL, steps: [ChainLayout.Step]) throws -> ChainState {
        if let cache = loadCache(), cache.chain == chain.lastPathComponent, cache.lastStep == steps.count - 1 {
            return ChainState(items: cache.items)
        }
        var state = ChainState()
        for step in steps {
            state.apply(try readJournal(of: step.url))
        }
        saveCache(CachedState(chain: chain.lastPathComponent, lastStep: steps.count - 1, items: Array(state.items.values)))
        return state
    }

    /// Journaux (changements) de toutes les étapes validées de la chaîne en cours, dans l'ordre.
    public func journals() throws -> [ChainDelta] {
        guard let current = ChainLayout.currentChain(in: destination) else { return [] }
        return try current.steps.map { try readJournal(of: $0.url) }
    }

    func readJournal(of step: URL) throws -> ChainDelta {
        let temporary = fm.temporaryDirectory.appendingPathComponent("msb-journal-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try EncryptedArchive.extract(from: step.appendingPathComponent(ChainLayout.journalFolder),
                                     to: temporary, password: password, beforeReading: fetch)
        let data = try Data(contentsOf: temporary.appendingPathComponent(ChainLayout.journalFileName))
        return try JSONDecoder().decode(ChainDelta.self, from: data)
    }

    /// Dossier d'une nouvelle chaîne, horodaté ; jamais celui d'une chaîne existante (deux
    /// chaînes créées dans la même seconde).
    private func newChainURL(date: Date) -> URL {
        let existing = Set(ChainLayout.chains(in: destination).map(\.lastPathComponent))
        var date = date
        while existing.contains(ChainLayout.chainFolderName(date: date)) { date += 1 }
        return destination.appendingPathComponent(ChainLayout.chainFolderName(date: date), isDirectory: true)
    }

    /// Clé de la chaîne : celle de son archive complète (une seule dérivation du mot de passe
    /// pour toute la chaîne, mise en cache), ou une nouvelle clé pour une nouvelle chaîne.
    private func chainKey(of firstStep: ChainLayout.Step?) throws -> EncryptedArchive.Key {
        guard let firstStep else { return try .generate(password: password, iterations: options.iterations) }
        let journal = firstStep.url.appendingPathComponent(ChainLayout.journalFolder)
        try fetch(journal.appendingPathComponent(EncryptedArchive.keyFileName))
        return try .load(in: journal, password: password)
    }

    private func writeJournal(_ delta: ChainDelta, in stepURL: URL, key: EncryptedArchive.Key) throws {
        let temporary = fm.temporaryDirectory.appendingPathComponent("msb-journal-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        try JSONEncoder().encode(delta).write(to: temporary.appendingPathComponent(ChainLayout.journalFileName))
        let journalURL = stepURL.appendingPathComponent(ChainLayout.journalFolder, isDirectory: true)
        let result = try EncryptedArchive.create(from: temporary, to: journalURL, password: password, key: key,
                                                 partSize: .max)
        for part in result.parts { enqueueSmallFile(part) }
        enqueueSmallFile(journalURL.appendingPathComponent(EncryptedArchive.keyFileName))
    }

    /// Petits fichiers (clé, journal, marqueur) : envoyés mais gardés localement.
    private func enqueueSmallFile(_ url: URL) {
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        uploader?.enqueue(url, size: size, evict: false)
    }

    /// Supprime les étapes inachevées (sans marqueur) de toutes les chaînes, et les chaînes sans
    /// aucune étape validée (archive complète interrompue).
    private func removeIncompleteSteps() throws {
        for chain in ChainLayout.chains(in: destination) {
            let committed = ChainLayout.committedSteps(in: chain)
            if committed.isEmpty {
                try? fm.removeItem(at: chain)
                continue
            }
            let valid = Set(committed.map(\.url.lastPathComponent))
            for step in ChainLayout.steps(in: chain) where !valid.contains(step.url.lastPathComponent) {
                try? fm.removeItem(at: step.url)
            }
        }
    }

    // MARK: Cache local

    private func loadCache() -> CachedState? {
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        return try? JSONDecoder().decode(CachedState.self, from: data)
    }

    private func saveCache(_ cache: CachedState) {
        try? fm.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: cacheFile, options: .atomic)
    }
}
#endif
