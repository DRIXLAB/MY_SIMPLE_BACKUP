import AppKit
import BackupCore
import SwiftUI

/// État de la restauration d'un élément sauvegardé dans iCloud.
@MainActor
final class RestoreModel: ObservableObject {
    enum Phase: Equatable {
        case choosing
        case reading
        case restoring
        case finished(ICloudChainRestore.Outcome, URL)
        case cancelled
    }

    @Published var backupFolder: URL? { didSet { reloadElements() } }
    @Published private(set) var elements: [ICloudChainRestore.Element] = []
    @Published var elementName: String? { didSet { if oldValue != elementName { journals = nil } } }
    @Published var useSavedPassword: Bool { didSet { journals = nil } }
    @Published var otherPassword = "" { didSet { if !useSavedPassword { journals = nil } } }
    /// Journaux de l'élément choisi, lus avec le mot de passe (prouve qu'il est correct).
    @Published private(set) var journals: [ChainDelta]?
    @Published var stepNumber = 0
    @Published var parentFolder: URL?
    @Published private(set) var phase: Phase = .choosing
    @Published private(set) var progress = ICloudChainRestore.Progress()
    @Published var errorMessage: String?

    private let controller: BackupController
    private var cancelFlag = CancellationFlag()

    init(controller: BackupController) {
        self.controller = controller
        useSavedPassword = controller.hasICloudPassword
        backupFolder = controller.iCloudFolder
        reloadElements()
    }

    var isBusy: Bool { phase == .reading || phase == .restoring }

    var element: ICloudChainRestore.Element? { elements.first { $0.name == elementName } }

    func reloadElements() {
        elements = backupFolder.map(ICloudChainRestore.elements(in:)) ?? []
        if element == nil { elementName = elements.first?.name }
        journals = nil
    }

    /// Nom affiché d'un élément (« Bureau » pour le dossier « Desktop »…).
    static func label(for name: String) -> String {
        BackupSource.all.first { $0.folderURL?.lastPathComponent == name }?.label ?? name
    }

    static func stepTitle(_ step: ChainLayout.Step) -> String {
        let kind = step.kind == .complete ? tr("archive complète", "full archive")
                                          : tr("incrément n° \(step.number)", "increment #\(step.number)")
        return L10n.dateTime(step.date) + "  ·  " + kind
    }

    /// Ce que contiendra la restauration à l'étape choisie.
    var planSummary: String? {
        guard let journals, stepNumber < journals.count else { return nil }
        let plan = RestorePlan(deltas: Array(journals.prefix(stepNumber + 1)))
        let files = plan.items.values.filter { $0.kind != .directory }.count
        return L10n.count(files, "fichier", "fichiers", "file", "files") + " · " + L10n.bytes(plan.totalSize)
    }

    /// Dossier créé pour la restauration : « Documents (restauré le 2026-11-27 14.05) ».
    var restoreFolderName: String? {
        guard let element, stepNumber < element.steps.count else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let date = formatter.string(from: element.steps[stepNumber].date)
        return tr("\(element.name) (sauvegarde du \(date))", "\(element.name) (backup of \(date))")
    }

    // MARK: Actions

    func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.title = tr("Dossier de sauvegarde dans iCloud Drive", "Backup folder in iCloud Drive")
        panel.prompt = tr("Choisir", "Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = backupFolder ?? (ICloudDrive.isAvailable ? ICloudDrive.rootURL : nil)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupFolder = url
    }

