#if canImport(AppleArchive)
import AppleArchive
import Foundation
import System

/// Archive Apple Archive compressée (LZFSE) et chiffrée par mot de passe (AEA, AES-256),
/// écrite et relue **au fil de l'eau** et découpée en morceaux (`archive.aea.0001`, `.0002`…).
///
/// Le découpage passe par un tube (`pipe`) : Apple Archive écrit le flux chiffré dans le tube, un
/// thread le lit et le répartit en morceaux de `partSize` octets. Un morceau n'est qu'une tranche
/// du flux chiffré : la relecture recolle les morceaux dans l'ordre (`extract`). Le crochet
/// `beforeNewPart` est appelé avant chaque nouveau morceau et peut bloquer : tant qu'il bloque,
/// plus rien n'est lu dans le tube et Apple Archive attend (contre-pression), ce qui limite
/// l'espace disque utilisé localement.
///
/// macOS uniquement (Apple Archive) ; testé par `EncryptedArchiveTests` sur Mac.
public enum EncryptedArchive {
    public static let partPrefix = "archive.aea."

    public enum Failure: Error, Equatable, LocalizedError {
        case cannotCreateStream(String)
        case unreadableArchive
        case wrongPasswordOrDamaged
        case noParts(String)
        case cancelled
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .cannotCreateStream(let what):
                return tr("Impossible de créer le flux d'archive (\(what)).", "Cannot create the archive stream (\(what)).")
            case .unreadableArchive:
                return tr("Archive illisible ou endommagée.", "Unreadable or damaged archive.")
            case .wrongPasswordOrDamaged:
                return tr("Mot de passe incorrect ou archive endommagée.", "Wrong password or damaged archive.")
            case .noParts(let path):
                return tr("Aucun morceau d'archive trouvé dans \(path).", "No archive part found in \(path).")
            case .cancelled:
                return tr("Opération annulée.", "Operation cancelled.")
            case .io(let message):
                return message
            }
        }
    }

    /// Champs conservés pour chaque élément : type, chemin, lien, contenu, droits, dates,
    /// attributs étendus. Ni propriétaire (UID/GID) ni drapeaux (FLG) : comme pour la copie vers
    /// le disque, ils gêneraient la restauration sur un autre Mac ou un autre compte.
    static let fieldKeys = "TYP,PAT,LNK,DEV,DAT,MOD,MTM,BTM,CTM,XAT"

    // MARK: Création

    /// Archive tout le contenu de `sourceDirectory` dans `partsDirectory` (créé si besoin).
    /// - Parameters:
    ///   - partSize: taille d'un morceau, en octets.
    ///   - beforeNewPart: appelé avant d'ouvrir chaque morceau (peut bloquer, ou lever une erreur).
    ///   - onPartCompleted: appelé à la fermeture de chaque morceau, avec son URL et sa taille.
    ///   - isCancelled: consulté entre chaque bloc écrit.
    /// - Returns: les morceaux écrits, dans l'ordre.
    @discardableResult
    public static func create(
        from sourceDirectory: URL,
        to partsDirectory: URL,
        password: String,
        partSize: Int64 = 1 << 30,
        beforeNewPart: @escaping () throws -> Void = {},
        onPartCompleted: @escaping (URL, Int64) -> Void = { _, _ in },
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> [URL] {
        try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
        let (readEnd, writeEnd) = try makePipe()

        // Thread lecteur : tube → morceaux.
        let splitter = PartSplitter(directory: partsDirectory, partSize: partSize,
                                    beforeNewPart: beforeNewPart, onPartCompleted: onPartCompleted,
                                    isCancelled: isCancelled)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            splitter.run(readingFrom: readEnd)
            close(readEnd)
            done.signal()
        }
        thread.stackSize = 1 << 20
        thread.start()

        // Thread courant : dossier → archive → compression + chiffrement → tube.
        var archiveError: Error?
        do {
            try writeArchive(of: sourceDirectory, toDescriptor: writeEnd, password: password)
        } catch {
            archiveError = error
        }
        done.wait()

        // Une annulation ou une erreur côté morceaux ferme le tube et fait échouer Apple Archive :
        // c'est alors la cause d'origine qu'on remonte.
        if let splitterError = splitter.error { throw splitterError }
        if let archiveError {
            throw (archiveError as? Failure) ?? Failure.io(archiveError.localizedDescription)
        }
        return splitter.parts
    }

    /// Fermetures explicites et dans l'ordre (archive, chiffrement, fichier) : une erreur lors de
    /// l'écriture finale doit remonter, sinon l'archive serait tronquée sans avertissement.
    private static func writeArchive(of sourceDirectory: URL, toDescriptor fd: Int32, password: String) throws {
        guard let fileStream = ArchiveByteStream.fileStream(fd: FileDescriptor(rawValue: fd), automaticClose: true) else {
            close(fd)
            throw Failure.cannotCreateStream("fd")
        }
        let context = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__scrypt__none,
                                               compressionAlgorithm: .lzfse)
        guard (try? context.setPassword(password)) != nil,
              let encryptionStream = ArchiveByteStream.encryptionStream(writingTo: fileStream,
                                                                        encryptionContext: context) else {
            try? fileStream.close()
            throw Failure.cannotCreateStream("encryption")
        }
        guard let encoder = ArchiveStream.encodeStream(writingTo: encryptionStream),
              let keySet = ArchiveHeader.FieldKeySet(fieldKeys) else {
            try? encryptionStream.close()
            try? fileStream.close()
            throw Failure.cannotCreateStream("encode")
        }
        do {
            try encoder.writeDirectoryContents(archiveFrom: FilePath(sourceDirectory.path), keySet: keySet)
        } catch {
            try? encoder.close()
            try? encryptionStream.close()
            try? fileStream.close()
            throw error
        }
        do {
            try encoder.close()
            try encryptionStream.close()
        } catch {
            try? fileStream.close()
            throw error
        }
        try fileStream.close()
    }

    // MARK: Relecture

    /// Morceaux d'une archive, dans l'ordre.
    public static func parts(in partsDirectory: URL) throws -> [URL] {
        let names = try FileManager.default.contentsOfDirectory(atPath: partsDirectory.path)
            .filter { $0.hasPrefix(partPrefix) }
            .sorted()
        guard !names.isEmpty else { throw Failure.noParts(partsDirectory.path) }
        return names.map { partsDirectory.appendingPathComponent($0) }
    }

    /// Déchiffre et extrait l'archive de `partsDirectory` dans `destination` (créé si besoin).
    /// - Parameter beforeReadingPart: appelé avant de lire chaque morceau (par exemple pour le
    ///   télécharger depuis iCloud) ; peut bloquer ou lever une erreur.
    public static func extract(
        from partsDirectory: URL,
        to destination: URL,
        password: String,
        beforeReadingPart: @escaping (URL) throws -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { false }
    ) throws {
        let partURLs = try parts(in: partsDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let (readEnd, writeEnd) = try makePipe()

        // Thread écrivain : morceaux → tube.
        let joiner = PartJoiner(parts: partURLs, beforeReadingPart: beforeReadingPart, isCancelled: isCancelled)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            joiner.run(writingTo: writeEnd)
            close(writeEnd)
            done.signal()
        }
        thread.stackSize = 1 << 20
        thread.start()

        var archiveError: Error?
        do {
            try readArchive(fromDescriptor: readEnd, to: destination, password: password)
        } catch {
            archiveError = error
        }
        done.wait()

        if let joinerError = joiner.error { throw joinerError }
        if let archiveError {
            throw (archiveError as? Failure) ?? Failure.wrongPasswordOrDamaged
        }
    }

    private static func readArchive(fromDescriptor fd: Int32, to destination: URL, password: String) throws {
        guard let fileStream = ArchiveByteStream.fileStream(fd: FileDescriptor(rawValue: fd), automaticClose: true) else {
            close(fd)
            throw Failure.cannotCreateStream("fd")
        }
        guard let context = ArchiveEncryptionContext(from: fileStream) else {
            try? fileStream.close()
            throw Failure.unreadableArchive
        }
        guard (try? context.setPassword(password)) != nil,
              let decryptionStream = ArchiveByteStream.decryptionStream(readingFrom: fileStream,
                                                                        encryptionContext: context) else {
            try? fileStream.close()
            throw Failure.wrongPasswordOrDamaged
        }
        guard let decoder = ArchiveStream.decodeStream(readingFrom: decryptionStream) else {
            try? decryptionStream.close()
            try? fileStream.close()
            throw Failure.wrongPasswordOrDamaged
        }
        guard let extractor = ArchiveStream.extractStream(extractingTo: FilePath(destination.path)) else {
            try? decoder.close()
            try? decryptionStream.close()
            try? fileStream.close()
            throw Failure.cannotCreateStream("extract")
        }
        var failed = false
        do {
            _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor)
        } catch {
            failed = true
        }
        // Toutes les fermetures sont tentées ; la moindre erreur rend la restauration douteuse.
        if (try? extractor.close()) == nil { failed = true }
        if (try? decoder.close()) == nil { failed = true }
        if (try? decryptionStream.close()) == nil { failed = true }
        try? fileStream.close()
        if failed { throw Failure.wrongPasswordOrDamaged }
    }

    // MARK: Tube

    /// Tube dont l'écriture ne déclenche pas SIGPIPE (qui tuerait l'app) si le lecteur s'arrête.
    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            throw Failure.io(String(cString: strerror(errno)))
        }
        _ = fcntl(fds[1], F_SETNOSIGPIPE, 1)
        _ = fcntl(fds[0], F_SETNOSIGPIPE, 1)
        return (fds[0], fds[1])
    }
}

