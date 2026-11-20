import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Synchronisation incrémentale `source/ → destination/`, à la manière de `rsync -a --safe-links`.
///
/// Fonctionnement en deux phases :
/// 1. **Plan** : parcours de la source et comparaison avec la destination (taille + date de
///    modification, à `modifyWindow` près). Rien n'est modifié ; on obtient la liste des actions
///    et le volume total à copier, ce qui donne une progression exacte.
/// 2. **Exécution** : les actions sont appliquées dans l'ordre (suppressions d'un dossier avant
///    ses créations, comme `rsync --delete-during`).
///
/// Garanties de sécurité :
/// - la source n'est jamais modifiée ;
/// - source et destination imbriquées → refus (`SyncError.overlappingPaths`) ;
/// - aucune suppression hors de la destination, et aucun lien symbolique de la destination n'est suivi ;
/// - un dossier source illisible n'entraîne aucune suppression dans la destination correspondante ;
/// - une source vide n'entraîne pas l'effacement complet d'une destination non vide ;
/// - les fichiers AppleDouble (« ._nom ») d'un disque non Mac ne sont pas supprimés tant que
///   « nom » existe dans la source ;
/// - chaque fichier est écrit dans un fichier temporaire puis renommé : une copie interrompue
///   ne laisse jamais de fichier tronqué sous le nom final.
public final class SyncEngine {
    public typealias ProgressHandler = (SyncProgress) -> Void
    public typealias CancellationCheck = () -> Bool

    /// Point d'injection pour les tests : liste le contenu d'un dossier de la source.
    var listSourceDirectory: (String) throws -> [String] = SyncEngine.listDirectory

    public init() {}

    /// Synchronise le *contenu* de `source` dans `destination` (créée si besoin).
    /// - Parameters:
    ///   - isCancelled: interrogé entre chaque élément et chaque bloc copié.
    ///   - progress: appelé au plus toutes les 100 ms depuis le thread appelant.
    /// - Throws: `SyncError` pour les erreurs bloquantes ; les problèmes par élément sont dans `SyncStats.issues`.
    public func sync(
        source: URL,
        destination: URL,
        options: SyncOptions = SyncOptions(),
        isCancelled: @escaping CancellationCheck = { false },
        progress: @escaping ProgressHandler = { _ in }
    ) throws -> SyncStats {
        let srcRoot = Self.resolvedPath(source.path)
        let dstRoot = Self.resolvedPath(destination.path)

        guard FileManager.default.fileExists(atPath: srcRoot) else {
            throw SyncError.sourceNotFound(source.path)
        }
        guard Entry.read(atPath: srcRoot)?.kind == .directory else {
            throw SyncError.sourceNotDirectory(source.path)
        }
        if Self.pathsOverlap(srcRoot, dstRoot) {
            throw SyncError.overlappingPaths(source: srcRoot, destination: dstRoot)
        }

        let run = SyncRun(
            srcRoot: srcRoot, dstRoot: dstRoot, options: options,
            listSourceDirectory: listSourceDirectory,
            isCancelled: isCancelled, progressHandler: progress
        )
        return try run.execute()
    }

    // MARK: - Utilitaires de chemins (internes, testés)

