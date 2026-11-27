#if canImport(AppleArchive)
import AppleArchive
import CommonCrypto
import CryptoKit
import Foundation
import System

/// Archive chiffrée d'un dossier, en **morceaux indépendants** (`archive-0001.aea`, `-0002`…).
///
/// Chaque morceau est une archive Apple Archive complète, compressée (LZFSE) et chiffrée (AEA,
/// AES-256), contenant un lot d'environ `partSize` octets de fichiers (`ArchivePlan.batches`).
/// Pour chaque lot, un dossier temporaire de **liens physiques** vers les fichiers (aucune copie :
/// les originaux ne sont jamais modifiés) est archivé, puis supprimé. Avantages : l'espace local
/// utilisé reste de l'ordre d'un morceau ; un morceau abîmé ne fait perdre que ses fichiers.
///
/// Uniquement des flux fichiers standard (`fileStream(path:)`), comme l'exemple officiel d'Apple :
/// le chiffrement AEA réécrit son prologue à la fin, à l'offset 0 (un tube est refusé), et le flux
/// personnalisé `customStream` a planté sur macOS 13.
///
/// Chiffrement : le profil AEA à mot de passe (scrypt) refuse le mot de passe sur macOS 13
/// (`setPassword` échoue). On utilise le profil à clé symétrique (macOS 12+), avec une clé de
/// 256 bits **dérivée du mot de passe** par PBKDF2-HMAC-SHA256 (CommonCrypto). Le sel aléatoire et
/// le nombre d'itérations sont écrits en clair dans `cle.json` : non secrets, mais indispensables.
///
/// macOS uniquement (Apple Archive) ; testé par `EncryptedArchiveTests` sur Mac.
public enum EncryptedArchive {
    public static let partPrefix = "archive-"
    public static let partSuffix = ".aea"
    /// Paramètres de dérivation de la clé (non secrets), à côté des morceaux.
    public static let keyFileName = "cle.json"
    /// Itérations PBKDF2 (recommandation OWASP pour HMAC-SHA256).
    public static let defaultIterations = 600_000

