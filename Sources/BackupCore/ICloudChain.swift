import Foundation

// Chaîne de sauvegarde iCloud : une archive complète (étape 0) puis des incréments (étapes 1, 2…).
// Ce fichier ne dépend pas d'Apple Archive : modèle, comparaison, plan de restauration et
// organisation des dossiers, testés aussi sous Linux. L'exécution est dans ICloudBackup.swift.
//
// Organisation dans iCloud, pour un élément sauvegardé (ex. « Documents ») :
//
//   <dossier iCloud choisi>/Documents/
//     chaine-20261127T232100Z/                 une chaîne (nouvelle seulement sur demande)
//       0000-complete-20261127T232100Z/         étape 0 : archive complète
//         donnees/   archive-0001.aea …, cle.json   fichiers (absent s'il n'y a rien à archiver)
//         journal/   archive-0001.aea, cle.json      liste chiffrée des changements (ChainDelta)
//         termine                                    marqueur, écrit en dernier : étape validée
//       0001-increment-20261128T090000Z/        étape 1 : fichiers ajoutés ou modifiés + supprimés
//
// Une étape sans marqueur « termine » est inachevée (interrompue) : ignorée, puis supprimée à la
// sauvegarde suivante. Les noms de fichiers n'apparaissent jamais en clair dans iCloud.

/// Changements d'une étape de la chaîne (enregistré chiffré dans `journal/`).
public struct ChainDelta: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case complete, increment }

    public var formatVersion = 1
    public var step: Int
    public var kind: Kind
    public var date: Date
    /// Éléments ajoutés ou modifiés, présents dans l'archive de l'étape (tous pour l'étape 0).
    public var changed: [ArchiveItem]
    /// Chemins supprimés depuis l'étape précédente.
    public var deleted: [String]

    public init(step: Int, kind: Kind, date: Date, changed: [ArchiveItem], deleted: [String]) {
        self.step = step
        self.kind = kind
        self.date = date
        self.changed = changed
        self.deleted = deleted
    }

    public var changedFileCount: Int { changed.filter { $0.kind == .file }.count }
    public var changedBytes: Int64 { changed.reduce(0) { $0 + $1.size } }
}

/// État d'une source tel que sauvegardé : ce qui serait restauré à la dernière étape appliquée.
public struct ChainState: Equatable, Sendable {
    public var items: [String: ArchiveItem] = [:]

    public init(items: [ArchiveItem] = []) {
        for item in items { self.items[item.path] = item }
    }

    public mutating func apply(_ delta: ChainDelta) {
        for path in delta.deleted { items[path] = nil }
        for item in delta.changed { items[item.path] = item }
    }

    public var totalSize: Int64 { items.values.reduce(0) { $0 + $1.size } }
}

/// Comparaison entre l'état sauvegardé et l'inventaire actuel de la source.
public enum ChainDiff {
    /// - Parameters:
    ///   - unreadable: chemins que l'inventaire n'a pas pu lire (dossiers illisibles, éléments
    ///     inaccessibles) : ni eux ni leur contenu ne sont comptés comme supprimés, comme pour la
    ///     copie vers le disque (un dossier momentanément illisible ne doit pas « disparaître »).
    /// - Returns: éléments nouveaux ou modifiés (taille, type, ou date à `modifyWindow` près ;
    ///   pour un dossier, seulement s'il est nouveau) et chemins disparus, triés. Si l'inventaire
    ///   est vide, aucune suppression (source vide : probablement un problème d'accès).
    public static func compute(previous: ChainState, current: [ArchiveItem], unreadable: [String] = [],
                               modifyWindow: TimeInterval = 2) -> (changed: [ArchiveItem], deleted: [String]) {
        var changed: [ArchiveItem] = []
        for item in current {
            guard let old = previous.items[item.path] else {
                changed.append(item)
                continue
            }
            if old.kind != item.kind {
                changed.append(item)
            } else if item.kind != .directory,
                      old.size != item.size
                        || abs(old.modificationDate.timeIntervalSince(item.modificationDate)) > modifyWindow {
                changed.append(item)
            }
        }
        changed.sort { $0.path < $1.path }
        guard !current.isEmpty, !unreadable.contains("") else { return (changed, []) }
        let present = Set(current.map(\.path))
        let deleted = previous.items.keys.filter { path in
            !present.contains(path) && !unreadable.contains { path == $0 || path.hasPrefix($0 + "/") }
        }.sorted()
        return (changed, deleted)
    }
}

