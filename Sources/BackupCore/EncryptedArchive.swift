#if canImport(AppleArchive)
import AppleArchive
import CommonCrypto
import CryptoKit
import Foundation
import System

/// Archive Apple Archive compressée (LZFSE) et chiffrée (AEA, AES-256), écrite et relue
/// **au fil de l'eau** et découpée en morceaux (`archive.aea.0001`, `.0002`…).
///
/// Chiffrement : le profil AEA « mot de passe » (scrypt) refuse le mot de passe sur macOS 13
/// (`setPassword` échoue ; il ne fonctionne qu'à partir de macOS 14). On utilise donc le profil à
/// clé symétrique (macOS 12+), avec une clé de 256 bits **dérivée du mot de passe** par
/// PBKDF2-HMAC-SHA256 (CommonCrypto). Le sel aléatoire et le nombre d'itérations sont écrits en
/// clair dans `cle.json` à côté des morceaux : ils ne sont pas secrets, mais indispensables.
///
/// Écriture : Apple Archive écrit dans un flux personnalisé (`PartedSink`) qui répartit les octets
/// en morceaux de `partSize`. Le chiffrement AEA réécrit son en-tête (« prologue ») **à la fin**, à
/// l'offset 0 : le flux doit accepter les écritures positionnées (un tube ne convient pas), et le
/// **premier morceau** reste donc ouvert jusqu'à la fermeture ; il n'est signalé terminé
/// (`onPartCompleted`) qu'en dernier. Les autres morceaux sont signalés dès qu'ils sont pleins.
/// `beforeNewPart` est appelé avant chaque nouveau morceau et peut bloquer : Apple Archive attend
/// alors (contre-pression), ce qui limite l'espace disque utilisé localement.
///
/// Relecture : un thread recolle les morceaux dans l'ordre dans un tube lu par Apple Archive.
///
/// Une archive inachevée (erreur, annulation) est indéchiffrable : tous ses morceaux sont supprimés.
///
/// macOS uniquement (Apple Archive) ; testé par `EncryptedArchiveTests` sur Mac.
public enum EncryptedArchive {
    public static let partPrefix = "archive.aea."
    /// Paramètres de dérivation de la clé (non secrets), à côté des morceaux.
    public static let keyFileName = "cle.json"
    /// Itérations PBKDF2 (recommandation OWASP pour HMAC-SHA256).
    public static let defaultIterations = 600_000

    struct KeyParameters: Codable, Equatable {
        var algorithm = "PBKDF2-HMAC-SHA256"
        var iterations: Int
        var salt: Data
    }

    /// Clé AES-256 dérivée du mot de passe.
    static func deriveKey(password: String, parameters: KeyParameters) throws -> SymmetricKey {
        guard parameters.algorithm == "PBKDF2-HMAC-SHA256", parameters.iterations > 0 else {
            throw Failure.unreadableArchive
        }
        var derived = [UInt8](repeating: 0, count: 32)
        let status = parameters.salt.withUnsafeBytes { salt in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 password, password.utf8.count,
                                 salt.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                 UInt32(parameters.iterations),
                                 &derived, derived.count)
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
        iterations: Int = defaultIterations,
        beforeNewPart: @escaping () throws -> Void = {},
        onPartCompleted: @escaping (URL, Int64) -> Void = { _, _ in },
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> [URL] {
        try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
        var salt = Data(count: 16)
        salt.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        let parameters = KeyParameters(iterations: iterations, salt: salt)
        let key = try deriveKey(password: password, parameters: parameters)
        try writeKeyParameters(parameters, in: partsDirectory)

        let sink = PartedSink(directory: partsDirectory, partSize: partSize, beforeNewPart: beforeNewPart,
                              onPartCompleted: onPartCompleted, isCancelled: isCancelled)
        do {
            try writeArchive(of: sourceDirectory, to: sink, key: key)
            return try sink.finish()
        } catch {
            sink.abandon()
            try? FileManager.default.removeItem(at: partsDirectory.appendingPathComponent(keyFileName))
            // Une erreur levée par le flux (annulation, crochet) prime sur celle d'Apple Archive.
            if let failure = sink.failure { throw failure }
            throw (error as? Failure) ?? Failure.io(error.localizedDescription)
        }
    }

    /// Fermetures explicites et dans l'ordre (archive, chiffrement, flux) : une erreur lors de
    /// l'écriture finale doit remonter, sinon l'archive serait tronquée sans avertissement.
    private static func writeArchive(of sourceDirectory: URL, to sink: PartedSink, key: SymmetricKey) throws {
        guard let output = ArchiveByteStream.customStream(instance: sink) else {
            throw Failure.cannotCreateStream("output")
        }
        let context = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__symmetric__none,
                                               compressionAlgorithm: .lzfse)
        do {
            try context.setSymmetricKey(key)
        } catch {
            try? output.close()
            throw Failure.cannotCreateStream("key")
        }
        guard let encryptionStream = ArchiveByteStream.encryptionStream(writingTo: output,
                                                                        encryptionContext: context) else {
            try? output.close()
            throw Failure.cannotCreateStream("encryption")
        }
        guard let encoder = ArchiveStream.encodeStream(writingTo: encryptionStream),
              let keySet = ArchiveHeader.FieldKeySet(fieldKeys) else {
            try? encryptionStream.close()
            try? output.close()
            throw Failure.cannotCreateStream("encode")
        }
        do {
            try encoder.writeDirectoryContents(archiveFrom: FilePath(sourceDirectory.path), keySet: keySet)
        } catch {
            try? encoder.close()
            try? encryptionStream.close()
            try? output.close()
            throw error
        }
        do {
            try encoder.close()
            try encryptionStream.close()
        } catch {
            try? output.close()
            throw error
        }
        try output.close()
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
        let key = try deriveKey(password: password, parameters: try readKeyParameters(in: partsDirectory))
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
            try readArchive(fromDescriptor: readEnd, to: destination, key: key)
        } catch {
            archiveError = error
        }
        done.wait()

