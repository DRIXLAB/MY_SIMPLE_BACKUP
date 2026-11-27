import AppKit
import BackupCore
import SwiftUI

/// État de l'application et orchestration d'une sauvegarde.
///
/// Tout l'état publié vit sur le thread principal (`@MainActor`). La sauvegarde est orchestrée par
/// une `Task.detached` ; le moteur `SyncEngine` (bloquant, parfois des heures) tourne sur un thread
/// dédié (`onDedicatedThread`) pour ne pas occuper le pool de threads de Swift. L'annulation passe
/// par un `CancellationFlag`. Les mises à jour de l'état passent par des méthodes dédiées : Swift 5.9
/// refuse les modifications `inout` de propriétés isolées depuis `MainActor.run`.
@MainActor
final class BackupController: ObservableObject {
    @Published var destination: URL? {
        didSet {
            UserDefaults.standard.set(destination?.path, forKey: Self.destinationKey)
            refreshDestination()
        }
    }
    /// Faux si la destination mémorisée n'existe pas (disque externe non branché).
    @Published private(set) var destinationAvailable = false
    @Published var selection: Set<String> {
        didSet { UserDefaults.standard.set(selection.sorted(), forKey: Self.selectionKey) }
    }
    @Published var deleteExtraneous = false
    /// Langue de l'interface. Les menus fournis par macOS (Fichier, Édition…) suivent au prochain lancement.
    @Published var language: AppLanguage {
        didSet {
            L10n.language = language
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    @Published private(set) var access: [String: Bool] = [:]
    @Published private(set) var hasFullDiskAccess = true
    /// Taille de chaque dossier en octets (-1 si le calcul a échoué). Gardée en nombre et non en
    /// texte : elle est formatée à l'affichage, dans la langue courante.
    @Published private(set) var sizes: [String: Int64] = [:]
    @Published private(set) var runningApps: [String: [String]] = [:]
    /// Journal de la dernière sauvegarde (en cours, ou la plus récente de l'historique).
    @Published private(set) var run: RunReport?
    /// Sauvegardes terminées, la plus récente en premier.
    @Published private(set) var history: [RunReport] = []
    @Published var showHistory = false
    @Published private(set) var isRunning = false
    @Published private(set) var progress: SyncProgress?

    // Sauvegarde iCloud (archive chiffrée, incrémentale)
    @Published var iCloudEnabled = false {
        didSet { UserDefaults.standard.set(iCloudEnabled, forKey: Self.iCloudEnabledKey) }
    }
    /// Dossier choisi dans iCloud Drive ; chaque élément y a son sous-dossier.
    @Published var iCloudFolder: URL? {
        didSet { UserDefaults.standard.set(iCloudFolder?.path, forKey: Self.iCloudFolderKey) }
    }
    @Published private(set) var hasICloudPassword = false
    /// Éléments dont la prochaine sauvegarde iCloud repartira d'une archive complète.
    @Published private(set) var pendingFullArchive: Set<String> = [] {
        didSet { UserDefaults.standard.set(pendingFullArchive.sorted(), forKey: Self.pendingFullKey) }
    }
    /// Vrai après un changement de mot de passe : la nouvelle archive complète est obligatoire
    /// (une chaîne ne doit jamais mélanger deux mots de passe).
    @Published private(set) var fullArchiveRequired = false {
        didSet { UserDefaults.standard.set(fullArchiveRequired, forKey: Self.fullRequiredKey) }
    }
    @Published var showICloudSettings = false
    /// Avancement de la ligne iCloud en cours.
    @Published private(set) var cloudProgress: CloudProgress?

    /// Avertissements à confirmer avant de lancer la sauvegarde.
    @Published var confirmation: [String] = []
    @Published var showConfirmation = false
    @Published var errorMessage: String?

    private static let destinationKey = "destinationPath"
    private static let selectionKey = "selectedSources"
    private static let languageKey = "appLanguage"
    private static let iCloudEnabledKey = "iCloudEnabled"
    private static let iCloudFolderKey = "iCloudFolderPath"
    private static let pendingFullKey = "iCloudPendingFullArchive"
    private static let fullRequiredKey = "iCloudFullArchiveRequired"
    private let historyStore = HistoryStore.default
    /// Écritures de l'historique, en arrière-plan et dans l'ordre.
    private let historyQueue = DispatchQueue(label: "com.cepe.sauvegarde-mac.history", qos: .utility)
    private var job: Task<Void, Never>?
    private var cancelFlag: CancellationFlag?
    /// Élément dont la progression est affichée : les mises à jour tardives d'un autre sont ignorées.
    private var progressSourceID: String?
    /// Fermeture de l'app demandée pendant une sauvegarde : à confirmer à AppKit une fois arrêtée.
    private var terminationPending = false
    /// Empêche la mise en veille pendant la sauvegarde.
    private var activity: NSObjectProtocol?

    init() {
        // Variable locale : lire `self.language` ici serait refusé tant que toutes les propriétés
        // ne sont pas initialisées (erreur de Swift 5.9 / Xcode 15.0).
        let initialLanguage = UserDefaults.standard.string(forKey: Self.languageKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .systemDefault
        language = initialLanguage
        L10n.language = initialLanguage
        // Destination conservée même si le disque n'est pas branché : il pourra l'être plus tard.
        if let path = UserDefaults.standard.string(forKey: Self.destinationKey) ?? Self.legacyDestination() {
            destination = URL(fileURLWithPath: path)
        }
        let known = Set(BackupSource.all.map(\.id))
        if let saved = UserDefaults.standard.stringArray(forKey: Self.selectionKey) {
            selection = Set(saved).intersection(known)
        } else {
            selection = Set(BackupSource.all.filter(\.isDefault).map(\.id))
        }
        iCloudEnabled = UserDefaults.standard.bool(forKey: Self.iCloudEnabledKey)
        iCloudFolder = UserDefaults.standard.string(forKey: Self.iCloudFolderKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        pendingFullArchive = Set(UserDefaults.standard.stringArray(forKey: Self.pendingFullKey) ?? [])
        fullArchiveRequired = UserDefaults.standard.bool(forKey: Self.fullRequiredKey) && !pendingFullArchive.isEmpty
        hasICloudPassword = PasswordKeychain.exists()
        let loaded = historyStore.loadReportingProblems()
        history = loaded.runs
        run = history.first
        if let aside = loaded.movedAside {
            errorMessage = tr("L'historique des sauvegardes était illisible. Il a été mis de côté ici :\n\(aside.path)",
                              "The backup history was unreadable. It has been set aside here:\n\(aside.path)")
        }
        refresh()
        computeSizes()
    }

    /// Destination enregistrée par l'ancienne version Python (`{"dest": "..."}`).
    private static func legacyDestination() -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.cepe.sauvegarde-mac.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["dest"] as? String
    }

    // MARK: - État du système

    /// Appelé toutes les 4 s par la vue, et avant chaque sauvegarde.
    func refresh() {
        refreshDestination()
        hasFullDiskAccess = SystemInfo.hasFullDiskAccess
        for source in BackupSource.all {
            if let url = source.folderURL {
                access[source.id] = SystemInfo.canRead(url)
            }
            runningApps[source.id] = source.watchedApps.filter(SystemInfo.isRunning).map(\.name)
        }
    }

    private func refreshDestination() {
        destinationAvailable = destination.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    func computeSizes() {
        let folders = BackupSource.all.compactMap { s in s.folderURL.map { (s.id, $0) } }
        // Le contrôleur vit autant que l'application : capture forte sans risque.
        let controller = self
        Task.detached(priority: .utility) {
            for (id, url) in folders {
                let size = try? await BackupController.onDedicatedThread(qos: .utility) {
                    SystemInfo.allocatedSize(of: url)
                }
                await controller.setSize(size ?? -1, for: id)
            }
        }
    }

    /// Exécute un travail bloquant sur un thread dédié (grande pile, hors du pool de Swift).
    nonisolated static func onDedicatedThread<T>(
        qos: QualityOfService, _ work: @escaping () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result(catching: work))
            }
            thread.qualityOfService = qos
            thread.stackSize = 8 << 20
            thread.start()
        }
    }

    /// Méthode dédiée : Swift 5.9 refuse `controller.sizes[id] = …` dans `MainActor.run`
    /// (accès `inout` à une propriété isolée depuis un appel asynchrone).
    private func setSize(_ bytes: Int64, for id: String) {
        sizes[id] = bytes
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = tr("Choisir le dossier de destination", "Choose the destination folder")
        panel.prompt = tr("Choisir", "Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination ?? URL(fileURLWithPath: "/Volumes")
        if panel.runModal() == .OK, let url = panel.url {
            destination = url
        }
    }

    // MARK: - Lancement

    func requestStart() {
        guard !isRunning else { return }
        let selected = selectedSources
        guard !selected.isEmpty else {
            errorMessage = tr("Sélectionnez au moins un élément à sauvegarder.", "Select at least one item to back up.")
            return
        }
        let diskReady = destination.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if iCloudEnabled {
            if let problem = iCloudProblem {
                errorMessage = problem
                return
            }
        } else {
            guard let destination else {
                errorMessage = tr("Cliquez sur « Choisir… » pour sélectionner un dossier de destination.",
                                  "Click “Choose…” to select a destination folder.")
                return
            }
            guard diskReady else {
                errorMessage = tr("Le dossier de destination est introuvable :\n\(destination.path)\n\nLe disque externe est-il branché ?",
                                  "The destination folder cannot be found:\n\(destination.path)\n\nIs the external disk connected?")
                return
            }
        }

        refresh()
        var warnings: [String] = []
        if iCloudEnabled, !diskReady {
            warnings.append(tr("Disque externe non connecté : seule la sauvegarde iCloud sera faite.",
                               "External disk not connected: only the iCloud backup will run."))
        }
        let open = selected.flatMap { runningApps[$0.id] ?? [] }
        if !open.isEmpty {
            let names = open.joined(separator: ", ")
            warnings.append(tr("Applications ouvertes : \(names). La sauvegarde risque d'être incomplète ou incohérente.",
                               "Open applications: \(names). The backup may be incomplete or inconsistent."))
        }
        let denied = selected.filter { $0.folderURL != nil && access[$0.id] == false }.map(\.label)
        if !denied.isEmpty {
            let names = denied.joined(separator: ", ")
            warnings.append(tr("Accès refusé : \(names). Accordez l'accès complet au disque à MY SIMPLE BACKUP dans Réglages Système › Confidentialité et sécurité.",
                               "Access denied: \(names). Grant Full Disk Access to MY SIMPLE BACKUP in System Settings › Privacy & Security."))
        }
        if deleteExtraneous, diskReady {
            warnings.append(tr("Mode suppression activé : les fichiers présents dans la destination mais absents de votre Mac seront définitivement supprimés.",
                               "Deletion mode enabled: files in the destination that are no longer on your Mac will be permanently deleted."))
        }
        let resets = selected.filter { pendingFullArchive.contains($0.id) }.map(\.label)
        if iCloudEnabled, !resets.isEmpty {
            let names = resets.joined(separator: ", ")
            warnings.append(tr("iCloud repartira d'une archive complète pour : \(names). Tout sera renvoyé ; les anciennes archives seront supprimées une fois la nouvelle terminée.",
                               "iCloud will start over from a full archive for: \(names). Everything will be uploaded again; the old archives will be deleted once the new one is complete."))
        }

        if warnings.isEmpty {
            start()
        } else {
            confirmation = warnings
            showConfirmation = true
        }
    }

    func start() {
        guard !isRunning else { return }
        let sources = selectedSources
        let delete = deleteExtraneous
        let disk = destination.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        var cloud: CloudPlan?
        if iCloudEnabled, let folder = iCloudFolder {
            do {
                guard let password = try PasswordKeychain.read(), !password.isEmpty else {
                    hasICloudPassword = false
                    errorMessage = tr("Mot de passe des archives iCloud introuvable dans le trousseau : définissez-le dans Réglages iCloud…",
                                      "iCloud archive password not found in the keychain: set it in iCloud Settings…")
                    return
                }
                cloud = CloudPlan(folder: folder, password: password, startNew: pendingFullArchive)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        guard disk != nil || cloud != nil else { return }
        // Constante : Swift 5.9 refuse de capturer une `var` dans la tâche détachée.
        let cloudPlan = cloud

        isRunning = true
        progress = nil
        let flag = CancellationFlag()
        cancelFlag = flag
        setWindowsClosable(false)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Backup in progress"
        )

        let controller = self
        job = Task.detached(priority: .userInitiated) {
            await BackupController.perform(sources: sources, destination: disk, delete: delete,
                                           cloud: cloudPlan, cancel: flag, controller: controller)
            await controller.backupEnded()
        }
    }

    private func backupEnded() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        isRunning = false
        progress = nil
        cloudProgress = nil
        progressSourceID = nil
        job = nil
        cancelFlag = nil
        setWindowsClosable(true)
        refresh()
        if terminationPending {
            terminationPending = false
            flushHistory()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    func cancel() {
        cancelFlag?.cancel()
        job?.cancel()
    }

    /// Pendant une sauvegarde, la fenêtre ne peut pas être fermée : sa fermeture quitterait l'app
    /// et interromprait la copie sans avertissement (⌘W émet alors un bip).
    private func setWindowsClosable(_ closable: Bool) {
        for window in NSApp.windows {
            window.standardWindowButton(.closeButton)?.isEnabled = closable
        }
    }

    /// Réponse à ⌘Q : pendant une sauvegarde, confirmation puis arrêt propre avant de quitter.
    func shouldTerminate() -> NSApplication.TerminateReply {
        guard isRunning else {
            flushHistory()
            return .terminateNow
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("Une sauvegarde est en cours", "A backup is in progress")
        alert.informativeText = tr(
            "Quitter maintenant l'interrompt. Les fichiers déjà copiés restent complets et la sauvegarde sera notée « Annulée » dans l'historique.",
            "Quitting now interrupts it. Files already copied remain complete and the backup will be marked “Cancelled” in the history.")
        alert.addButton(withTitle: tr("Continuer la sauvegarde", "Continue backup"))
        alert.addButton(withTitle: tr("Arrêter et quitter", "Stop and quit"))
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        terminationPending = true
        cancel()
        return .terminateLater
    }

    private var selectedSources: [BackupSource] {
        BackupSource.all.filter { selection.contains($0.id) }
    }

    // MARK: - Exécution (hors thread principal)

    /// Paramètres de la partie iCloud d'une sauvegarde.
    struct CloudPlan {
        let folder: URL
        let password: String
        /// Éléments à faire repartir d'une archive complète.
        let startNew: Set<String>
    }

    private nonisolated static func perform(
        sources: [BackupSource], destination: URL?, delete: Bool, cloud: CloudPlan?,
        cancel: CancellationFlag, controller: BackupController
    ) async {
        var rows: [SourceReport] = []
        if destination != nil {
            rows += sources.map { SourceReport(id: $0.id, label: $0.label, symbol: $0.symbol) }
        }
        if cloud != nil {
            rows += sources.map { SourceReport(id: SourceReport.cloudPrefix + $0.id, label: $0.label, symbol: "icloud.fill") }
        }
        await controller.beginRun(RunReport(
            startedAt: Date(),
            destination: destination ?? cloud?.folder ?? URL(fileURLWithPath: "/"),
            deleteMode: delete && destination != nil,
            sources: rows
        ))

        var interruption: String?
        if let destination {
            interruption = await performDisk(sources: sources, destination: destination, delete: delete,
                                             cancel: cancel, controller: controller)
        }
        if let cloud, !cancel.isCancelled {
            await performCloud(sources: sources, plan: cloud, cancel: cancel, controller: controller)
        }
        await controller.finishRun(cancelled: cancel.isCancelled, interruption: interruption)
    }

    /// Copie vers le disque externe. Renvoie le message à afficher si le disque a été débranché.
    private nonisolated static func performDisk(
        sources: [BackupSource], destination: URL, delete: Bool,
        cancel: CancellationFlag, controller: BackupController
    ) async -> String? {
        let engine = SyncEngine()
        var interruption: String?
        for source in sources {
            if cancel.isCancelled { break }
            await controller.beginSource(source.id)

            switch source.kind {
            case .appList:
                let apps = AppInventory.scan()
                let file = destination.appendingPathComponent(AppInventory.fileName)
                do {
                    try AppInventory.report(apps).write(to: file, atomically: true, encoding: .utf8)
                    await controller.finishSource(source.id, status: .success, applicationCount: apps.count)
                } catch {
                    await controller.finishSource(source.id, status: .failed, message: error.localizedDescription)
                }

            case .folder(let url):
                let target = destination.appendingPathComponent(url.lastPathComponent)
                let sourceID = source.id
                do {
                    let stats = try await onDedicatedThread(qos: .userInitiated) {
                        try engine.sync(
                            source: url,
                            destination: target,
                            options: SyncOptions(deleteExtraneous: delete),
                            isCancelled: { cancel.isCancelled },
                            progress: { p in Task { @MainActor in controller.updateProgress(p, for: sourceID) } }
                        )
                    }
                    await controller.finishSource(
                        source.id,
                        status: stats.issues.isEmpty ? .success : .warning,
                        issues: stats.issues.map(\.description),
                        stats: stats
                    )
                } catch SyncError.cancelled {
                    await controller.finishSource(source.id, status: .cancelled)
                } catch SyncError.destinationUnavailable(_) {
                    interruption = disconnectedMessage()
                    await controller.finishSource(source.id, status: .failed, message: disconnectedMessage())
                } catch {
                    await controller.finishSource(source.id, status: .failed, message: error.localizedDescription)
                }
            }

            if interruption == nil, !FileManager.default.fileExists(atPath: destination.path) {
                interruption = disconnectedMessage()
            }
            if interruption != nil { break }
        }
        return interruption
    }

    /// Envoi vers iCloud : une étape de chaîne chiffrée par dossier, et la liste des applications
    /// en clair. Chaque ligne n'est terminée qu'une fois tout envoyé vers iCloud.
    private nonisolated static func performCloud(
        sources: [BackupSource], plan: CloudPlan, cancel: CancellationFlag, controller: BackupController
    ) async {
        let uploader = ICloudUploadQueue(
            isCancelled: { cancel.isCancelled },
            onStatus: { status in Task { @MainActor in controller.updateCloudUpload(status) } })
        for source in sources {
            if cancel.isCancelled { break }
            let rowID = SourceReport.cloudPrefix + source.id
            await controller.beginSource(rowID)

            switch source.kind {
            case .appList:
                do {
                    let count = try await onDedicatedThread(qos: .userInitiated) { () throws -> Int in
                        let apps = AppInventory.scan()
                        let file = plan.folder.appendingPathComponent(AppInventory.fileName)
                        try FileManager.default.createDirectory(at: plan.folder, withIntermediateDirectories: true)
                        try AppInventory.report(apps).write(to: file, atomically: true, encoding: .utf8)
                        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?
                            .int64Value ?? 0
                        uploader.enqueue(file, size: size, evict: false)
                        try uploader.waitUntilEmpty()
                        return apps.count
                    }
                    await controller.finishSource(rowID, status: .success, applicationCount: count)
                } catch {
                    await controller.finishCloudFailure(rowID, error: error, cancelled: cancel.isCancelled)
                }

            case .folder(let url):
                let sourceID = source.id
                let fullRequested = plan.startNew.contains(sourceID)
                let backup = ICloudChainBackup(
                    source: url,
                    destination: plan.folder.appendingPathComponent(url.lastPathComponent, isDirectory: true),
                    cacheFile: cloudCacheFile(for: sourceID),
                    password: plan.password,
                    uploader: uploader,
                    fetch: { try ICloudDrive.download($0, isCancelled: { cancel.isCancelled }) })
                do {
                    let outcome = try await onDedicatedThread(qos: .userInitiated) {
                        try backup.run(startNewChain: fullRequested, isCancelled: { cancel.isCancelled },
                                       progress: { p in Task { @MainActor in controller.updateCloudPhase(p, for: rowID) } })
                    }
                    await controller.finishCloudSource(rowID, sourceID: sourceID, outcome: outcome,
                                                       fullRequested: fullRequested)
                } catch {
                    await controller.finishCloudFailure(rowID, error: error, cancelled: cancel.isCancelled)
                }
            }
        }
    }

    /// État mémorisé localement de la chaîne iCloud d'un élément (hors iCloud).
    private nonisolated static func cloudCacheFile(for sourceID: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("com.cepe.sauvegarde-mac/icloud/\(sourceID).json")
    }

    private nonisolated static func disconnectedMessage() -> String {
        tr("Le disque de destination a été déconnecté pendant la sauvegarde. Rebranchez-le puis relancez la sauvegarde.",
           "The destination disk was disconnected during the backup. Reconnect it and start the backup again.")
    }

    // MARK: - Mises à jour du journal (thread principal)

    private func beginRun(_ report: RunReport) {
        run = report
    }

    private func beginSource(_ id: String) {
        progress = nil
        cloudProgress = nil
        progressSourceID = id
        guard let i = run?.sources.firstIndex(where: { $0.id == id }) else { return }
        run?.sources[i].status = .running
        run?.sources[i].startedAt = Date()
    }

    /// Les mises à jour arrivent sans ordre garanti : celles d'un autre élément sont ignorées.
    private func updateProgress(_ newProgress: SyncProgress, for id: String) {
        guard isRunning, id == progressSourceID else { return }
        progress = newProgress
    }

    /// Les compteurs (et non un texte figé) sont enregistrés : le résumé est recalculé à
    /// l'affichage dans la langue courante (`SourceReport.displaySummary`).
    private func finishSource(_ id: String, status: SourceReport.Status, message: String? = nil,
                              issues: [String] = [], stats: SyncStats? = nil, applicationCount: Int? = nil) {
        guard var report = run?.sources.first(where: { $0.id == id }),
              let i = run?.sources.firstIndex(where: { $0.id == id }) else { return }
        report.status = status
        report.message = message
        report.issues = issues
        report.issueCount = issues.count
        report.applicationCount = applicationCount
        if let stats {
            report.sourceFiles = stats.sourceFiles
            report.copiedFiles = stats.copiedFiles
            report.copiedBytes = stats.copiedBytes
            report.deletedItems = stats.deletedItems
            report.skippedItems = stats.skippedItems
        }
        report.finishedAt = Date()
        run?.sources[i] = report
    }

    // MARK: - iCloud (thread principal)

    private func updateCloudPhase(_ phase: ICloudChainBackup.Progress, for id: String) {
        guard isRunning, id == progressSourceID else { return }
        var current = cloudProgress ?? CloudProgress()
        current.phase = phase.phase
        current.partsWritten = phase.partsWritten
        current.bytesToArchive = phase.bytesToArchive
        cloudProgress = current
    }

    private func updateCloudUpload(_ status: ICloudUploadQueue.Status) {
        guard isRunning, progressSourceID?.hasPrefix(SourceReport.cloudPrefix) == true else { return }
        var current = cloudProgress ?? CloudProgress()
        current.uploadedBytes = status.uploadedBytes
        current.pendingBytes = status.pendingBytes
        current.waitingForICloud = status.waitingForICloud
        cloudProgress = current
    }

    private func finishCloudSource(_ rowID: String, sourceID: String, outcome: ICloudChainBackup.Outcome,
                                   fullRequested: Bool) {
        cloudProgress = nil
        guard var report = run?.sources.first(where: { $0.id == rowID }),
              let i = run?.sources.firstIndex(where: { $0.id == rowID }) else { return }
        report.status = outcome.issues.isEmpty ? .success : .warning
        report.issues = outcome.issues.map(\.description)
        report.issueCount = outcome.issues.count
        report.sourceFiles = outcome.sourceFiles
        report.copiedFiles = outcome.changedFiles
        report.copiedBytes = outcome.changedBytes
        report.deletedItems = outcome.deletedItems
        report.cloudStep = outcome.step
        report.cloudFull = outcome.kind == .complete
        report.finishedAt = Date()
        run?.sources[i] = report
        if fullRequested, outcome.step == 0 {
            pendingFullArchive.remove(sourceID)
            if pendingFullArchive.isEmpty { fullArchiveRequired = false }
        }
    }

    private func finishCloudFailure(_ rowID: String, error: Error, cancelled: Bool) {
        cloudProgress = nil
        if cancelled {
            finishSource(rowID, status: .cancelled)
        } else {
            finishSource(rowID, status: .failed, message: error.localizedDescription)
        }
    }

    // MARK: - Réglages iCloud

    /// Problème empêchant la sauvegarde iCloud, ou `nil` si elle est prête.
    var iCloudProblem: String? {
        if !ICloudDrive.isAvailable {
            return tr("iCloud Drive n'est pas activé sur ce Mac (Réglages Système › votre nom › iCloud).",
                      "iCloud Drive is not enabled on this Mac (System Settings › your name › iCloud).")
        }
        guard let folder = iCloudFolder, ICloudDrive.contains(folder) else {
            return tr("Choisissez le dossier de sauvegarde dans iCloud Drive (Réglages iCloud…).",
                      "Choose the backup folder in iCloud Drive (iCloud Settings…).")
        }
        if !hasICloudPassword {
            return tr("Définissez le mot de passe des archives (Réglages iCloud…).",
                      "Set the archive password (iCloud Settings…).")
        }
        return nil
    }

    /// Chemin du dossier iCloud tel que le Finder l'affiche (« iCloud Drive › MY SIMPLE BACKUP »).
    var iCloudFolderDisplay: String? {
        guard let folder = iCloudFolder else { return nil }
        let root = ICloudDrive.rootURL.standardizedFileURL.path
        let path = folder.standardizedFileURL.path
        guard path.hasPrefix(root) else { return folder.path }
        let rest = path.dropFirst(root.count).split(separator: "/").joined(separator: " › ")
        return rest.isEmpty ? "iCloud Drive" : "iCloud Drive › " + rest
    }

    func chooseICloudFolder() {
        guard ICloudDrive.isAvailable else {
            errorMessage = iCloudProblem
            return
        }
        let panel = NSOpenPanel()
        panel.title = tr("Choisir le dossier de sauvegarde dans iCloud Drive", "Choose the backup folder in iCloud Drive")
        panel.prompt = tr("Choisir", "Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = iCloudFolder ?? ICloudDrive.rootURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ICloudDrive.contains(url) else {
            errorMessage = tr("Ce dossier n'est pas dans iCloud Drive. Choisissez un dossier dans iCloud Drive.",
                              "This folder is not in iCloud Drive. Choose a folder in iCloud Drive.")
            return
        }
        iCloudFolder = url
    }

    /// Enregistre le mot de passe dans le trousseau.
    /// - Returns: un message d'erreur, ou `nil` si c'est fait.
    func setICloudPassword(_ password: String, confirmation: String) -> String? {
        guard password.count >= 8 else {
            return tr("Le mot de passe doit contenir au moins 8 caractères.", "The password must be at least 8 characters long.")
        }
        guard password == confirmation else {
            return tr("Les deux mots de passe ne sont pas identiques.", "The two passwords do not match.")
        }
        let replacing = hasICloudPassword
        do {
            try PasswordKeychain.save(password)
        } catch {
            return error.localizedDescription
        }
        hasICloudPassword = true
        // Les archives existantes restent chiffrées avec l'ancien mot de passe : nouvelle chaîne,
        // obligatoire (on ne mélange jamais deux mots de passe dans une chaîne).
        if replacing {
            requestFullArchive()
            fullArchiveRequired = true
        }
        return nil
    }

    /// La prochaine sauvegarde iCloud de chaque dossier repartira d'une archive complète.
    func requestFullArchive() {
        pendingFullArchive = Set(BackupSource.all.filter { $0.folderURL != nil }.map(\.id))
    }

    func cancelFullArchiveRequest() {
        guard !fullArchiveRequired else { return }
        pendingFullArchive = []
    }

    private func finishRun(cancelled: Bool, interruption: String?) {
        guard var current = run else { return }
        let hadPending = current.sources.contains { $0.status == .pending }
        for i in current.sources.indices where current.sources[i].status == .pending {
            current.sources[i].status = .cancelled
        }
        // « Annulée » seulement si l'annulation a réellement interrompu quelque chose.
        current.cancelled = cancelled && (hadPending || current.sources.contains { $0.status == .cancelled })
        current.finishedAt = Date()
        run = current
        history = historyStore.appending(current, to: history)
        persistHistory()
        if let interruption {
            errorMessage = interruption
        }
    }

    // MARK: - Historique

    func deleteFromHistory(_ id: UUID) {
        updateHistory(history.filter { $0.id != id })
    }

    func clearHistory() {
        updateHistory([])
    }

    private func updateHistory(_ runs: [RunReport]) {
        history = runs
        persistHistory()
        // Le journal affiché ne doit pas montrer une sauvegarde effacée (sauf si elle est en cours).
        if let run, run.isFinished, !runs.contains(where: { $0.id == run.id }) {
            self.run = runs.first
        }
    }

    /// Enregistre l'historique en arrière-plan (le fichier peut peser plusieurs Mo).
    private func persistHistory() {
        let runs = history
        let store = historyStore
        let controller = self
        historyQueue.async {
            do {
                try store.save(runs)
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in controller.reportHistoryError(message) }
            }
        }
    }

    private func reportHistoryError(_ message: String) {
        errorMessage = tr("L'historique n'a pas pu être enregistré : \(message)", "The history could not be saved: \(message)")
    }

    /// Attend la fin des écritures de l'historique (avant de quitter).
    func flushHistory() {
        historyQueue.sync {}
    }
}

/// Avancement de la ligne iCloud en cours (phase de l'étape + état de la file d'envoi).
struct CloudProgress: Equatable {
    var phase: ICloudChainBackup.Phase = .scanning
    var partsWritten = 0
    var bytesToArchive: Int64 = 0
    var uploadedBytes: Int64 = 0
    var pendingBytes: Int64 = 0
    var waitingForICloud = false
}
