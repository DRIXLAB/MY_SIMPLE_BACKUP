import AppKit
import BackupCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: BackupController

    private let refreshTimer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            languageBar
            destinationSection
            sourcesSection
            optionsSection
            actionSection
            logSection
        }
        // Changement de langue : on reconstruit toute la vue pour que chaque texte soit retraduit
        // (les sous-vues dont les données n'ont pas changé ne seraient pas recalculées).
        .id(controller.language)
        .padding(20)
        .frame(width: 560)
        .onReceive(refreshTimer) { _ in controller.refresh() }
        .alert(tr("Attention", "Warning"), isPresented: $controller.showConfirmation) {
            Button(tr("Continuer", "Continue"), role: .destructive) { controller.start() }
            Button(tr("Annuler", "Cancel"), role: .cancel) {}
        } message: {
            Text(controller.confirmation.joined(separator: "\n\n") + "\n\n" + tr("Continuer quand même ?", "Continue anyway?"))
        }
        .alert("MY SIMPLE BACKUP",
               isPresented: Binding(get: { controller.errorMessage != nil },
                                    set: { if !$0 { controller.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.errorMessage ?? "")
        }
        .sheet(isPresented: $controller.showHistory) {
            HistoryView(controller: controller)
        }
    }

    // MARK: Langue

    /// Choix de la langue, en haut à droite, avec drapeaux.
    private var languageBar: some View {
        HStack {
            Spacer()
            Picker("", selection: $controller.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text("\(language.flag) \(language.displayName)").tag(language)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(tr("Langue de l'application (les menus de macOS changent au prochain lancement)",
                     "App language (macOS menus change at next launch)"))
        }
        .padding(.bottom, -6)
        .disabled(controller.isRunning)
    }

    // MARK: Destination

    private var destinationSection: some View {
        GroupBox(tr("Destination", "Destination")) {
            HStack {
                let missing = controller.destination != nil && !controller.destinationAvailable
                Image(systemName: missing ? "externaldrive.badge.xmark" : "externaldrive")
                    .foregroundStyle(missing ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(controller.destination?.path ?? tr("Aucun dossier sélectionné", "No folder selected"))
                        .foregroundStyle(controller.destination == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if missing {
                        Text(tr("Disque non connecté — branchez-le pour lancer la sauvegarde",
                                "Disk not connected — connect it to start the backup"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let destination = controller.destination, controller.destinationAvailable {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help(tr("Afficher dans le Finder", "Show in Finder"))
                }
                Button(tr("Choisir…", "Choose…")) { controller.chooseDestination() }
            }
            .padding(4)
        }
        .disabled(controller.isRunning)
    }

    // MARK: Éléments

    private var sourcesSection: some View {
        GroupBox(tr("Éléments à sauvegarder", "Items to back up")) {
            VStack(alignment: .leading, spacing: 6) {
                if !controller.hasFullDiskAccess {
                    fullDiskAccessBanner
                }
                ForEach(BackupSource.all) { source in
                    sourceRow(source)
                }
            }
            .padding(4)
        }
        .disabled(controller.isRunning)
    }

    private func sourceRow(_ source: BackupSource) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { controller.selection.contains(source.id) },
                set: { on in
                    if on { controller.selection.insert(source.id) } else { controller.selection.remove(source.id) }
                }
            )) {
                HStack(spacing: 6) {
                    if source.folderURL != nil {
                        Circle()
                            .fill(accessColor(source))
                            .frame(width: 8, height: 8)
                            .help(controller.access[source.id] == false
                                  ? tr("Accès refusé", "Access denied") : tr("Accès autorisé", "Access granted"))
                    } else {
                        Color.clear.frame(width: 8, height: 8)
                    }
                    Text(source.label)
                }
            }
            .toggleStyle(.checkbox)

            Spacer()

            if let running = controller.runningApps[source.id], !running.isEmpty {
                Label(tr("\(running.joined(separator: ", ")) ouvert", "\(running.joined(separator: ", ")) open"),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if source.folderURL != nil {
                Group {
                    if let size = controller.sizes[source.id] {
                        Text(size >= 0 ? SystemInfo.formatBytes(size) : "?")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(tr("Calcul en cours…", "Calculating…"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 110, alignment: .trailing)
            }
        }
    }

    private func accessColor(_ source: BackupSource) -> Color {
        switch controller.access[source.id] {
        case true?: return .green
        case false?: return .red
        case nil: return .gray
        }
    }

    private var fullDiskAccessBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Accès complet au disque non accordé", "Full Disk Access not granted"))
                    .fontWeight(.semibold)
                Text(tr("Nécessaire pour copier la photothèque et les bibliothèques Musique et iMovie. Ajoutez « MY SIMPLE BACKUP », puis relancez l'application.",
                        "Required to copy the Photos library and the Music and iMovie libraries. Add “MY SIMPLE BACKUP”, then relaunch the app."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(tr("Ouvrir les Réglages", "Open Settings")) { SystemInfo.openFullDiskAccessSettings() }
        }
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Options

    private var optionsSection: some View {
        GroupBox(tr("Options", "Options")) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle(tr("Supprimer de la destination les fichiers absents de la source",
                          "Delete files from the destination that are no longer in the source"),
                       isOn: $controller.deleteExtraneous)
                    .toggleStyle(.checkbox)
                Text(tr("Les fichiers effacés sur ce Mac seront aussi effacés du disque de sauvegarde.",
                        "Files deleted on this Mac will also be deleted from the backup disk."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .disabled(controller.isRunning)
    }

    // MARK: Lancement

    private var actionSection: some View {
        Group {
            if controller.isRunning {
                Button(role: .cancel) {
                    controller.cancel()
                } label: {
                    Label(tr("Annuler la sauvegarde", "Cancel backup"), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            } else {
                Button {
                    controller.requestStart()
                } label: {
                    Label(tr("Lancer la sauvegarde", "Start backup"), systemImage: "arrow.down.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Journal

    private var logSection: some View {
        GroupBox {
            JournalView(run: controller.run, progress: controller.progress)
                .padding(4)
        } label: {
            HStack {
                Text(tr("Journal", "Log"))
                Spacer()
                Button {
                    controller.showHistory = true
                } label: {
                    Label(tr("Historique", "History") + " (\(controller.history.count))", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(tr("Historique des sauvegardes (⌘Y)", "Backup history (⌘Y)"))
            }
            .frame(maxWidth: .infinity)
        }
    }
}