        if let joinerError = joiner.error { throw joinerError }
        if let archiveError {
            throw (archiveError as? Failure) ?? Failure.wrongPasswordOrDamaged
        }
    }

    private static func readArchive(fromDescriptor fd: Int32, to destination: URL, key: SymmetricKey) throws {
        guard let fileStream = ArchiveByteStream.fileStream(fd: FileDescriptor(rawValue: fd), automaticClose: true) else {
            close(fd)
            throw Failure.cannotCreateStream("fd")
        }
        guard let context = ArchiveEncryptionContext(from: fileStream) else {
            try? fileStream.close()
            throw Failure.unreadableArchive
        }
        guard (try? context.setSymmetricKey(key)) != nil,
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

/// Flux d'écriture Apple Archive réparti en morceaux. Écritures séquentielles : à la suite, en
/// ouvrant un nouveau morceau quand le courant est plein. Écritures et lectures positionnées
/// (prologue AEA réécrit à l'offset 0 en fin de chiffrement) : dans le morceau concerné.
private final class PartedSink: ArchiveByteStreamProtocol {
    private struct Part {
        let url: URL
        var size: Int64
        var completed = false
    }

    let directory: URL
    let partSize: Int64
    let beforeNewPart: () throws -> Void
    let onPartCompleted: (URL, Int64) -> Void
    let isCancelled: () -> Bool

    private var parts: [Part] = []
    /// Descripteurs ouverts : morceau courant et premier morceau (réécrit à la fin).
    private var openFiles: [Int: Int32] = [:]
    private let lock = NSLock()
    private(set) var failure: Error?

    init(directory: URL, partSize: Int64, beforeNewPart: @escaping () throws -> Void,
         onPartCompleted: @escaping (URL, Int64) -> Void, isCancelled: @escaping () -> Bool) {
        self.directory = directory
        self.partSize = max(partSize, 64 * 1024)
        self.beforeNewPart = beforeNewPart
        self.onPartCompleted = onPartCompleted
        self.isCancelled = isCancelled
    }

    deinit {
        for fd in openFiles.values { Darwin.close(fd) }
    }

    // MARK: ArchiveByteStreamProtocol

    func write(from buffer: UnsafeRawBufferPointer) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return try guarded {
            if isCancelled() { throw EncryptedArchive.Failure.cancelled }
            var done = 0
            while done < buffer.count {
                if parts.isEmpty || parts[parts.count - 1].size >= partSize {
                    try startNewPart()
                }
                let index = parts.count - 1
                let room = Int(partSize - parts[index].size)
                let count = min(room, buffer.count - done)
                try pwriteAll(UnsafeRawBufferPointer(rebasing: buffer[done..<(done + count)]),
                              part: index, at: parts[index].size)
                parts[index].size += Int64(count)
                done += count
            }
            return buffer.count
        }
    }

    func write(from buffer: UnsafeRawBufferPointer, atOffset offset: Int64) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return try guarded {
            var done = 0
            while done < buffer.count {
                let absolute = offset + Int64(done)
                let index = Int(absolute / partSize)
                let local = absolute % partSize
                guard index < parts.count else { throw EncryptedArchive.Failure.io("write beyond end") }
                if parts[index].completed && index != 0 {
                    // Morceau déjà confié à l'envoi (et peut-être libéré) : on ne peut plus le modifier.
                    throw EncryptedArchive.Failure.io("rewrite of a completed part (\(index + 1))")
                }
                let count = min(Int(partSize - local), buffer.count - done)
                try pwriteAll(UnsafeRawBufferPointer(rebasing: buffer[done..<(done + count)]), part: index, at: local)
                parts[index].size = max(parts[index].size, local + Int64(count))
                done += count
            }
            return buffer.count
        }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, atOffset offset: Int64) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return try guarded {
            let index = Int(offset / partSize)
            guard index < parts.count else { return 0 }
            let local = offset % partSize
            let available = Int(max(0, parts[index].size - local))
            let count = min(buffer.count, available)
            guard count > 0 else { return 0 }
            let fd = try descriptor(for: index)
            let n = pread(fd, buffer.baseAddress, count, local)
            guard n >= 0 else { throw EncryptedArchive.Failure.io(String(cString: strerror(errno))) }
            return n
        }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        throw EncryptedArchive.Failure.io("sequential read not supported")
    }

    func seek(toOffset offset: Int64, relativeTo origin: FileDescriptor.SeekOrigin) throws -> Int64 {
        throw EncryptedArchive.Failure.io("seek not supported")
    }

    func cancel() {}

    func close() throws {}

    // MARK: Fin

    /// Fin normale : synchronise et ferme les morceaux, signale ceux qui restaient (le premier en
    /// dernier, puisqu'il vient d'être réécrit) et renvoie la liste ordonnée.
    func finish() throws -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        for index in openFiles.keys.sorted(by: >) {
            try closeFile(index, sync: true)
        }
        for index in parts.indices.reversed() where !parts[index].completed {
            parts[index].completed = true
            onPartCompleted(parts[index].url, parts[index].size)
        }
        return parts.map(\.url)
    }

    /// Échec ou annulation : l'archive est inutilisable, tous ses morceaux sont supprimés.
    func abandon() {
        lock.lock()
        defer { lock.unlock() }
        for fd in openFiles.values { Darwin.close(fd) }
        openFiles.removeAll()
        for part in parts { try? FileManager.default.removeItem(at: part.url) }
        parts.removeAll()
    }

    // MARK: Morceaux

    /// Mémorise la première erreur levée (elle prime sur celle qu'Apple Archive en déduira).
    private func guarded<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            if failure == nil { failure = error }
            throw error
        }
    }

    private func startNewPart() throws {
        if let last = parts.indices.last, last != 0 {
            // Morceau plein (sauf le premier, réécrit à la fin) : fermé, synchronisé et signalé.
            try closeFile(last, sync: true)
            parts[last].completed = true
            onPartCompleted(parts[last].url, parts[last].size)
        }
        try beforeNewPart()
        let name = EncryptedArchive.partPrefix + String(format: "%04d", parts.count + 1)
        let url = directory.appendingPathComponent(name)
        let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw EncryptedArchive.Failure.io(tr("Impossible de créer \(url.path)", "Cannot create \(url.path)")
                                              + " (\(String(cString: strerror(errno))))")
        }
        openFiles[parts.count] = fd
        parts.append(Part(url: url, size: 0))
    }

    private func descriptor(for index: Int) throws -> Int32 {
        if let fd = openFiles[index] { return fd }
        let fd = open(parts[index].url.path, O_RDWR)
        guard fd >= 0 else { throw EncryptedArchive.Failure.io(String(cString: strerror(errno))) }
        openFiles[index] = fd
        return fd
    }

    private func closeFile(_ index: Int, sync: Bool) throws {
        guard let fd = openFiles.removeValue(forKey: index) else { return }
        defer { Darwin.close(fd) }
        if sync, fsync(fd) != 0 {
            throw EncryptedArchive.Failure.io(String(cString: strerror(errno)))
        }
    }

    private func pwriteAll(_ buffer: UnsafeRawBufferPointer, part index: Int, at offset: Int64) throws {
        let fd = try descriptor(for: index)
        var done = 0
        while done < buffer.count {
            let n = pwrite(fd, buffer.baseAddress! + done, buffer.count - done, offset + Int64(done))
            if n < 0 {
                if errno == EINTR { continue }
                throw EncryptedArchive.Failure.io(String(cString: strerror(errno)))
            }
            done += n
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
