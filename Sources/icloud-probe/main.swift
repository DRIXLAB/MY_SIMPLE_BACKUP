// Outil de diagnostic (étape 1 de la sauvegarde iCloud) : vérifie, sur ce Mac et en conditions
// réelles, que tout ce dont la sauvegarde iCloud aura besoin fonctionne.
//
//   swift run -c release icloud-probe "<dossier de test dans iCloud Drive>" [--garder]
//
// Étapes : archive chiffrée de fichiers de test → morceaux écrits dans le dossier iCloud → attente
// de l'envoi → libération de la copie locale → retéléchargement → déchiffrement → comparaison.
// Sans --garder, le dossier de test créé dans iCloud est supprimé à la fin.

import BackupCore
import Foundation

setvbuf(stdout, nil, _IONBF, 0)
L10n.language = .french

func say(_ text: String) { print(text) }
func ok(_ text: String) { print("  ✓ \(text)") }
func fail(_ text: String) -> Never {
    print("  ✗ \(text)")
    print("\nDiagnostic interrompu.")
    exit(1)
}
func step(_ text: String) { print("\n── \(text) ──") }

let args = CommandLine.arguments.dropFirst()
guard let folderArg = args.first(where: { !$0.hasPrefix("--") }) else {
    say("Usage : swift run -c release icloud-probe \"<dossier de test dans iCloud Drive>\" [--garder]")
    say("Exemple : swift run -c release icloud-probe \"$HOME/Library/Mobile Documents/com~apple~CloudDocs/Test MSB\"")
    exit(2)
}
let keep = args.contains("--garder")
let fm = FileManager.default
let iCloudFolder = URL(fileURLWithPath: (folderArg as NSString).expandingTildeInPath, isDirectory: true)
let password = "diagnostic-\(UUID().uuidString.prefix(8))"
let partSize: Int64 = 4 * 1024 * 1024
let started = Date()

// ── 1. iCloud Drive ──
step("1/6  iCloud Drive")
guard ICloudDrive.isAvailable else { fail("iCloud Drive introuvable (\(ICloudDrive.rootURL.path)) : est-il activé ?") }
ok("iCloud Drive présent")
guard ICloudDrive.contains(iCloudFolder) else { fail("Ce dossier n'est pas dans iCloud Drive : \(iCloudFolder.path)") }
do {
    try fm.createDirectory(at: iCloudFolder, withIntermediateDirectories: true)
} catch {
    fail("Création du dossier impossible : \(error.localizedDescription)")
}
ok("Dossier de test : \(iCloudFolder.path)")

// ── 2. Fichiers de test ──
step("2/6  Fichiers de test")
let work = fm.temporaryDirectory.appendingPathComponent("msb-diagnostic-\(UUID().uuidString)")
let source = work.appendingPathComponent("source")
let restored = work.appendingPathComponent("restauration")
do {
    try fm.createDirectory(at: source.appendingPathComponent("sous-dossier"), withIntermediateDirectories: true)
    try Data("Fichier texte de test MY SIMPLE BACKUP".utf8).write(to: source.appendingPathComponent("note.txt"))
    var random = Data(count: 10 * 1024 * 1024)
    random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
    try random.write(to: source.appendingPathComponent("sous-dossier/donnees.bin"))
} catch {
    fail("Création des fichiers de test impossible : \(error.localizedDescription)")
}
ok("10 Mo de données aléatoires + un fichier texte")

// ── 3. Archive chiffrée vers iCloud ──
step("3/6  Archive chiffrée, morceaux de 4 Mo, écrite dans iCloud")
let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
let partsFolder = iCloudFolder.appendingPathComponent("diagnostic-\(stamp)", isDirectory: true)
var parts: [URL] = []
do {
    parts = try EncryptedArchive.create(from: source, to: partsFolder, password: password, partSize: partSize,
                                        onPartCompleted: { url, size in
                                            ok("\(url.lastPathComponent) écrit (\(L10n.bytes(size)))")
                                        })
} catch {
    fail("Archivage impossible : \(error.localizedDescription)")
}
ok("\(parts.count) morceaux dans \(partsFolder.lastPathComponent)")

// ── 4. Envoi vers iCloud puis libération de la copie locale ──
step("4/6  Envoi vers iCloud et libération de la copie locale")
say("  (l'attente dépend de votre connexion ; jusqu'à 30 min par morceau avant abandon)")
for part in parts {
    var lastState: ICloudDrive.UploadState?
    do {
        try ICloudDrive.waitUntilUploaded(part, timeout: 30 * 60, onWait: { state in
            if state != lastState {
                lastState = state
                say("  … \(part.lastPathComponent) : \(state == .uploading ? "envoi en cours" : "en attente d'envoi")")
            }
        })
    } catch {
        fail("\(part.lastPathComponent) : \(error.localizedDescription)")
    }
    ok("\(part.lastPathComponent) envoyé")
    do {
        try ICloudDrive.evict(part)
    } catch {
        fail("Libération de \(part.lastPathComponent) refusée : \(error.localizedDescription)")
    }
    // La libération est asynchrone : on laisse quelques secondes à macOS.
    var evicted = false
    for _ in 0..<30 {
        if !ICloudDrive.isDownloaded(part) { evicted = true; break }
        Thread.sleep(forTimeInterval: 1)
    }
    if evicted {
        ok("\(part.lastPathComponent) : copie locale libérée")
    } else {
        say("  ⚠ \(part.lastPathComponent) : libération demandée, mais le fichier est encore local après 30 s")
    }
}

// ── 5. Retéléchargement et déchiffrement ──
step("5/6  Retéléchargement depuis iCloud et déchiffrement")
do {
    try EncryptedArchive.extract(from: partsFolder, to: restored, password: password,
                                 beforeReadingPart: { part in
                                     let wasLocal = ICloudDrive.isDownloaded(part)
                                     try ICloudDrive.download(part, timeout: 30 * 60)
                                     ok("\(part.lastPathComponent) \(wasLocal ? "déjà local" : "retéléchargé")")
                                 })
} catch {
    fail("Restauration impossible : \(error.localizedDescription)")
}
ok("Archive déchiffrée et extraite")

// ── 6. Vérification ──
step("6/6  Vérification")
for rel in ["note.txt", "sous-dossier/donnees.bin"] {
    let original = try? Data(contentsOf: source.appendingPathComponent(rel))
    let copy = try? Data(contentsOf: restored.appendingPathComponent(rel))
    guard let original, original == copy else { fail("\(rel) : contenu différent après restauration") }
    ok("\(rel) identique")
}
do {
    try EncryptedArchive.extract(from: partsFolder, to: work.appendingPathComponent("mauvais"), password: "mauvais")
    fail("Un mauvais mot de passe a été accepté")
} catch {
    ok("Un mauvais mot de passe est bien refusé")
}

try? fm.removeItem(at: work)
if keep {
    say("\nDossier de test conservé dans iCloud : \(partsFolder.path)")
} else {
    try? fm.removeItem(at: partsFolder)
    say("\nDossier de test supprimé d'iCloud.")
}
say("\n✓ Diagnostic réussi en \(L10n.duration(from: started, to: Date())) : la sauvegarde iCloud est réalisable sur ce Mac.")