    func chooseParentFolder() {
        let panel = NSOpenPanel()
        panel.title = tr("Où restaurer ?", "Where to restore?")
        panel.message = tr("Un nouveau dossier y sera créé ; rien d'existant n'est remplacé.",
                           "A new folder will be created there; nothing existing is replaced.")
        panel.prompt = tr("Choisir", "Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = parentFolder ?? FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        parentFolder = url
    }

    private func password() -> String? {
        if useSavedPassword {
            do {
                guard let saved = try PasswordKeychain.read() else {
                    errorMessage = tr("Aucun mot de passe enregistré dans le trousseau.", "No password saved in the keychain.")
                    return nil
                }
                return saved
            } catch {
                errorMessage = error.localizedDescription
                return nil
            }
        }
        guard !otherPassword.isEmpty else {
            errorMessage = tr("Saisissez le mot de passe des archives.", "Enter the archive password.")
            return nil
        }
        return otherPassword
    }

    private func restorer(_ element: ICloudChainRestore.Element, password: String,
                          cancel: CancellationFlag) -> ICloudChainRestore {
        let inICloud = ICloudDrive.contains(element.folder)
        return ICloudChainRestore(
            element: element, password: password,
            fetch: { url in
                if inICloud { try ICloudDrive.download(url, isCancelled: { cancel.isCancelled }) }
            },
            release: { url in
                if inICloud { try? ICloudDrive.evict(url) }
            })
    }

    /// Lit les journaux de l'élément (téléchargés si besoin) : vérifie le mot de passe.
    func readJournals() {
        guard let element, let password = password() else { return }
        let cancel = CancellationFlag()
        cancelFlag = cancel
        let restore = restorer(element, password: password, cancel: cancel)
        phase = .reading
        controller.isRestoring = true
        Task {
            do {
                let result = try await BackupController.onDedicatedThread(qos: .userInitiated) {
                    try restore.journals(isCancelled: { cancel.isCancelled })
                }
                journals = result
                stepNumber = max(0, result.count - 1)
            } catch {
                if !cancel.isCancelled { errorMessage = error.localizedDescription }
            }
            phase = .choosing
            controller.isRestoring = false
        }
    }

    func restore() {
        guard let element, let journals, let parentFolder, let name = restoreFolderName,
              let password = password() else { return }
        // Jamais par-dessus un dossier existant : « … 2 », « … 3 »… si le nom est déjà pris.
        var destination = parentFolder.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = parentFolder.appendingPathComponent("\(name) \(suffix)", isDirectory: true)
            suffix += 1
        }
        let cancel = CancellationFlag()
        cancelFlag = cancel
        let restore = restorer(element, password: password, cancel: cancel)
        let step = stepNumber
        progress = ICloudChainRestore.Progress()
        phase = .restoring
        controller.isRestoring = true
        Task {
            do {
                let outcome = try await BackupController.onDedicatedThread(qos: .userInitiated) {
                    try restore.restore(upTo: step, journals: journals, to: destination,
                                        isCancelled: { cancel.isCancelled },
                                        progress: { p in Task { @MainActor in self.setProgress(p) } })
                }
                phase = .finished(outcome, destination)
            } catch {
                if cancel.isCancelled {
                    phase = .cancelled
                } else {
                    errorMessage = error.localizedDescription
                    phase = .choosing
                }
            }
            controller.isRestoring = false
        }
    }

    private func setProgress(_ newProgress: ICloudChainRestore.Progress) {
        if phase == .restoring { progress = newProgress }
    }

    func cancel() { cancelFlag.cancel() }

    func startOver() { phase = .choosing }
}

/// Feuille « Restaurer depuis iCloud » : dossier, mot de passe, élément et date, destination.
struct RestoreView: View {
    @ObservedObject var controller: BackupController
    @StateObject private var model: RestoreModel
    @Environment(\.dismiss) private var dismiss

