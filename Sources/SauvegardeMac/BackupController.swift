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
    @Published private(set) var sizes: [String: String] = [:]
    @Published private(set) var runningApps: [String: [String]] = [:]
    /// Journal de la dernière sauvegarde (en cours, ou la plus récente de l'historique).
    @Published private(set) var run: RunReport?
    /// Sauvegardes terminées, la plus récente en premier.
    @Published private(set) var history: [RunReport] = []
    @Published var showHistory = false
    @Published private(set) var isRunning = false
    @Published private(set) var progress: SyncProgress?

    /// Avertissements à confirmer avant de lancer la sauvegarde.
    @Published var confirmation: [String] = []
    @Published var showConfirmation = false
    @Published var errorMessage: String?

    private static let destinationKey = "destinationPath"
    private static let selectionKey = "selectedSources"
    private static let languageKey = "appLanguage"
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
                await controller.setSize(size.map(SystemInfo.formatBytes) ?? "?", for: id)
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
    private func setSize(_ text: String, for id: String) {
        sizes[id] = text
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
        guard let destination else {
            errorMessage = tr("Cliquez sur « Choisir… » pour sélectionner un dossier de destination.",
                              "Click “Choose…” to select a destination folder.")
            return
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            errorMessage = tr("Le dossier de destination est introuvable :\n\(destination.path)\n\nLe disque externe est-il branché ?",
                              "The destination folder cannot be found:\n\(destination.path)\n\nIs the external disk connected?")
            return
        }
        let selected = selectedSources
        guard !selected.isEmpty else {
            errorMessage = tr("Sélectionnez au moins un élément à sauvegarder.", "Select at least one item to back up.")
            return
        }

        refresh()
        var warnings: [String] = []
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
        if deleteExtraneous {
            warnings.append(tr("Mode suppression activé : les fichiers présents dans la destination mais absents de votre Mac seront définitivement supprimés.",
                               "Deletion mode enabled: files in the destination that are no longer on your Mac will be permanently deleted."))
        }

        if warnings.isEmpty {
            start()
        } else {
            confirmation = warnings
            showConfirmation = true
        }
    }

    func start() {
        guard !isRunning, let destination else { return }
        let sources = selectedSources
        let delete = deleteExtraneous

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
            await BackupController.perform(sources: sources, destination: destination, delete: delete,
                                           cancel: flag, controller: controller)
            await controller.backupEnded()
        }
    }

    private func backupEnded() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        isRunning = false
        progress = nil
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

    private nonisolated static func perform(
        sources: [BackupSource], destination: URL, delete: Bool,
        cancel: CancellationFlag, controller: BackupController
    ) async {
        await controller.beginRun(RunReport(
            startedAt: Date(),
            destination: destination,
            deleteMode: delete,
            sources: sources.map { SourceReport(id: $0.id, label: $0.label, symbol: $0.symbol) }
        ))

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

        await controller.finishRun(cancelled: cancel.isCancelled, interruption: interruption)
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
