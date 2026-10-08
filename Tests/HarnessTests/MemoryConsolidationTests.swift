import Foundation
import FoundationModels
import Testing
@testable import Harness

struct ScriptedPlanner: ConsolidationPlanner {
    let plan: ConsolidationPlan
    func plan(index: String, candidates: [String]) async throws -> ConsolidationPlan { plan }
}

struct FailingPlanner: ConsolidationPlanner {
    struct Failure: Error {}
    func plan(index: String, candidates: [String]) async throws -> ConsolidationPlan { throw Failure() }
}

@Suite struct MemoryConsolidationTests {
    private func makeDirectory() throws -> MemoryDirectory {
        try MemoryDirectory(root: FileManager.default.temporaryDirectory.appending(path: "harness-consolidate-\(UUID().uuidString)"))
    }

    @Test func gathersCandidatesFromRecentNotesNotAlreadyIndexed() throws {
        let directory = try makeDirectory()
        let now = Date()
        try "- 2026-10-01 Prefers Zed (source: notes/x.md)\n".write(to: directory.indexURL, atomically: true, encoding: .utf8)
        try directory.appendNote("Prefers Zed", date: now)
        try directory.appendNote("Tests live under Tests/HarnessTests", date: now)
        try directory.appendNote("ancient thing", date: Calendar.current.date(byAdding: .day, value: -10, to: now)!)
        let consolidation = MemoryConsolidation(directory: directory, planner: ScriptedPlanner(plan: .init(operations: [])), days: 7)
        let candidates = consolidation.candidates(now: now)
        #expect(candidates.map(\.text) == ["Tests live under Tests/HarnessTests"])
        #expect(candidates.first?.source.hasPrefix("notes/") == true)
    }

    @Test func appliesOperationsKeepsUndoAndWritesDiary() async throws {
        let directory = try makeDirectory()
        let now = Date()
        try "# Index\n- 2026-10-01 Uses SwiftLint before every commit (source: notes/a.md)\n- 2026-10-01 Deploys happen on Fridays (source: notes/a.md)\n".write(to: directory.indexURL, atomically: true, encoding: .utf8)
        try directory.appendNote("Deploys moved to Tuesdays", date: now)
        try directory.appendNote("Ran the tests once", date: now)
        try directory.appendNote("The eval tasks live in evals/tasks", date: now)
        let plan = ConsolidationPlan(operations: [
            .init(kind: "supersede", candidate: 1, text: "Deploys happen on Tuesdays", replaces: "- 2026-10-01 Deploys happen on Fridays (source: notes/a.md)"),
            .init(kind: "drop", candidate: 2, text: nil, replaces: nil),
            .init(kind: "add", candidate: 3, text: "Eval tasks live in evals/tasks", replaces: nil),
        ])
        let result = try await MemoryConsolidation(directory: directory, planner: ScriptedPlanner(plan: plan)).run(now: now)
        #expect(result == .init(candidates: 3, added: 1, merged: 0, superseded: 1, dropped: 1, rejected: nil))

        let index = try String(contentsOf: directory.indexURL, encoding: .utf8)
        #expect(index.contains("Deploys happen on Tuesdays") && !index.contains("Fridays"))
        #expect(index.contains("Uses SwiftLint"))
        #expect(index.hasSuffix("Eval tasks live in evals/tasks (source: notes/\(MemoryDirectory.dayFormatter.string(from: now)).md)\n"))
        #expect(index.hasPrefix("# Index\n"))

        let archive = try FileManager.default.contentsOfDirectory(atPath: directory.root.appending(path: "archive").path)
        #expect(archive.count == 1 && archive[0].hasPrefix("MEMORY-"))
        #expect(try String(contentsOf: directory.root.appending(path: "archive/\(archive[0])"), encoding: .utf8).contains("Fridays"), "the undo copy keeps the old line")
        let diary = try String(contentsOf: directory.root.appending(path: "consolidation.md"), encoding: .utf8)
        #expect(diary.contains("3 candidates, 1 added, 0 merged, 1 superseded, 1 dropped"))
    }

    @Test func rejectsRewritesThatRemoveTooMuchAndAppendsInstead() async throws {
        let directory = try makeDirectory()
        let now = Date()
        try "- 2026-10-01 A (source: s)\n- 2026-10-01 B (source: s)\n".write(to: directory.indexURL, atomically: true, encoding: .utf8)
        try directory.appendNote("replace A and B with one line", date: now)
        try directory.appendNote("brand new", date: now)
        // Merging two existing lines into one removes half the entries, over the quarter allowed.
        let plan = ConsolidationPlan(operations: [
            .init(kind: "merge", candidate: 1, text: "A and B together", replaces: "- 2026-10-01 A (source: s)"),
            .init(kind: "merge", candidate: 1, text: "A and B together", replaces: "- 2026-10-01 B (source: s)"),
            .init(kind: "add", candidate: 2, text: "brand new", replaces: nil),
        ])
        var limited = directory
        _ = limited
        let result = try await MemoryConsolidation(directory: directory, planner: ScriptedPlanner(plan: plan), maximumRemovedShare: 0.0).run(now: now)
        #expect(result.rejected != nil)
        #expect(result.added == 1 && result.merged == 0)
        let index = try String(contentsOf: directory.indexURL, encoding: .utf8)
        #expect(index.contains("A (source: s)") && index.contains("B (source: s)") && index.contains("brand new"))
    }

    @Test func plannerFailureLeavesTheIndexAlone() async throws {
        let directory = try makeDirectory()
        try "- keep me\n".write(to: directory.indexURL, atomically: true, encoding: .utf8)
        try directory.appendNote("something")
        await #expect(throws: FailingPlanner.Failure.self) {
            try await MemoryConsolidation(directory: directory, planner: FailingPlanner()).run()
        }
        #expect(try String(contentsOf: directory.indexURL, encoding: .utf8) == "- keep me\n")
    }

    @Test func runsAsAScheduledJob() async throws {
        let directory = try makeDirectory()
        try directory.appendNote("A durable fact about the project")
        let store = try JobStore(root: FileManager.default.temporaryDirectory.appending(path: "harness-jobs-\(UUID().uuidString)"))
        let plan = ConsolidationPlan(operations: [.init(kind: "add", candidate: 1, text: "A durable fact about the project", replaces: nil)])
        let runner = CompositeJobRunner(
            runners: ["memory-consolidation": MemoryConsolidationRunner(consolidation: MemoryConsolidation(directory: directory, planner: ScriptedPlanner(plan: plan)))],
            fallback: ScriptedRunner([])
        )
        let scheduler = Scheduler(store: store, runner: runner, delivery: InboxDelivery(store: store))
        try await scheduler.add(Job.memoryConsolidation(cron: "0 3 * * *", timeZone: TimeZone(identifier: "UTC")!))
        let run = try #require(await scheduler.runNow("memory-consolidation"))
        #expect(run.status == .ok && run.outcome == .done)
        #expect(run.summary?.contains("1 added") == true)
        #expect(try String(contentsOf: directory.indexURL, encoding: .utf8).contains("A durable fact"))
        let again = try #require(await scheduler.runNow("memory-consolidation"))
        #expect(again.outcome == .noChange, "already-indexed notes are not candidates")
    }
}