    init(controller: BackupController) {
        self.controller = controller
        _model = StateObject(wrappedValue: RestoreModel(controller: controller))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(tr("Restaurer depuis iCloud Drive", "Restore from iCloud Drive"),
                  systemImage: "clock.arrow.circlepath")
                .font(.title3.weight(.semibold))

            switch model.phase {
            case .choosing, .reading:
                form
            case .restoring:
                restoringView
            case .finished(let outcome, let folder):
                finishedView(outcome, folder: folder)
            case .cancelled:
                Label(tr("Restauration annulée. Le dossier de restauration est incomplet.",
                         "Restore cancelled. The restore folder is incomplete."),
                      systemImage: "xmark.circle.fill")
                    .foregroundStyle(.orange)
            }

            HStack {
                if case .finished = model.phase { Button(tr("Autre restauration…", "Another restore…")) { model.startOver() } }
                if model.phase == .cancelled { Button(tr("Recommencer…", "Start over…")) { model.startOver() } }
                Spacer()
                if model.isBusy {
                    Button(tr("Annuler", "Cancel")) { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button(tr("Fermer", "Close")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(model.isBusy)
        .alert("MY SIMPLE BACKUP",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: Formulaire

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1. Dossier de sauvegarde
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("1. Dossier de sauvegarde iCloud", "1. iCloud backup folder")).font(.headline)
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(model.backupFolder.map(display) ?? tr("Aucun dossier choisi", "No folder chosen"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(tr("Choisir…", "Choose…")) { model.chooseBackupFolder() }
                }
                if model.backupFolder != nil, model.elements.isEmpty {
                    Text(tr("Aucune sauvegarde iCloud terminée dans ce dossier.",
                            "No completed iCloud backup in this folder."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            // 2. Élément et mot de passe
            if !model.elements.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("2. Élément et mot de passe", "2. Item and password")).font(.headline)
                    Picker(tr("Élément", "Item"), selection: $model.elementName) {
                        ForEach(model.elements) { element in
                            Text(RestoreModel.label(for: element.name)).tag(Optional(element.name))
                        }
                    }
                    if controller.hasICloudPassword {
                        Toggle(tr("Utiliser le mot de passe enregistré dans le trousseau",
                                  "Use the password saved in the keychain"),
                               isOn: $model.useSavedPassword)
                            .toggleStyle(.checkbox)
                    }
                    if !model.useSavedPassword || !controller.hasICloudPassword {
                        SecureField(tr("Mot de passe des archives", "Archive password"), text: $model.otherPassword)
                    }
                    HStack {
                        if model.phase == .reading {
                            ProgressView().controlSize(.small)
                            Text(tr("Lecture des journaux (téléchargement depuis iCloud si besoin)…",
                                    "Reading the logs (downloading from iCloud if needed)…"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if model.journals != nil {
                            Label(tr("Mot de passe correct", "Password correct"), systemImage: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Button(tr("Lire les sauvegardes", "Read backups")) { model.readJournals() }
                            .disabled(model.isBusy || model.journals != nil)
                    }
                }
            }

            // 3. Date et destination
            if let element = model.element, model.journals != nil {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("3. Date et destination", "3. Date and destination")).font(.headline)
                    Picker(tr("État au", "State as of"), selection: $model.stepNumber) {
                        ForEach(element.steps.reversed(), id: \.number) { step in
                            Text(RestoreModel.stepTitle(step)).tag(step.number)
                        }
                    }
                    if let summary = model.planSummary {
                        Text(tr("À restaurer : \(summary)", "To restore: \(summary)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(model.parentFolder.map { $0.path } ?? tr("Choisissez où restaurer", "Choose where to restore"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(tr("Choisir…", "Choose…")) { model.chooseParentFolder() }
                    }
                    if model.parentFolder != nil, let name = model.restoreFolderName {
                        Text(tr("Nouveau dossier : « \(name) »", "New folder: “\(name)”"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button(tr("Restaurer", "Restore")) { model.restore() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.parentFolder == nil || model.isBusy)
                    }
                }
            }
        }
        .disabled(model.phase == .reading)
    }

    private func display(_ url: URL) -> String {
        let root = ICloudDrive.rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return url.path }
        let rest = path.dropFirst(root.count).split(separator: "/").joined(separator: " › ")
        return rest.isEmpty ? "iCloud Drive" : "iCloud Drive › " + rest
    }

    // MARK: Avancement et résultat

    private var restoringView: some View {
        VStack(alignment: .leading, spacing: 8) {
            let p = model.progress
            if p.partsTotal > 0 {
                ProgressView(value: Double(p.partsDone), total: Double(p.partsTotal))
            } else {
                ProgressView()
            }
            Text(tr("Morceau \(L10n.number(min(p.partsDone + 1, max(p.partsTotal, 1)))) sur \(L10n.number(p.partsTotal)) · ",
                    "Part \(L10n.number(min(p.partsDone + 1, max(p.partsTotal, 1)))) of \(L10n.number(p.partsTotal)) · ")
                 + L10n.count(p.filesRestored, "fichier restauré", "fichiers restaurés", "file restored", "files restored")
                 + " · " + L10n.bytes(p.bytesRestored))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(tr("Chaque morceau est téléchargé depuis iCloud, déchiffré puis libéré de ce Mac.",
                    "Each part is downloaded from iCloud, decrypted, then removed from this Mac."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func finishedView(_ outcome: ICloudChainRestore.Outcome, folder: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if outcome.issues.isEmpty {
                Label(tr("Restauration terminée", "Restore complete"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label(tr("Restauration terminée avec des éléments non restaurés",
                         "Restore complete with items not restored"),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(L10n.count(outcome.restoredFiles, "fichier restauré", "fichiers restaurés", "file restored", "files restored")
                 + " · " + L10n.bytes(outcome.restoredBytes))
                .foregroundStyle(.secondary)
            if !outcome.issues.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(outcome.issues.prefix(200).enumerated()), id: \.offset) { _, issue in
                            Text(issue.description)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if outcome.issues.count > 200 {
                            Text(tr("… et \(L10n.number(outcome.issues.count - 200)) autres",
                                    "… and \(L10n.number(outcome.issues.count - 200)) more"))
                                .font(.caption)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
            Button(tr("Afficher dans le Finder", "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        }
    }
}