    /// Chemin absolu avec liens symboliques résolus, y compris quand la fin du chemin n'existe pas encore.
    static func resolvedPath(_ path: String) -> String {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            missing.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
        var resolved = url.resolvingSymlinksInPath()
        for component in missing { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL.path
    }

    /// Vrai si les deux chemins sont identiques ou si l'un contient l'autre.
    /// Comparaison insensible à la casse (APFS/HFS+ par défaut) : en cas de doute, on refuse.
    static func pathsOverlap(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        func contains(_ parent: String, _ child: String) -> Bool {
            parent == "/" || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
        }
        return a == b || contains(a, b) || contains(b, a)
    }

    /// Règle `rsync --safe-links` : un lien est sûr s'il est relatif et ne sort jamais de l'arborescence.
    /// - Parameter linkDirectory: dossier du lien, relatif à la racine synchronisée.
    static func isSafeLink(target: String, linkDirectory: String) -> Bool {
        if target.isEmpty || target.hasPrefix("/") { return false }
        var depth = linkDirectory.split(separator: "/").count
        for component in target.split(separator: "/") {
            if component == ".." {
                depth -= 1
                if depth < 0 { return false }
            } else if component != "." {
                depth += 1
            }
        }
        return true
    }

    /// Contenu d'un dossier via `opendir`/`readdir`, sans aucun filtrage.
    /// Pas `FileManager.contentsOfDirectory` : sur macOS, il omet les fichiers AppleDouble « ._nom »,
    /// qui ne seraient alors ni sauvegardés côté source ni vus côté destination.
    static func listDirectory(_ path: String) throws -> [String] {
        guard let directory = opendir(path) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: tuple.pointee)) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    static let tempPrefix = ".sauvegarde-"
    static let tempSuffix = ".tmp"

    static func isTempName(_ name: String) -> Bool {
        name.hasPrefix(tempPrefix) && name.hasSuffix(tempSuffix)
    }
}

// MARK: - Métadonnées d'un élément (sans suivre les liens symboliques)

struct Entry {
    enum Kind { case directory, file, symlink, other }

    let kind: Kind
    let size: Int64
    let modificationDate: Date
    let permissions: Int

    /// `nil` si l'élément n'existe pas ou n'est pas accessible.
    static func read(atPath path: String) -> Entry? {
        try? readOrThrow(atPath: path)
    }

    static func readOrThrow(atPath path: String) throws -> Entry {
        // attributesOfItem ne suit pas les liens symboliques (lstat).
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let type: FileAttributeType? = (attrs[.type] as? FileAttributeType)
            ?? (attrs[.type] as? String).map(FileAttributeType.init(rawValue:))
        let kind: Kind
        switch type {
        case .typeDirectory?: kind = .directory
        case .typeRegular?: kind = .file
        case .typeSymbolicLink?: kind = .symlink
        default: kind = .other
        }
        return Entry(
            kind: kind,
            size: int64(attrs[.size]),
            modificationDate: attrs[.modificationDate] as? Date ?? .distantPast,
            permissions: Int(int64(attrs[.posixPermissions]))
        )
    }

    private static func int64(_ value: Any?) -> Int64 {
        switch value {
        case let n as NSNumber: return n.int64Value
        case let n as Int: return Int64(n)
        case let n as Int64: return n
        case let n as UInt64: return Int64(n)
        case let n as UInt16: return Int64(n)
        default: return 0
        }
    }
}

// MARK: - Exécution d'une synchronisation

private final class SyncRun {
    enum Action {
        case removeExtraneous(String)
        case removeConflicting(String)
        case removeStaleTemp(String)
        case makeDirectory(String)
        case copyFile(String, size: Int64, modificationDate: Date, permissions: Int)
        case setPermissions(String, Int)
        case makeSymlink(String, target: String)

        var path: String {
            switch self {
            case .removeExtraneous(let p), .removeConflicting(let p), .removeStaleTemp(let p),
                 .makeDirectory(let p), .copyFile(let p, _, _, _), .setPermissions(let p, _),
                 .makeSymlink(let p, _):
                return p
            }
        }
    }

    struct DirectoryMeta {
        let path: String
        let permissions: Int
        let modificationDate: Date
    }

    let srcRoot: String
    let dstRoot: String
    let options: SyncOptions
    let listSourceDirectory: (String) throws -> [String]
    let isCancelled: SyncEngine.CancellationCheck
    let progressHandler: SyncEngine.ProgressHandler
    let fm = FileManager.default

    var actions: [Action] = []
    var directories: [DirectoryMeta] = []
    var stats = SyncStats()
    var progress = SyncProgress(phase: .scanning)
    var lastEmit = Date.distantPast
    /// Vrai dès qu'une modification de permissions est restée sans effet (exFAT, FAT…).
    var permissionsUnsupported = false

