import XCTest
@testable import BackupCore

final class ICloudChainTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func file(_ path: String, _ size: Int64, _ seconds: TimeInterval = 0) -> ArchiveItem {
        ArchiveItem(path: path, kind: .file, size: size, modificationDate: t0.addingTimeInterval(seconds))
    }

    private func dir(_ path: String, _ seconds: TimeInterval = 0) -> ArchiveItem {
        ArchiveItem(path: path, kind: .directory, size: 0, modificationDate: t0.addingTimeInterval(seconds))
    }

    // MARK: Comparaison

    func testDiffFromEmptyStateTakesEverything() {
        let current = [dir("d"), file("d/a", 10), file("b", 5)]
        let diff = ChainDiff.compute(previous: ChainState(), current: current)
        XCTAssertEqual(diff.changed.map(\.path), ["b", "d", "d/a"])
        XCTAssertEqual(diff.deleted, [])
    }

    func testDiffDetectsAddedModifiedAndDeleted() {
        let previous = ChainState(items: [dir("d"), file("d/a", 10), file("b", 5), file("c", 7), file("old", 1)])
        let current = [
            dir("d", 3600),          // date d'un dossier modifiée : ignorée
            file("d/a", 11),         // taille modifiée
            file("b", 5, 1),         // date à 1 s près : inchangé
            file("c", 7, 60),        // date modifiée
            file("new", 2),          // nouveau
        ]
        let diff = ChainDiff.compute(previous: previous, current: current)
        XCTAssertEqual(diff.changed.map(\.path), ["c", "d/a", "new"])
        XCTAssertEqual(diff.deleted, ["old"])
    }

    func testDiffDetectsTypeChange() {
        let previous = ChainState(items: [dir("x"), file("x/in", 1)])
        let diff = ChainDiff.compute(previous: previous, current: [file("x", 3)])
        XCTAssertEqual(diff.changed.map(\.path), ["x"])
        XCTAssertEqual(diff.deleted, ["x/in"])
    }

    func testStateAppliesDeltasInOrder() {
        var state = ChainState()
        state.apply(ChainDelta(step: 0, kind: .complete, date: t0, changed: [file("a", 1), file("b", 2)], deleted: []))
        state.apply(ChainDelta(step: 1, kind: .increment, date: t0, changed: [file("a", 9)], deleted: ["b"]))
        XCTAssertEqual(state.items.keys.sorted(), ["a"])
        XCTAssertEqual(state.items["a"]?.size, 9)
        XCTAssertEqual(state.totalSize, 9)
    }

    // MARK: Plan de restauration

    func testRestorePlanTakesLatestVersionFromItsStep() {
        let deltas = [
            ChainDelta(step: 0, kind: .complete, date: t0, changed: [file("a", 1), file("b", 2), file("c", 3)], deleted: []),
            ChainDelta(step: 1, kind: .increment, date: t0, changed: [file("a", 10)], deleted: ["c"]),
            ChainDelta(step: 2, kind: .increment, date: t0, changed: [file("d", 4)], deleted: []),
        ]
        let latest = RestorePlan(deltas: deltas)
        XCTAssertEqual(latest.items.keys.sorted(), ["a", "b", "d"])
        XCTAssertEqual(latest.stepOf["a"], 1)
        XCTAssertEqual(latest.paths(fromStep: 0), ["b"])
        XCTAssertEqual(latest.neededSteps, [0, 1, 2])
        XCTAssertEqual(latest.totalSize, 16)

        // État à l'étape 0 : la version d'origine de « a », et « c » existe encore.
        let atStart = RestorePlan(deltas: Array(deltas.prefix(1)))
        XCTAssertEqual(atStart.items.keys.sorted(), ["a", "b", "c"])
        XCTAssertEqual(atStart.items["a"]?.size, 1)
        XCTAssertEqual(atStart.neededSteps, [0])
    }

    func testRestorePlanForgetsFileDeletedThenRecreated() {
        let deltas = [
            ChainDelta(step: 0, kind: .complete, date: t0, changed: [file("a", 1)], deleted: []),
            ChainDelta(step: 1, kind: .increment, date: t0, changed: [], deleted: ["a"]),
            ChainDelta(step: 2, kind: .increment, date: t0, changed: [file("a", 5)], deleted: []),
        ]
        let plan = RestorePlan(deltas: deltas)
        XCTAssertEqual(plan.stepOf["a"], 2)
        XCTAssertEqual(plan.neededSteps, [2])
        XCTAssertTrue(RestorePlan(deltas: Array(deltas.prefix(2))).items.isEmpty)
    }

    func testDeltaRoundTripsThroughJSON() throws {
        let delta = ChainDelta(step: 3, kind: .increment, date: t0, changed: [file("é/a", 1), dir("é")], deleted: ["x"])
        let decoded = try JSONDecoder().decode(ChainDelta.self, from: JSONEncoder().encode(delta))
        XCTAssertEqual(decoded, delta)
        XCTAssertEqual(delta.changedFileCount, 1)
        XCTAssertEqual(delta.changedBytes, 1)
    }

    // MARK: Organisation des dossiers

    func testStepNamesRoundTrip() throws {
        let name = ChainLayout.stepFolderName(step: 12, kind: .increment, date: t0)
        XCTAssertEqual(name, "0012-increment-20231114T221320Z")
        let parsed = try XCTUnwrap(ChainLayout.parseStep(name))
        XCTAssertEqual(parsed.number, 12)
        XCTAssertEqual(parsed.kind, .increment)
        XCTAssertEqual(parsed.date, t0)
        XCTAssertNil(ChainLayout.parseStep("12-increment-20231114T221320Z"))
        XCTAssertNil(ChainLayout.parseStep("0001-autre-20231114T221320Z"))
        XCTAssertNil(ChainLayout.parseStep(".DS_Store"))
    }

    func testCommittedStepsStopAtFirstIncompleteOrGap() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("chaine-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Documents")
        let old = source.appendingPathComponent(ChainLayout.chainFolderName(date: t0))
        let chain = source.appendingPathComponent(ChainLayout.chainFolderName(date: t0.addingTimeInterval(86400)))

        func makeStep(_ chain: URL, _ number: Int, _ kind: ChainDelta.Kind, committed: Bool, placeholder: Bool = false) throws {
            let url = chain.appendingPathComponent(ChainLayout.stepFolderName(step: number, kind: kind,
                                                                              date: t0.addingTimeInterval(Double(number))))
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            if committed {
                // Avant macOS 14, un marqueur libéré par iCloud devient « .termine.icloud ».
                let marker = placeholder ? "." + ChainLayout.commitMarker + ".icloud" : ChainLayout.commitMarker
                try Data().write(to: url.appendingPathComponent(marker))
            }
        }
        try makeStep(old, 0, .complete, committed: true)
        try makeStep(chain, 0, .complete, committed: true)
        try makeStep(chain, 1, .increment, committed: true, placeholder: true)
        try makeStep(chain, 2, .increment, committed: false)
        try makeStep(chain, 3, .increment, committed: true)

        XCTAssertEqual(ChainLayout.chains(in: source).map(\.lastPathComponent),
                       [old.lastPathComponent, chain.lastPathComponent])
        XCTAssertEqual(ChainLayout.steps(in: chain).map(\.number), [0, 1, 2, 3])
        XCTAssertEqual(ChainLayout.committedSteps(in: chain).map(\.number), [0, 1])
        let current = try XCTUnwrap(ChainLayout.currentChain(in: source))
        XCTAssertEqual(current.url.lastPathComponent, chain.lastPathComponent)
        XCTAssertEqual(current.steps.count, 2)
    }

    func testChainWithoutCommittedCompleteStepIsIgnored() throws {
        let fm = FileManager.default
        let source = fm.temporaryDirectory.appendingPathComponent("chaine-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: source) }
        let chain = source.appendingPathComponent(ChainLayout.chainFolderName(date: t0))
        try fm.createDirectory(at: chain.appendingPathComponent(ChainLayout.stepFolderName(step: 0, kind: .complete, date: t0)),
                               withIntermediateDirectories: true)
        XCTAssertNil(ChainLayout.currentChain(in: source))
    }
}
