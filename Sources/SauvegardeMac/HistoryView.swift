import BackupCore
import SwiftUI

/// Historique des sauvegardes passées : liste à gauche, détail (même présentation que le journal) à droite.
struct HistoryView: View {
    @ObservedObject var controller: BackupController
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if controller.history.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    List(controller.history, selection: $selection) { run in
                        HistoryRow(run: run)
                            .contextMenu {
                                Button(tr("Supprimer de l'historique", "Delete from history"), role: .destructive) {
                                    delete(run.id)
                                }
                            }
                    }
                    .listStyle(.sidebar)
                    // Touche Suppr (⌫) ou menu Édition › Supprimer sur la sauvegarde sélectionnée.
                    .onDeleteCommand {
                        if let selection { delete(selection) }
                    }
                    .frame(width: 290)

                    Divider()

                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            footer
        }
        .frame(width: 860, height: 540)
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: controller.history.map(\.id)) { _ in selectFirstIfNeeded() }
        .confirmationDialog(tr("Effacer tout l'historique ?", "Clear the whole history?"), isPresented: $confirmClear) {
            Button(tr("Effacer l'historique", "Clear history"), role: .destructive) { controller.clearHistory() }
            Button(tr("Annuler", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("Les sauvegardes elles-mêmes ne sont pas touchées : seul leur compte rendu est supprimé.",
                    "The backups themselves are not affected: only their reports are deleted."))
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(tr("Historique des sauvegardes", "Backup history"))
                .font(.title3.weight(.semibold))
            Spacer()
            if !controller.history.isEmpty {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var summary: String {
        let count = controller.history.count
        let bytes = controller.history.reduce(Int64(0)) { $0 + $1.copiedBytes }
        let label = L10n.count(count, "sauvegarde", "sauvegardes", "backup", "backups")
        let total = SystemInfo.formatBytes(bytes)
        return "\(label)  ·  " + tr("\(total) copiés au total", "\(total) copied in total")
    }

    @ViewBuilder
    private var detail: some View {
        if let run = controller.history.first(where: { $0.id == selection }) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        delete(run.id)
                    } label: {
                        Label(tr("Supprimer de l'historique", "Delete from history"), systemImage: "trash")
                    }
                    .help(tr("Supprimer ce compte rendu (les fichiers sauvegardés ne sont pas touchés)",
                             "Delete this report (backed-up files are not affected)"))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                ScrollView {
                    JournalView(run: run, progress: nil, listHeight: nil)
                        .padding(20)
                }
                // Nouvel état (listes dépliées…) pour chaque sauvegarde affichée.
                .id(run.id)
            }
        } else {
            Text(tr("Sélectionnez une sauvegarde", "Select a backup"))
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(tr("Aucune sauvegarde dans l'historique", "No backup in the history"))
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(tr("Chaque sauvegarde terminée ou annulée y sera ajoutée.", "Every completed or cancelled backup will be added here."))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button(tr("Effacer tout l'historique…", "Clear the whole history…"), role: .destructive) { confirmClear = true }
                .disabled(controller.history.isEmpty)
            Spacer()
            Button(tr("Fermer", "Close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Supprime une sauvegarde de l'historique et sélectionne sa voisine.
    private func delete(_ id: UUID) {
        let ids = controller.history.map(\.id)
        if let index = ids.firstIndex(of: id), selection == id {
            let remaining = ids.filter { $0 != id }
            selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
        }
        controller.deleteFromHistory(id)
    }

    private func selectFirstIfNeeded() {
        if selection == nil || !controller.history.contains(where: { $0.id == selection }) {
            selection = controller.history.first?.id
        }
    }
}

/// Ligne de la liste : état, date, durée et volume copié.
private struct HistoryRow: View {
    let run: RunReport

    var body: some View {
        HStack(spacing: 10) {
            let badge = StatusBadge(run: run)
            Image(systemName: badge.symbol)
                .foregroundStyle(badge.color)
                .font(.system(size: 15))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.dateTime(run.startedAt))
                    .fontWeight(.medium)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(run.destination.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var details: String {
        var parts = [run.statusTitle]
        if let end = run.finishedAt {
            parts.append(formatDuration(from: run.startedAt, to: end))
        }
        if run.copiedFiles > 0 {
            parts.append(L10n.count(run.copiedFiles, "copié", "copiés", "copied", "copied"))
            parts.append(SystemInfo.formatBytes(run.copiedBytes))
        } else if run.isFinished && !run.cancelled {
            parts.append(tr("aucun changement", "no changes"))
        }
        return parts.joined(separator: " · ")
    }
}