    init(srcRoot: String, dstRoot: String, options: SyncOptions,
         listSourceDirectory: @escaping (String) throws -> [String],
         isCancelled: @escaping SyncEngine.CancellationCheck,
         progressHandler: @escaping SyncEngine.ProgressHandler) {
        self.srcRoot = srcRoot
        self.dstRoot = dstRoot
        self.options = options
        self.listSourceDirectory = listSourceDirectory
        self.isCancelled = isCancelled
        self.progressHandler = progressHandler
    }

    func execute() throws -> SyncStats {
        try fm.createDirectory(atPath: dstRoot, withIntermediateDirectories: true)

        try plan()

        progress.phase = .transferring
        progress.filesDone = 0
        emit(force: true)

        for action in actions {
            try checkCancelled()
            try apply(action)
        }

        // Permissions et dates des dossiers en dernier, du plus profond au moins profond,
        // pour que l'écriture de leur contenu ne modifie plus leur date.
        for dir in directories.reversed() {
            let path = dstPath(dir.path)
            try? fm.setAttributes([.posixPermissions: (dir.permissions & 0o777) | 0o700], ofItemAtPath: path)
            try? fm.setAttributes([.modificationDate: dir.modificationDate], ofItemAtPath: path)
        }

        progress.currentPath = nil
        emit(force: true)
        return stats
    }

    // MARK: Phase 1 — plan

    /// Parcours itératif (pile explicite) : pas de récursion, donc pas de risque de débordement
    /// de pile sur une arborescence très profonde. Un dossier est créé (action `makeDirectory`)
    /// avant que son contenu ne soit planifié.
    func plan() throws {
        var pending = [""]
        while let rel = pending.popLast() {
            try checkCancelled()
            let subdirectories = try plan(directory: rel)
            pending.append(contentsOf: subdirectories.reversed())
        }
    }

