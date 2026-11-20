import Foundation

/// Inventaire des applications installées, écrit dans `applications.txt` à la racine de la sauvegarde.
/// Lecture directe des bundles `.app` (Info.plist), sans `system_profiler` : quelques millisecondes.
public enum AppInventory {
    public enum Origin: Sendable, Equatable { case appStore, other, system }

    public struct App: Sendable, Equatable {
        public let name: String
        public let version: String
        public let origin: Origin
    }

    public static let fileName = "applications.txt"

    /// Dossiers parcourus, avec l'origine attribuée par défaut aux apps qu'ils contiennent.
    public static var defaultDirectories: [(url: URL, origin: Origin)] {
        [
            (URL(fileURLWithPath: "/Applications"), .other),
            (FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"), .other),
            (URL(fileURLWithPath: "/System/Applications"), .system),
        ]
    }

    /// Parcourt le premier niveau et un niveau de sous-dossier (ex. /Applications/Utilities),
    /// sans descendre dans les bundles (helpers, frameworks). Dédoublonné par nom, trié.
    public static func scan(directories: [(url: URL, origin: Origin)] = defaultDirectories) -> [App] {
        let fm = FileManager.default
        var found: [(app: App, order: Int)] = []

        for (base, defaultOrigin) in directories {
            guard let top = try? fm.contentsOfDirectory(atPath: base.path) else { continue }
            var candidates: [URL] = []
            for name in top.sorted() {
                let url = base.appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    candidates.append(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                          let sub = try? fm.contentsOfDirectory(atPath: url.path) {
                    candidates += sub.sorted().filter { $0.hasSuffix(".app") }.map { url.appendingPathComponent($0) }
                }
            }
            for appURL in candidates {
                guard let app = readApp(at: appURL, defaultOrigin: defaultOrigin) else { continue }
                found.append((app, found.count))
            }
        }

        // Une même app peut figurer dans plusieurs dossiers : on garde la première rencontrée.
        let sorted = found.sorted {
            let l = $0.app.name.lowercased(), r = $1.app.name.lowercased()
            return l != r ? l < r : $0.order < $1.order
        }
        var seen = Set<String>()
        return sorted.compactMap { seen.insert($0.app.name.lowercased()).inserted ? $0.app : nil }
    }

    static func readApp(at url: URL, defaultOrigin: Origin) -> App? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        func string(_ key: String) -> String? {
            (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let name = string("CFBundleDisplayName") ?? string("CFBundleName")
            ?? url.deletingPathExtension().lastPathComponent
        let version = string("CFBundleShortVersionString") ?? string("CFBundleVersion") ?? "?"
        let receipt = url.appendingPathComponent("Contents/_MASReceipt/receipt")
        let origin: Origin = FileManager.default.fileExists(atPath: receipt.path) ? .appStore : defaultOrigin
        return App(name: name, version: version, origin: origin)
    }

    /// Rapport texte, dans la langue de l'interface.
    public static func report(_ apps: [App], date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.language.locale
        formatter.dateFormat = tr("dd/MM/yyyy 'à' HH:mm:ss", "yyyy-MM-dd 'at' HH:mm:ss")

        let separator = String(repeating: "─", count: 72)
        let header = "  " + pad(tr("Nom", "Name"), 50) + "  Version"

        func section(_ title: String, _ origin: Origin) -> [String] {
            let list = apps.filter { $0.origin == origin }
            return ["\(title) (\(list.count) application(s))", separator, header, separator]
                + list.map { "  " + pad(String($0.name.prefix(48)), 50) + "  " + String($0.version.prefix(18)) }
                + [""]
        }

        let lines = [
            tr("Généré le \(formatter.string(from: date))", "Generated on \(formatter.string(from: date))"),
            tr("Sources : ", "Sources: ") + "/Applications, ~/Applications, /System/Applications",
            "",
        ]
            + section("APP STORE", .appStore)
            + section(tr("AUTRES", "OTHER"), .other)
            + section(tr("SYSTÈME APPLE", "APPLE SYSTEM"), .system)
            + [separator, tr("Total : ", "Total: ") + "\(apps.count) application(s)"]
        return lines.joined(separator: "\n")
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
}