// MARK: - Découpage en morceaux

private final class PartSplitter {
    let directory: URL
    let partSize: Int64
    let beforeNewPart: () throws -> Void
    let onPartCompleted: (URL, Int64) -> Void
    let isCancelled: () -> Bool

    private(set) var parts: [URL] = []
    private(set) var error: Error?

    init(directory: URL, partSize: Int64, beforeNewPart: @escaping () throws -> Void,
         onPartCompleted: @escaping (URL, Int64) -> Void, isCancelled: @escaping () -> Bool) {
        self.directory = directory
        self.partSize = max(partSize, 64 * 1024)
        self.beforeNewPart = beforeNewPart
        self.onPartCompleted = onPartCompleted
        self.isCancelled = isCancelled
    }

    func run(readingFrom fd: Int32) {
        let bufferSize = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var current: FileHandle?
        var currentURL: URL?
        var written: Int64 = 0

        func finishPart() {
            guard let handle = current, let url = currentURL else { return }
            try? handle.synchronize()
            try? handle.close()
            current = nil
            parts.append(url)
            onPartCompleted(url, written)
        }

        do {
            while true {
                if isCancelled() { throw EncryptedArchive.Failure.cancelled }
                let count = read(fd, buffer, bufferSize)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw EncryptedArchive.Failure.io(String(cString: strerror(errno)))
                }
                if count == 0 { break }

                var offset = 0
                while offset < count {
                    if current == nil {
                        try beforeNewPart()
                        let name = EncryptedArchive.partPrefix + String(format: "%04d", parts.count + 1)
                        let url = directory.appendingPathComponent(name)
                        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                            throw EncryptedArchive.Failure.io(tr("Impossible de créer \(url.path)", "Cannot create \(url.path)"))
                        }
                        current = try FileHandle(forWritingTo: url)
                        currentURL = url
                        written = 0
                    }
                    let room = Int(min(Int64(count - offset), partSize - written))
                    try current!.write(contentsOf: Data(bytes: buffer + offset, count: room))
                    written += Int64(room)
                    offset += room
                    if written >= partSize { finishPart() }
                }
            }
            finishPart()
        } catch {
            self.error = error
            // Morceau inachevé : supprimé, il ne doit jamais être pris pour un morceau valide.
            if let handle = current {
                try? handle.close()
                if let url = currentURL { try? FileManager.default.removeItem(at: url) }
            }
        }
    }
}