    /// Planifie le contenu d'un dossier ; renvoie ses sous-dossiers à parcourir, dans l'ordre.
    func plan(directory rel: String) throws -> [String] {
        let names: [String]
        do {
            names = try listSourceDirectory(srcPath(rel)).sorted()
        } catch {
            if rel.isEmpty {
                throw SyncError.sourceUnreadable(srcRoot, Self.reason(error))
            }
            issue(rel, tr("lecture du dossier impossible (\(Self.reason(error))) — ignoré, rien n'y est supprimé",
                          "cannot read folder (\(Self.reason(error))) — skipped, nothing deleted in it"))
            return []
        }

        let dstNames: [String]
        if Entry.read(atPath: dstPath(rel))?.kind == .directory {
            dstNames = (try? SyncEngine.listDirectory(dstPath(rel))) ?? []
        } else {
            dstNames = []
        }

        // Éléments présents uniquement dans la destination.
        var allowDelete = options.deleteExtraneous
        if rel.isEmpty, names.isEmpty, allowDelete,
           dstNames.contains(where: { !SyncEngine.isTempName($0) }) {
            allowDelete = false
            issue("", tr("la source est vide : suppression dans la destination annulée par sécurité",
                         "the source is empty: deletion in the destination cancelled for safety"))
        }
        // Insensible à la casse : sur un volume insensible à la casse, « foo » et « Foo »
        // sont le même fichier ; dans le doute, on conserve.
        let sourceNames = Set(names.map { $0.lowercased() })
        for name in dstNames where !sourceNames.contains(name.lowercased()) {
            let path = join(rel, name)
            if SyncEngine.isTempName(name) {
                actions.append(.removeStaleTemp(path))
                continue
            }
            // « ._nom » : métadonnées AppleDouble de « nom » sur un disque non Mac (exFAT, FAT…).
            // Tant que « nom » existe dans la source, ce n'est pas un élément en trop.
            if name.hasPrefix("._"), sourceNames.contains(String(name.dropFirst(2)).lowercased()) {
                continue
            }
            if allowDelete {
                actions.append(.removeExtraneous(path))
            }
        }

        var subdirectories: [String] = []
        for name in names {
            let path = join(rel, name)
            let source: Entry
            do {
                source = try Entry.readOrThrow(atPath: srcPath(path))
            } catch {
                issue(path, tr("inaccessible (\(Self.reason(error)))", "not accessible (\(Self.reason(error)))"))
                continue
            }
            let existing = Entry.read(atPath: dstPath(path))

            switch source.kind {
            case .directory:
                if let existing, existing.kind != .directory {
                    guard scheduleReplacement(path, existing) else { continue }
                }
                if existing?.kind != .directory {
                    actions.append(.makeDirectory(path))
                }
                directories.append(DirectoryMeta(
                    path: path, permissions: source.permissions, modificationDate: source.modificationDate))
                subdirectories.append(path)

            case .file:
                stats.sourceFiles += 1
                progress.filesTotal += 1
                progress.currentPath = path
                emit()
                if let existing, existing.kind == .file,
                   existing.size == source.size,
                   abs(existing.modificationDate.timeIntervalSince(source.modificationDate)) <= options.modifyWindow {
                    // Bits rwx uniquement (setuid, setgid, sticky ne sont jamais copiés).
                    if existing.permissions & 0o777 != source.permissions & 0o777 {
                        actions.append(.setPermissions(path, source.permissions & 0o777))
                    }
                    continue
                }
                if let existing, existing.kind != .file {
                    guard scheduleReplacement(path, existing) else { continue }
                }
                actions.append(.copyFile(path, size: source.size,
                                         modificationDate: source.modificationDate,
                                         permissions: source.permissions))
                progress.bytesTotal += source.size

            case .symlink:
                guard let target = try? fm.destinationOfSymbolicLink(atPath: srcPath(path)),
                      SyncEngine.isSafeLink(target: target, linkDirectory: rel) else {
                    stats.skippedItems += 1
                    continue
                }
                if let existing {
                    if existing.kind == .symlink,
                       (try? fm.destinationOfSymbolicLink(atPath: dstPath(path))) == target {
                        continue
                    }
                    guard scheduleReplacement(path, existing) else { continue }
                }
                actions.append(.makeSymlink(path, target: target))

            case .other:
                stats.skippedItems += 1
            }
        }
        return subdirectories
    }

    /// Un élément de la destination d'un autre type bloque la copie. Un fichier ou un lien est
    /// remplacé ; un dossier ne l'est que si la suppression est autorisée (comme rsync sans --force).
    func scheduleReplacement(_ path: String, _ existing: Entry) -> Bool {
        if existing.kind == .directory && !options.deleteExtraneous {
            issue(path, tr("un dossier du même nom existe dans la destination — activez la suppression pour le remplacer",
                           "a folder with the same name exists in the destination — enable deletion to replace it"))
            return false
        }
        actions.append(.removeConflicting(path))
        return true
    }

    // MARK: Phase 2 — exécution

