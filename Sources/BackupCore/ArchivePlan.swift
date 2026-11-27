import Foundation

/// Élément à placer dans une archive chiffrée (chemin relatif à la racine du dossier sauvegardé).
public struct ArchiveItem: Equatable, Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case file, symlink, directory }

    public let path: String
    public let kind: Kind
    /// Taille en octets (0 pour un dossier ou un lien).
    public let size: Int64
    public let modificationDate: Date

    public init(path: String, kind: Kind, size: Int64, modificationDate: Date) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modificationDate = modificationDate
    }
}

/// Préparation d'une archive chiffrée : inventaire d'un dossier et répartition en lots.
/// Indépendant d'Apple Archive, donc testé aussi sous Linux.
public enum ArchivePlan {
    public struct Scan: Equatable {
        public var items: [ArchiveItem] = []
        /// Sous-dossiers ou éléments illisibles, ignorés.
        public var issues: [SyncIssue] = []
        public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    }

    /// Inventaire de `root` : fichiers, liens symboliques et dossiers (y compris vides), triés par
    /// chemin. Parcours itératif, sans suivre les liens ; mêmes règles de lecture que `SyncEngine`
    /// (`listDirectory`, fichiers « ._nom » compris). Les fichiers spéciaux (sockets…) sont ignorés.
    /// - Throws: `SyncError.sourceUnreadable` si la racine elle-même est illisible.
    public static func scan(_ root: URL, isCancelled: () -> Bool = { false }) throws -> Scan {
        let rootPath = SyncEngine.resolvedPath(root.path)
        var result = Scan()
        var pending = [""]
        while let rel = pending.popLast() {
            if isCancelled() { throw SyncError.cancelled }
            let directory = rel.isEmpty ? rootPath : rootPath + "/" + rel
            let names: [String]
            do {
                names = try SyncEngine.listDirectory(directory).sorted()
            } catch {
                if rel.isEmpty { throw SyncError.sourceUnreadable(rootPath, error.localizedDescription) }
                result.issues.append(SyncIssue(path: rel, message: tr("lecture du dossier impossible", "cannot read folder")))
                continue
            }
            var subdirectories: [String] = []
            for name in names {
                let path = rel.isEmpty ? name : rel + "/" + name
                guard let entry = Entry.read(atPath: rootPath + "/" + path) else {
                    result.issues.append(SyncIssue(path: path, message: tr("inaccessible", "not accessible")))
                    continue
                }
                switch entry.kind {
                case .directory:
                    result.items.append(ArchiveItem(path: path, kind: .directory, size: 0,
                                                    modificationDate: entry.modificationDate))
                    subdirectories.append(path)
                case .file:
                    result.items.append(ArchiveItem(path: path, kind: .file, size: entry.size,
                                                    modificationDate: entry.modificationDate))
                case .symlink:
                    result.items.append(ArchiveItem(path: path, kind: .symlink, size: 0,
                                                    modificationDate: entry.modificationDate))
                case .other:
                    continue
                }
            }
            pending.append(contentsOf: subdirectories.reversed())
        }
        result.items.sort { $0.path < $1.path }
        return result
    }

    /// Répartit les éléments en lots consécutifs d'au plus `partSize` octets. Un fichier plus gros
    /// que `partSize` forme un lot à lui seul. Aucun lot n'est vide ; l'ordre est conservé.
    public static func batches(_ items: [ArchiveItem], partSize: Int64) -> [[ArchiveItem]] {
        var result: [[ArchiveItem]] = []
        var current: [ArchiveItem] = []
        var currentSize: Int64 = 0
        for item in items {
            if !current.isEmpty, currentSize + item.size > partSize {
                result.append(current)
                current = []
                currentSize = 0
            }
            current.append(item)
            currentSize += item.size
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
