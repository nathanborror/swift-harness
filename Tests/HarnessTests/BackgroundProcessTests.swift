#if os(macOS)
import Foundation
import FoundationModels
import Testing
@testable import Harness

@Suite struct BackgroundProcessTests {
    private func makeTools() throws -> CodingTools {
        let root = FileManager.default.temporaryDirectory.appending(path: "harness-bg-\(UUID().uuidString)")
        let workspace = try Workspace(root: root.appending(path: "ws"))
        return CodingTools(workspace: workspace, backgroundOutputs: root.appending(path: "outputs"))
    }

    @Test func startsChecksAndWakesOnExit() async throws {
        let tools = try makeTools()
        let manager = try #require(tools.context.processes)
        let exited = AsyncStream<BackgroundProcessManager.Record>.makeStream()
        await manager.setExitHandler { record in exited.continuation.yield(record) }

        let started = try await tools.shell.call(arguments: .init(command: "echo begin; sleep 0.3; echo end", workdir: nil, timeoutSeconds: nil, background: true))
        #expect(started.hasPrefix("Started background process bg_"))
        let id = try #require(started.split(separator: " ").first { $0.hasPrefix("bg_") }.map { String($0).trimmingCharacters(in: .punctuationCharacters) })

        let status = try await ProcessStatusTool(manager: manager).call(arguments: .init(id: id))
        #expect(status.contains("is running") || status.contains("exited with code 0"))

        var record: BackgroundProcessManager.Record?
        for await finished in exited.stream { record = finished; break }
        #expect(record?.id == id && record?.status == .exited(code: 0))
        let final = try await ProcessStatusTool(manager: manager).call(arguments: .init(id: id))
        #expect(final.contains("exited with code 0") && final.contains("begin\nend"))
        let names = tools.gated(by: ToolGate(policy: .allowAll)).map(\.name)
        #expect(names.contains("process_status") && names.contains("process_stop"))
    }

    @Test func stopKillsARunningProcess() async throws {
        let tools = try makeTools()
        let manager = try #require(tools.context.processes)
        let record = try await manager.start(command: "sleep 30", directory: tools.context.workspace.root)
        let stopped = try await ProcessStopTool(manager: manager).call(arguments: .init(id: record.id))
        #expect(stopped == "\(record.id) stopped.")
        let after = await manager.waitForExit(record.id, timeout: .seconds(3))
        #expect(after?.status == .stopped)
        #expect(try await ProcessStatusTool(manager: manager).call(arguments: .init(id: "nope")).hasPrefix("No background process"))
    }

    @Test func backgroundIsRefusedWhenNotEnabled() async throws {
        let plain = CodingTools(workspace: try Workspace(root: FileManager.default.temporaryDirectory.appending(path: "harness-bg-\(UUID().uuidString)")))
        let text = try await plain.shell.call(arguments: .init(command: "sleep 1", workdir: nil, timeoutSeconds: nil, background: true))
        #expect(text.hasPrefix("Background commands are not enabled"))
    }
}
#endif

@Suite struct SchedulerWakeTests {
    @Test func eventsWakeTheHeartbeatWithinTheRateLimit() async throws {
        let store = try JobStore(root: FileManager.default.temporaryDirectory.appending(path: "harness-jobs-\(UUID().uuidString)"))
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let runner = ScriptedRunner([])
        var policy = Scheduler.Policy()
        policy.wakeInterval = 30
        policy.wakeFloodLimit = 2
        policy.wakeFloodWindow = 120
        let scheduler = Scheduler(store: store, runner: runner, delivery: InboxDelivery(store: store), policy: policy, clock: { clock.now })
        try await scheduler.add(Job.heartbeat(every: 600))

        let first = await scheduler.enqueue(event: "bg_1 exited with code 0")
        #expect(first?.status == .ok, "an empty checklist does not block a wake that carries an event")
        let wake = try #require(await runner.wakes.last)
        #expect(wake.events == ["bg_1 exited with code 0"])
        #expect(wake.rendered().contains("Events since the last run:\n- bg_1 exited"))

        let second = await scheduler.enqueue(event: "bg_2 exited")
        #expect(second == nil, "within the wake interval the event waits")
        clock.advance(31)
        let third = await scheduler.enqueue(event: "bg_3 exited")
        #expect(third?.status == .ok)
        #expect(await runner.wakes.last?.events == ["bg_2 exited", "bg_3 exited"], "queued events are drained together")

        clock.advance(31)
        #expect(await scheduler.enqueue(event: "bg_4 exited") == nil, "the flood guard caps wakes per window")
        clock.advance(600)
        let tick = await scheduler.tick()
        #expect(tick.first?.status == .ok)
        #expect(await runner.wakes.last?.events == ["bg_4 exited"], "a regular tick drains what the guard held back")
    }
}