    /// Les erreurs par élément sont consignées dans `stats.issues` ; seule l'annulation est propagée.
    func apply(_ action: Action) throws {
        let path = action.path
        let bytesBefore = progress.bytesDone
        do {
            switch action {
            case .removeExtraneous(let p):
                try remove(p)
                stats.deletedItems += 1
            case .removeConflicting(let p), .removeStaleTemp(let p):
                try remove(p)
            case .makeDirectory(let p):
                try fm.createDirectory(atPath: dstPath(p), withIntermediateDirectories: false)
            case .copyFile(let p, let size, let date, let permissions):
                progress.currentPath = p
                emit()
                try copyFile(p, modificationDate: date, permissions: permissions)
                stats.copiedFiles += 1
                stats.copiedBytes += size
                progress.filesDone += 1
                // La taille réelle peut différer si le fichier a changé depuis le plan.
                progress.bytesDone = bytesBefore + size
                emit()
            case .setPermissions(let p, let permissions):
                guard !permissionsUnsupported else { break }
                try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: dstPath(p))
                // Volume sans permissions POSIX (exFAT, FAT…) : la modification n'a aucun effet et
                // serait retentée à chaque sauvegarde pour chaque fichier. On arrête pour cette fois.
                if let after = Entry.read(atPath: dstPath(p)), after.permissions & 0o777 != permissions {
                    permissionsUnsupported = true
                }
            case .makeSymlink(let p, let target):
                try fm.createSymbolicLink(atPath: dstPath(p), withDestinationPath: target)
            }
        } catch SyncError.cancelled {
            throw SyncError.cancelled
        } catch {
            // Disque débranché : inutile d'échouer fichier par fichier, on arrête tout.
            if !fm.fileExists(atPath: dstRoot) {
                throw SyncError.destinationUnavailable(dstRoot)
            }
            issue(path, Self.reason(error))
            if case .copyFile(_, let size, _, _) = action {
                progress.bytesDone = bytesBefore + size
            }
        }
    }

    func remove(_ rel: String) throws {
        // Ne jamais supprimer la racine ni sortir de la destination.
        precondition(!rel.isEmpty && !rel.split(separator: "/").contains(".."),
                     "chemin de suppression invalide : \(rel)")
        // removeItem supprime un lien symbolique sans suivre sa cible.
        try fm.removeItem(atPath: dstPath(rel))
    }

    func copyFile(_ rel: String, modificationDate: Date, permissions: Int) throws {
        let source = srcPath(rel)
        let destination = dstPath(rel)
        let directory = (destination as NSString).deletingLastPathComponent
        let token = UUID().uuidString.prefix(8).lowercased()
        let temp = directory + "/" + SyncEngine.tempPrefix + token + SyncEngine.tempSuffix

        guard let input = FileHandle(forReadingAtPath: source) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: source])
        }
        defer { try? input.close() }

        guard fm.createFile(atPath: temp, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp])
        }
        var installed = false
        defer { if !installed { try? fm.removeItem(atPath: temp) } }

        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: temp))
        do {
            while true {
                try checkCancelled()
                guard let chunk = try input.read(upToCount: options.chunkSize), !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
                progress.bytesDone += Int64(chunk.count)
                emit()
            }
            try output.close()
        } catch {
            try? output.close()
            throw error
        }

        #if canImport(Darwin)
        // Attributs étendus : étiquettes Finder, forks de ressources, commentaires Spotlight…
        // Ni ACL ni drapeaux (verrouillé, immuable) : ils empêcheraient les sauvegardes suivantes
        // de remplacer le fichier (rsync -a ne les copie pas non plus). Échec non bloquant (exFAT…).
        _ = copyfile(source, temp, nil, copyfile_flags_t(COPYFILE_XATTR))
        #endif
        try fm.setAttributes([.posixPermissions: permissions & 0o777], ofItemAtPath: temp)
        try fm.setAttributes([.modificationDate: modificationDate], ofItemAtPath: temp)

        if rename(temp, destination) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        installed = true
    }

    // MARK: Utilitaires

    func checkCancelled() throws {
        if isCancelled() { throw SyncError.cancelled }
    }

    func emit(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastEmit) >= 0.1 else { return }
        lastEmit = now
        progressHandler(progress)
    }

    func issue(_ path: String, _ message: String) {
        stats.issues.append(SyncIssue(path: path, message: message))
    }

    func join(_ rel: String, _ name: String) -> String { rel.isEmpty ? name : rel + "/" + name }
    func srcPath(_ rel: String) -> String { rel.isEmpty ? srcRoot : srcRoot + "/" + rel }
    func dstPath(_ rel: String) -> String { rel.isEmpty ? dstRoot : dstRoot + "/" + rel }

    static func reason(_ error: Error) -> String {
        if let posix = error as? POSIXError { return String(cString: strerror(posix.code.rawValue)) }
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        return ns.localizedDescription
    }
}
