import XCTest
@testable import BackupCore

final class AppInventoryTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        L10n.language = .french
        root = fm.temporaryDirectory.appendingPathComponent("apps-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    func makeApp(_ path: String, info: [String: String], appStore: Bool = false) throws {
        let contents = root.appendingPathComponent(path).appendingPathComponent("Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        if appStore {
            let receipt = contents.appendingPathComponent("_MASReceipt")
            try fm.createDirectory(at: receipt, withIntermediateDirectories: true)
            try Data("r".utf8).write(to: receipt.appendingPathComponent("receipt"))
        }
    }

    func testScanClassifiesDeduplicatesAndSorts() throws {
        try makeApp("Applications/Zed.app", info: ["CFBundleName": "Zed", "CFBundleShortVersionString": "1.2"])
        try makeApp("Applications/Pages.app", info: ["CFBundleDisplayName": "Pages", "CFBundleName": "X"], appStore: true)
        try makeApp("Applications/Utilities/Outil.app", info: ["CFBundleVersion": "42"])
        try makeApp("Applications/Zed.app/Contents/Helpers/Helper.app", info: ["CFBundleName": "Helper"])
        try makeApp("Applications/Cassée.app", info: [:])
        try fm.removeItem(at: root.appendingPathComponent("Applications/Cassée.app/Contents/Info.plist"))
        try makeApp("User/Zed.app", info: ["CFBundleName": "zed", "CFBundleShortVersionString": "0.9"])
        try makeApp("System/Notes.app", info: ["CFBundleName": "Notes", "CFBundleShortVersionString": "4.11"])

        let apps = AppInventory.scan(directories: [
            (root.appendingPathComponent("Applications"), .other),
            (root.appendingPathComponent("User"), .other),
            (root.appendingPathComponent("System"), .system),
        ])

        XCTAssertEqual(apps, [
            .init(name: "Notes", version: "4.11", origin: .system),
            .init(name: "Outil", version: "42", origin: .other),
            .init(name: "Pages", version: "?", origin: .appStore),
            .init(name: "Zed", version: "1.2", origin: .other),
        ])
    }

    func testReportFormat() {
        let apps: [AppInventory.App] = [
            .init(name: "Pages", version: "14.0", origin: .appStore),
            .init(name: String(repeating: "N", count: 60), version: "1", origin: .other),
        ]
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 4
        components.hour = 5; components.minute = 6; components.second = 7
        let date = Calendar.current.date(from: components)!

        let lines = AppInventory.report(apps, date: date).components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Généré le 04/03/2026 à 05:06:07")
        XCTAssertEqual(lines[3], "APP STORE (1 application(s))")
        XCTAssertEqual(lines[7], "  Pages" + String(repeating: " ", count: 45) + "  14.0")
        XCTAssertTrue(lines.contains("  " + String(repeating: "N", count: 48) + "    1"))
        XCTAssertTrue(lines.contains("SYSTÈME APPLE (0 application(s))"))
        XCTAssertEqual(lines.last, "Total : 2 application(s)")
    }

    func testReportInEnglish() {
        L10n.language = .english
        defer { L10n.language = .french }
        let lines = AppInventory.report([.init(name: "Pages", version: "14.0", origin: .appStore)],
                                        date: Date(timeIntervalSince1970: 0)).components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("Generated on "))
        XCTAssertTrue(lines.contains("OTHER (0 application(s))"))
        XCTAssertTrue(lines.contains("APPLE SYSTEM (0 application(s))"))
        XCTAssertEqual(lines.last, "Total: 1 application(s)")
    }
}
