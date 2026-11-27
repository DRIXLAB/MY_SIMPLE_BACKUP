import BackupCore
import SwiftUI

/// Réglages de la sauvegarde iCloud : dossier, mot de passe des archives, archive complète.
struct ICloudSettingsView: View {
    @ObservedObject var controller: BackupController
    @Environment(\.dismiss) private var dismiss

    @State private var editingPassword = false
    @State private var password = ""
    @State private var confirmation = ""
    @State private var passwordError: String?
    @State private var confirmFullArchive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(tr("Sauvegarde vers iCloud Drive", "Backup to iCloud Drive"), systemImage: "icloud.fill")
                .font(.title3.weight(.semibold))
            Text(tr("Chaque dossier est envoyé dans une archive compressée et chiffrée par votre mot de passe : une archive complète la première fois, puis uniquement les changements. Les fichiers ne restent pas sur ce Mac une fois envoyés.",
                    "Each folder is uploaded as an archive compressed and encrypted with your password: a full archive the first time, then only the changes. Files do not stay on this Mac once uploaded."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !ICloudDrive.isAvailable {
                Label(tr("iCloud Drive n'est pas activé sur ce Mac (Réglages Système › votre nom › iCloud).",
                         "iCloud Drive is not enabled on this Mac (System Settings › your name › iCloud)."),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            folderSection
            Divider()
            passwordSection
            Divider()
            fullArchiveSection

            HStack {
                Spacer()
                Button(tr("Fermer", "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .confirmationDialog(tr("Repartir d'une archive complète ?", "Start over from a full archive?"),
                            isPresented: $confirmFullArchive) {
            Button(tr("Repartir d'une archive complète", "Start over from a full archive"), role: .destructive) {
                controller.requestFullArchive()
            }
            Button(tr("Annuler", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("À la prochaine sauvegarde, chaque dossier sera entièrement renvoyé vers iCloud. Les anciennes archives seront supprimées une fois la nouvelle terminée, ce qui libère l'espace iCloud occupé par les fichiers supprimés et les anciennes versions.",
                    "At the next backup, every folder will be uploaded again in full. The old archives will be deleted once the new one is complete, freeing the iCloud space used by deleted files and old versions."))
        }
    }

    // MARK: Dossier

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Dossier dans iCloud Drive", "Folder in iCloud Drive")).font(.headline)
            HStack {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(controller.iCloudFolderDisplay ?? tr("Aucun dossier choisi", "No folder chosen"))
                    .foregroundStyle(controller.iCloudFolder == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(tr("Choisir…", "Choose…")) { controller.chooseICloudFolder() }
                    .disabled(!ICloudDrive.isAvailable)
            }
            Text(tr("Un sous-dossier par élément y est créé (Documents, Images…), ainsi que la liste des applications, en clair.",
                    "One subfolder per item is created there (Documents, Pictures…), plus the application list, unencrypted."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Mot de passe

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Mot de passe des archives", "Archive password")).font(.headline)
            if editingPassword || !controller.hasICloudPassword {
                SecureField(tr("Mot de passe (8 caractères minimum)", "Password (at least 8 characters)"), text: $password)
                SecureField(tr("Confirmation", "Confirmation"), text: $confirmation)
                Label(tr("Notez ce mot de passe en lieu sûr : sans lui, les archives sont définitivement illisibles. Il ne peut pas être récupéré, ni par vous ni par Apple.",
                         "Write this password down somewhere safe: without it, the archives can never be read. It cannot be recovered, neither by you nor by Apple."),
                      systemImage: "exclamationmark.lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if controller.hasICloudPassword {
                    Text(tr("Changer le mot de passe fera repartir chaque dossier d'une nouvelle archive complète (les archives existantes restent chiffrées avec l'ancien).",
                            "Changing the password will start each folder over from a new full archive (existing archives stay encrypted with the old one)."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let passwordError {
                    Text(passwordError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    if controller.hasICloudPassword {
                        Button(tr("Annuler", "Cancel")) { resetPasswordFields() }
                    }
                    Button(tr("Enregistrer dans le trousseau", "Save to the keychain")) {
                        if let error = controller.setICloudPassword(password, confirmation: confirmation) {
                            passwordError = error
                        } else {
                            resetPasswordFields()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || confirmation.isEmpty)
                }
            } else {
                HStack {
                    Label(tr("Enregistré dans le trousseau de ce Mac", "Saved in this Mac's keychain"),
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button(tr("Changer…", "Change…")) { editingPassword = true }
                }
            }
        }
    }

    private func resetPasswordFields() {
        password = ""
        confirmation = ""
        passwordError = nil
        editingPassword = false
    }

    // MARK: Archive complète

    private var fullArchiveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Archive complète", "Full archive")).font(.headline)
            if controller.pendingFullArchive.isEmpty {
                HStack {
                    Text(tr("Les sauvegardes n'envoient que les changements. Repartir d'une archive complète permet de récupérer l'espace iCloud.",
                            "Backups only upload changes. Starting over from a full archive reclaims iCloud space."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(tr("Repartir d'une archive complète…", "Start over from a full archive…")) {
                        confirmFullArchive = true
                    }
                }
            } else {
                HStack {
                    Label(tr("La prochaine sauvegarde iCloud repartira d'une archive complète.",
                             "The next iCloud backup will start over from a full archive."),
                          systemImage: "arrow.clockwise.icloud")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Spacer()
                    if !controller.fullArchiveRequired {
                        Button(tr("Annuler la demande", "Cancel request")) { controller.cancelFullArchiveRequest() }
                    }
                }
            }
        }
    }
}