// MARK: - Recollage des morceaux

private struct ReaderStopped: Error {}

private final class PartJoiner {
    let parts: [URL]
    let beforeReadingPart: (URL) throws -> Void
    let isCancelled: () -> Bool
    private(set) var error: Error?

    init(parts: [URL], beforeReadingPart: @escaping (URL) throws -> Void, isCancelled: @escaping () -> Bool) {
        self.parts = parts
        self.beforeReadingPart = beforeReadingPart
        self.isCancelled = isCancelled
    }

    func run(writingTo fd: Int32) {
        do {
            for part in parts {
                try beforeReadingPart(part)
                let handle = try FileHandle(forReadingFrom: part)
                defer { try? handle.close() }
                while true {
                    if isCancelled() { throw EncryptedArchive.Failure.cancelled }
                    guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                    try chunk.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            let count = write(fd, raw.baseAddress! + offset, raw.count - offset)
                            if count < 0 {
                                let code = errno
                                if code == EINTR { continue }
                                // Lecteur arrêté : c'est son erreur (Apple Archive) qui sera remontée.
                                if code == EPIPE { throw ReaderStopped() }
                                throw EncryptedArchive.Failure.io(String(cString: strerror(code)))
                            }
                            offset += count
                        }
                    }
                }
            }
        } catch is ReaderStopped {
            // Le lecteur a abandonné : sa propre erreur suffit.
        } catch {
            self.error = error
        }
    }
}
#endif