    public enum Failure: Error, Equatable, LocalizedError {
        case cannotCreateStream(String)
        case unreadableArchive
        case wrongPasswordOrDamaged(String)
        case noParts(String)
        case cancelled
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .cannotCreateStream(let what):
                return tr("Impossible de créer le flux d'archive (\(what)).", "Cannot create the archive stream (\(what)).")
            case .unreadableArchive:
                return tr("Archive illisible ou endommagée.", "Unreadable or damaged archive.")
            case .wrongPasswordOrDamaged(let part):
                return tr("Mot de passe incorrect ou archive endommagée (\(part)).", "Wrong password or damaged archive (\(part)).")
            case .noParts(let path):
                return tr("Aucun morceau d'archive trouvé dans \(path).", "No archive part found in \(path).")
            case .cancelled:
                return tr("Opération annulée.", "Operation cancelled.")
            case .io(let message):
                return message
            }
        }
    }

    public struct Result {
        /// Morceaux écrits, dans l'ordre.
        public var parts: [URL]
        /// Éléments non archivés (disparus ou illisibles entre l'inventaire et l'archivage).
        public var issues: [SyncIssue]
    }

    /// Champs conservés : type, chemin, lien, contenu, droits, dates, attributs étendus. Ni
    /// propriétaire (UID/GID) ni drapeaux (FLG), comme pour la copie vers le disque.
    static let fieldKeys = "TYP,PAT,LNK,DEV,DAT,MOD,MTM,BTM,CTM,XAT"

    // MARK: Clé

    struct KeyParameters: Codable, Equatable {
        var algorithm = "PBKDF2-HMAC-SHA256"
        var iterations: Int
        var salt: Data
    }

    /// Clé AES-256 dérivée du mot de passe.
    static func deriveKey(password: String, parameters: KeyParameters) throws -> SymmetricKey {
        guard parameters.algorithm == "PBKDF2-HMAC-SHA256", parameters.iterations > 0,
              !parameters.salt.isEmpty else {
            throw Failure.unreadableArchive
        }
        let passwordBytes = Array(password.utf8).map { CChar(bitPattern: $0) }
        var derived = [UInt8](repeating: 0, count: 32)
        let status: Int32 = passwordBytes.withUnsafeBufferPointer { pwd in
            parameters.salt.withUnsafeBytes { salt in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pwd.baseAddress, pwd.count,
                                     salt.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                     UInt32(parameters.iterations),
                                     &derived, derived.count)
            }
        }
        guard Int(status) == kCCSuccess else { throw Failure.cannotCreateStream("key") }
        return SymmetricKey(data: derived)
    }

    static func writeKeyParameters(_ parameters: KeyParameters, in directory: URL) throws {
        let data = try JSONEncoder().encode(parameters)
        try data.write(to: directory.appendingPathComponent(keyFileName), options: .atomic)
    }

    static func readKeyParameters(in directory: URL) throws -> KeyParameters {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(keyFileName)),
              let parameters = try? JSONDecoder().decode(KeyParameters.self, from: data) else {
            throw Failure.unreadableArchive
        }
        return parameters
    }

    // MARK: Création

    /// Archive `items` (par défaut tout le contenu de `sourceDirectory`) dans `partsDirectory`.
    /// - Parameters:
    ///   - partSize: taille visée d'un morceau, en octets (un fichier plus gros forme un morceau seul).
    ///   - beforeNewPart: appelé avant chaque morceau ; peut bloquer (contre-pression) ou lever une erreur.
    ///   - onPartCompleted: appelé quand un morceau est écrit et fermé, avec son URL et sa taille.
    /// - Note: en cas d'erreur ou d'annulation, tous les morceaux déjà écrits sont supprimés
    ///   (une archive partielle ne doit jamais passer pour complète).
    @discardableResult
    public static func create(
        from sourceDirectory: URL,
        items: [ArchiveItem]? = nil,
        to partsDirectory: URL,
        password: String,
        partSize: Int64 = 1 << 30,
        iterations: Int = defaultIterations,
        beforeNewPart: () throws -> Void = {},
        onPartCompleted: (URL, Int64) -> Void = { _, _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> Result {
        let fm = FileManager.default
        let sourcePath = SyncEngine.resolvedPath(sourceDirectory.path)
        let toArchive = try items ?? ArchivePlan.scan(sourceDirectory, isCancelled: isCancelled).items
        try fm.createDirectory(at: partsDirectory, withIntermediateDirectories: true)

        var salt = Data(count: 16)
        salt.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        let parameters = KeyParameters(iterations: iterations, salt: salt)
        let key = try deriveKey(password: password, parameters: parameters)
        try writeKeyParameters(parameters, in: partsDirectory)

        var written: [URL] = []
        var issues: [SyncIssue] = []
        let staging = fm.temporaryDirectory.appendingPathComponent("msb-lot-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }

        do {
            let batches = ArchivePlan.batches(toArchive, partSize: partSize)
            for (index, batch) in batches.enumerated() {
                if isCancelled() { throw Failure.cancelled }
                try beforeNewPart()

                try? fm.removeItem(at: staging)
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                issues += try stage(batch, from: sourcePath, into: staging, isCancelled: isCancelled)

                let name = partPrefix + String(format: "%04d", index + 1) + partSuffix
                let final = partsDirectory.appendingPathComponent(name)
                // Écrit sous un nom provisoire : un morceau interrompu n'a jamais le nom définitif.
                let temporary = partsDirectory.appendingPathComponent("." + name + ".tmp")
                try? fm.removeItem(at: temporary)
                try writeArchive(of: staging, to: temporary, key: key)
                try? fm.removeItem(at: final)
                try fm.moveItem(at: temporary, to: final)
                written.append(final)
                let size = (try? fm.attributesOfItem(atPath: final.path)[.size] as? NSNumber)?.int64Value ?? 0
                onPartCompleted(final, size)
            }
            return Result(parts: written, issues: issues)
        } catch {
            for url in written { try? fm.removeItem(at: url) }
            if let leftovers = try? fm.contentsOfDirectory(atPath: partsDirectory.path) {
                for name in leftovers where name.hasSuffix(".tmp") {
                    try? fm.removeItem(at: partsDirectory.appendingPathComponent(name))
                }
            }
            try? fm.removeItem(at: partsDirectory.appendingPathComponent(keyFileName))
            throw error
        }
    }

    /// Reproduit le lot dans `staging` sous forme de liens physiques (clone ou copie en repli,
    /// par exemple si le dossier temporaire est sur un autre volume). Les originaux ne sont jamais
    /// ouverts en écriture.
    static func stage(_ batch: [ArchiveItem], from sourcePath: String, into staging: URL,
                      isCancelled: () -> Bool) throws -> [SyncIssue] {
        let fm = FileManager.default
        var issues: [SyncIssue] = []
        for item in batch {
            if isCancelled() { throw Failure.cancelled }
            let source = sourcePath + "/" + item.path
            let target = staging.appendingPathComponent(item.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch item.kind {
            case .directory:
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            case .symlink:
                guard let destination = try? fm.destinationOfSymbolicLink(atPath: source) else {
                    issues.append(SyncIssue(path: item.path, message: tr("lien illisible", "unreadable link")))
                    continue
                }
                try fm.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
            case .file:
                if link(source, target.path) == 0 { continue }
                if errno == ENOENT {
                    issues.append(SyncIssue(path: item.path, message: tr("disparu depuis l'inventaire", "gone since the scan")))
                    continue
                }
                if copyfile(source, target.path, nil, copyfile_flags_t(COPYFILE_CLONE | COPYFILE_ALL)) != 0 {
                    issues.append(SyncIssue(path: item.path, message: String(cString: strerror(errno))))
                }
            }
        }
        return issues
    }

    /// Ouvre un flux, exécute `body`, puis le libère **avant** de rendre la main : en imbriquant
    /// ces appels, chaque flux est toujours libéré avant le flux dont il dépend.
    ///
    /// Indispensable : en cas d'erreur, la désallocation d'un flux Apple Archive le ferme
    /// (`deinit` → `AAArchiveStreamClose`) ; si le flux dont il dépend a déjà été fermé à la main,
    /// c'est un plantage (EXC_BAD_ACCESS constaté sur macOS 13 avec un morceau abîmé). On ne ferme
    /// donc les flux explicitement qu'en cas de succès, du plus interne au plus externe, pour que
    /// leurs erreurs remontent ; en cas d'échec, on laisse la libération ordonnée s'en charger.
    private static func scoped<Stream: AnyObject, R>(
        _ stream: Stream?, orThrow failure: @autoclosure () -> Error, _ body: (Stream) throws -> R
    ) throws -> R {
        guard let stream else { throw failure() }
        return try body(stream)
    }

    private static func writeArchive(of directory: URL, to file: URL, key: SymmetricKey) throws {
        let context = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__symmetric__none,
                                               compressionAlgorithm: .lzfse)
        do {
            try context.setSymmetricKey(key)
        } catch {
            throw Failure.cannotCreateStream("key")
        }
        guard let keySet = ArchiveHeader.FieldKeySet(fieldKeys) else {
            throw Failure.cannotCreateStream("keys")
        }
        let fileStream = ArchiveByteStream.fileStream(path: FilePath(file.path), mode: .writeOnly,
                                                      options: [.create, .truncate],
                                                      permissions: FilePermissions(rawValue: 0o644))
        try scoped(fileStream, orThrow: Failure.cannotCreateStream("file")) { output in
            let encryption = ArchiveByteStream.encryptionStream(writingTo: output, encryptionContext: context)
            try scoped(encryption, orThrow: Failure.cannotCreateStream("encryption")) { encrypted in
                try scoped(ArchiveStream.encodeStream(writingTo: encrypted),
                           orThrow: Failure.cannotCreateStream("encode")) { encoder in
                    try encoder.writeDirectoryContents(archiveFrom: FilePath(directory.path), keySet: keySet)
                    try encoder.close()
                }
                try encrypted.close()
            }
            try output.close()
        }
    }

    // MARK: Relecture

    /// Morceaux d'une archive, dans l'ordre.
    public static func parts(in partsDirectory: URL) throws -> [URL] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: partsDirectory.path)) ?? [])
            .filter { $0.hasPrefix(partPrefix) && $0.hasSuffix(partSuffix) }
            .sorted()
        guard !names.isEmpty else { throw Failure.noParts(partsDirectory.path) }
        return names.map { partsDirectory.appendingPathComponent($0) }
    }

    /// Déchiffre et extrait tous les morceaux de `partsDirectory` dans `destination`.
    /// - Parameter beforeReadingPart: appelé avant chaque morceau (par exemple pour le télécharger
    ///   depuis iCloud) ; peut bloquer ou lever une erreur.
    public static func extract(
        from partsDirectory: URL,
        to destination: URL,
        password: String,
        beforeReadingPart: (URL) throws -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws {
        let partURLs = try parts(in: partsDirectory)
        let key = try deriveKey(password: password, parameters: try readKeyParameters(in: partsDirectory))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for part in partURLs {
            if isCancelled() { throw Failure.cancelled }
            try beforeReadingPart(part)
            try extractPart(part, to: destination, key: key)
        }
    }

    private static func extractPart(_ part: URL, to destination: URL, key: SymmetricKey) throws {
        let name = part.lastPathComponent
        let damaged = Failure.wrongPasswordOrDamaged(name)
        let fileStream = ArchiveByteStream.fileStream(path: FilePath(part.path), mode: .readOnly, options: [],
                                                      permissions: FilePermissions(rawValue: 0o644))
        try scoped(fileStream, orThrow: Failure.io(tr("Lecture impossible de \(name)", "Cannot read \(name)"))) { input in
            guard let context = ArchiveEncryptionContext(from: input),
                  (try? context.setSymmetricKey(key)) != nil else {
                throw damaged
            }
            let decryption = ArchiveByteStream.decryptionStream(readingFrom: input, encryptionContext: context)
            try scoped(decryption, orThrow: damaged) { decrypted in
                try scoped(ArchiveStream.decodeStream(readingFrom: decrypted), orThrow: damaged) { decoder in
                    try scoped(ArchiveStream.extractStream(extractingTo: FilePath(destination.path)),
                               orThrow: Failure.cannotCreateStream("extract")) { extractor in
                        do {
                            _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor)
                            try extractor.close()
                        } catch {
                            throw damaged
                        }
                    }
                    do { try decoder.close() } catch { throw damaged }
                }
                do { try decrypted.close() } catch { throw damaged }
            }
            try? input.close()
        }
    }
}
#endif
