import AppKit
import BackupCore
import SwiftUI

/// Journal de la dernière sauvegarde : en-tête (état, durée, actions) puis une ligne par élément.
struct JournalView: View {
    let run: RunReport?
    let progress: SyncProgress?
    /// Hauteur de la liste défilante des éléments ; `nil` : pas de défilement propre
    /// (la vue est placée dans un conteneur qui défile, comme l'historique).
    var listHeight: CGFloat? = 228

    var body: some View {
        if let run {
            VStack(alignment: .leading, spacing: 10) {
                JournalHeader(run: run)
                if let listHeight {
                    ScrollViewReader { proxy in
                        ScrollView {
                            rows(run)
                        }
                        .frame(height: listHeight)
                        .onChange(of: run.running?.id) { id in
                            guard let id else { return }
                            withAnimation { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                } else {
                    rows(run)
                }
            }
        } else {
            EmptyJournal()
                .frame(height: (listHeight ?? 228) + 40)
        }
    }

    private func rows(_ run: RunReport) -> some View {
        VStack(spacing: 6) {
            ForEach(run.sources) { source in
                SourceRow(report: source, progress: source.status == .running ? progress : nil)
                    .id(source.id)
            }
        }
    }
}

/// « 1 min 5 s » entre deux dates.
func formatDuration(from start: Date, to end: Date) -> String {
    L10n.duration(from: start, to: end)
}

// MARK: - En-tête

private struct JournalHeader: View {
    let run: RunReport

    var body: some View {
        HStack(spacing: 10) {
            StatusBadge(run: run)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.dateTime(run.startedAt))
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(run.destination.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if run.deleteMode {
                        Text(tr("Suppression activée", "Deletion enabled"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.12), in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            // Mise à jour chaque seconde uniquement pendant la sauvegarde.
            if let end = run.finishedAt {
                durationLabel(formatDuration(from: run.startedAt, to: end))
            } else {
                TimelineView(.periodic(from: run.startedAt, by: 1)) { context in
                    durationLabel(formatDuration(from: run.startedAt, to: context.date))
                }
            }

            Button(action: copyToPasteboard) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(tr("Copier le journal", "Copy the log"))

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([run.destination])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help(tr("Afficher la destination dans le Finder", "Show the destination in Finder"))
        }
    }

    private func durationLabel(_ text: String) -> some View {
        Label(text, systemImage: "clock")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func copyToPasteboard() {
        let duration = formatDuration(from: run.startedAt, to: run.finishedAt ?? Date())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(run.plainText(duration: duration, label: BackupSource.label(for:)), forType: .string)
    }
}

struct StatusBadge: View {
    let run: RunReport

    var body: some View {
        HStack(spacing: 5) {
            if run.isFinished {
                Image(systemName: symbol)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(run.statusTitle)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
    }

    var symbol: String {
        if run.cancelled { return "stop.circle.fill" }
        return run.problemCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    var color: Color {
        if !run.isFinished { return .accentColor }
        if run.cancelled { return .gray }
        return run.problemCount == 0 ? .green : .orange
    }
}

// MARK: - Ligne d'un élément

private struct SourceRow: View {
    let report: SourceReport
    /// Progression du moteur, uniquement pour l'élément en cours.
    let progress: SyncProgress?
    @State private var showIssues = false

    private static let maxIssuesShown = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: report.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(tileColor.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(BackupSource.label(for: report))
                        .fontWeight(.medium)
                    subtitle
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if let start = report.startedAt, let end = report.finishedAt {
                    Text(formatDuration(from: start, to: end))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                statusIcon
                    .frame(width: 18)
            }

            if report.status == .running {
                progressBar
                    .padding(.leading, 36)
            }
            if !report.issues.isEmpty {
                issuesList
                    .padding(.leading, 36)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(report.status == .running ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
        )
        .animation(.easeInOut(duration: 0.2), value: report.status)
    }

    /// Nombre réel d'éléments non copiés (la liste est tronquée dans l'historique).
    private var issueTotal: Int { max(report.issueCount, report.issues.count) }

    private var tileColor: Color {
        switch report.status {
        case .pending, .cancelled: return .gray
        default: return .accentColor
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        switch report.status {
        case .pending:
            Text(tr("En attente", "Waiting"))
        case .running:
            if let p = progress, p.phase == .transferring {
                let done = SystemInfo.formatBytes(p.bytesDone), total = SystemInfo.formatBytes(p.bytesTotal)
                Text(tr("\(done) sur \(total)", "\(done) of \(total)") + "  ·  \(Int(p.fraction * 100)) %")
            } else {
                let files = L10n.count(progress?.filesTotal ?? 0, "fichier", "fichiers", "file", "files")
                Text(tr("Analyse… \(files)", "Scanning… \(files)"))
            }
        default:
            if let message = report.message {
                Text(message)
                    .foregroundStyle(.red)
            } else {
                Text(report.displaySummary ?? "")
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch report.status {
        case .pending:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let p = progress, p.phase == .transferring {
                ProgressView(value: p.fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            Text(progress?.currentPath ?? " ")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Liste dépliable des éléments non copiés. Bouton maison plutôt que `DisclosureGroup` :
    /// sur macOS, celui-ci ne réagit qu'au clic sur le petit triangle, pas sur le libellé.
    private var issuesList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showIssues.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showIssues ? 90 : 0))
                    Text(L10n.count(issueTotal, "élément non copié", "éléments non copiés",
                                    "item not copied", "items not copied"))
                        .font(.caption.weight(.medium))
                    Text(showIssues ? tr("Masquer", "Hide") : tr("Afficher", "Show"))
                        .font(.caption)
                        .underline()
                }
                .foregroundStyle(.orange)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showIssues ? tr("Masquer la liste", "Hide the list")
                             : tr("Afficher la liste des éléments non copiés", "Show the items that were not copied"))

            if showIssues {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(report.issues.prefix(Self.maxIssuesShown).enumerated()), id: \.offset) { _, issue in
                        Text(issue)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if issueTotal > min(report.issues.count, Self.maxIssuesShown) {
                        let hidden = issueTotal - min(report.issues.count, Self.maxIssuesShown)
                        Text(tr("… et \(hidden) autres", "… and \(hidden) more"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 13)
            }
        }
    }
}

// MARK: - État vide

private struct EmptyJournal: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(tr("Aucune sauvegarde pour le moment", "No backup yet"))
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(tr("Le déroulement de chaque élément s'affichera ici.", "The progress of each item will appear here."))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