/// Plan de restauration à une étape donnée : pour chaque élément à restaurer, l'étape qui en
/// contient la dernière version. Restaurer « l'état au 15 mars » revient à ne prendre que les
/// étapes jusqu'à cette date.
public struct RestorePlan: Equatable {
    /// Éléments à restaurer, avec leur dernière version connue.
    public private(set) var items: [String: ArchiveItem] = [:]
    /// Étape qui contient la dernière version de chaque élément.
    public private(set) var stepOf: [String: Int] = [:]

    /// - Parameter deltas: changements des étapes à prendre en compte, dans l'ordre.
    public init(deltas: [ChainDelta]) {
        for delta in deltas {
            for path in delta.deleted {
                items[path] = nil
                stepOf[path] = nil
            }
            for item in delta.changed {
                items[item.path] = item
                stepOf[item.path] = delta.step
            }
        }
    }

    /// Éléments à extraire de l'étape `step`.
    public func paths(fromStep step: Int) -> Set<String> {
        Set(stepOf.filter { $0.value == step }.map(\.key))
    }

    /// Étapes dont il faut lire l'archive, dans l'ordre.
    public var neededSteps: [Int] { Set(stepOf.values).sorted() }

    public var totalSize: Int64 { items.values.reduce(0) { $0 + $1.size } }
}

/// Noms et lecture de l'organisation des dossiers d'une chaîne.
public enum ChainLayout {
    public static let chainPrefix = "chaine-"
    public static let dataFolder = "donnees"
    public static let journalFolder = "journal"
    public static let journalFileName = "journal.json"
    public static let commitMarker = "termine"

    public struct Step: Equatable {
        public let url: URL
        public let number: Int
        public let kind: ChainDelta.Kind
        public let date: Date
        public let committed: Bool
    }

    private static var stampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }

    public static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }

    public static func chainFolderName(date: Date) -> String { chainPrefix + stamp(date) }

    public static func stepFolderName(step: Int, kind: ChainDelta.Kind, date: Date) -> String {
        String(format: "%04d", step) + "-" + kind.rawValue + "-" + stamp(date)
    }

    /// « 0001-increment-20261128T090000Z » → (1, .increment, date).
    public static func parseStep(_ name: String) -> (number: Int, kind: ChainDelta.Kind, date: Date)? {
        let parts = name.split(separator: "-", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0].count == 4, let number = Int(parts[0]),
              let kind = ChainDelta.Kind(rawValue: parts[1]),
              let date = stampFormatter.date(from: parts[2]) else { return nil }
        return (number, kind, date)
    }

    /// Noms réels du contenu d'un dossier iCloud (fichiers libérés « .nom.icloud » compris).
    static func names(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .map(ArchivePlan.logicalFileName)
    }

    /// Chaînes d'une source, de la plus ancienne à la plus récente.
    public static func chains(in sourceFolder: URL) -> [URL] {
        names(in: sourceFolder)
            .filter { $0.hasPrefix(chainPrefix) }
            .sorted()
            .map { sourceFolder.appendingPathComponent($0, isDirectory: true) }
    }

    /// Étapes d'une chaîne, validées ou non, par numéro croissant.
    public static func steps(in chain: URL) -> [Step] {
        names(in: chain).compactMap { name -> Step? in
            guard let parsed = parseStep(name) else { return nil }
            let url = chain.appendingPathComponent(name, isDirectory: true)
            return Step(url: url, number: parsed.number, kind: parsed.kind, date: parsed.date,
                        committed: names(in: url).contains(commitMarker))
        }
        .sorted { $0.number < $1.number }
    }

    /// Étapes validées utilisables : 0, 1, 2… consécutives, la 0 étant une archive complète.
    /// On s'arrête au premier trou ou à la première étape non validée.
    public static func committedSteps(in chain: URL) -> [Step] {
        var result: [Step] = []
        for step in steps(in: chain) {
            guard step.committed, step.number == result.count else { break }
            if step.number == 0, step.kind != .complete { break }
            if step.number > 0, step.kind != .increment { break }
            result.append(step)
        }
        return result
    }

    /// Chaîne en cours : la plus récente dont l'archive complète (étape 0) est validée.
    public static func currentChain(in sourceFolder: URL) -> (url: URL, steps: [Step])? {
        for chain in chains(in: sourceFolder).reversed() {
            let steps = committedSteps(in: chain)
            if !steps.isEmpty { return (chain, steps) }
        }
        return nil
    }
}
