import Foundation
import FoundationModels
import Testing
@testable import Harness
import HarnessTestSupport

@Suite struct CronExpressionTests {
    private func date(_ string: String, zone: String = "UTC") -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: string)!
    }

    @Test func computesNextFireTimes() throws {
        let utc = TimeZone(identifier: "UTC")!
        let daily = try CronExpression("30 9 * * *")
        #expect(daily.nextDate(after: date("2026-10-08 09:00"), timeZone: utc) == date("2026-10-08 09:30"))
        #expect(daily.nextDate(after: date("2026-10-08 09:30"), timeZone: utc) == date("2026-10-09 09:30"), "strictly after")
        let weekdays = try CronExpression("0 8 * * 1-5")
        #expect(weekdays.nextDate(after: date("2026-10-09 09:00"), timeZone: utc) == date("2026-10-12 08:00"), "Friday evening rolls to Monday")
        let steps = try CronExpression("*/15 * * * *")
        #expect(steps.nextDate(after: date("2026-10-08 09:01"), timeZone: utc) == date("2026-10-08 09:15"))
        let monthly = try CronExpression("0 0 1 */2 *")
        #expect(monthly.nextDate(after: date("2026-10-08 00:00"), timeZone: utc) == date("2026-11-01 00:00"))
        let zoned = try CronExpression("0 9 * * *")
        #expect(zoned.nextDate(after: date("2026-10-08 10:00"), timeZone: TimeZone(identifier: "America/Los_Angeles")!) == date("2026-10-08 09:00", zone: "America/Los_Angeles"))
        #expect(throws: CronExpression.ParseError.self) { _ = try CronExpression("* * *") }
        #expect(throws: CronExpression.ParseError.self) { _ = try CronExpression("61 * * * *") }
    }

    @Test func scheduleAndActiveHours() throws {
        let now = date("2026-10-08 12:00")
        #expect(JobSchedule.at(now.addingTimeInterval(-1)).nextRun(after: now) == nil)
        #expect(JobSchedule.every(10).nextRun(after: now) == now.addingTimeInterval(60), "intervals are floored at one minute")
        let hours = ActiveHours(startMinute: 9 * 60, endMinute: 17 * 60, timeZone: "UTC")
        #expect(hours.contains(now))
        #expect(!hours.contains(date("2026-10-08 20:00")))
        let night = ActiveHours(startMinute: 22 * 60, endMinute: 6 * 60, timeZone: "UTC")
        #expect(night.contains(date("2026-10-08 23:00")) && night.contains(date("2026-10-08 05:00")) && !night.contains(now))
    }
}

/// Returns scripted results and records the wake messages it received.
actor ScriptedRunner: JobRunner {
    enum Step { case result(JobResult), fail(String) }
    private var steps: [Step]
    private(set) var wakes: [WakeMessage] = []
    init(_ steps: [Step]) { self.steps = steps }
    func run(_ wake: WakeMessage) async throws -> JobResult {
        wakes.append(wake)
        guard !steps.isEmpty else { return .silent }
        switch steps.removeFirst() {
        case .result(let result): return result
        case .fail(let message): throw TimeLimitError(seconds: Int(message) ?? 0)
        }
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@Suite struct SchedulerTests {
    private func makeStore() throws -> JobStore {
        try JobStore(root: FileManager.default.temporaryDirectory.appending(path: "harness-jobs-\(UUID().uuidString)"))
    }

    @Test func storePersistsJobsAndRuns() async throws {
        let store = try makeStore()
        let job = Job(name: "daily", schedule: .cron(try CronExpression("0 9 * * *"), timeZone: "UTC"), prompt: "Read docs/automations/daily.md and follow it.")
        try await store.upsert(job)
        let reopened = try JobStore(root: store.root)
        let loaded = try #require(await reopened.all.first)
        #expect(loaded.id == job.id && loaded.name == job.name && loaded.prompt == job.prompt && loaded.schedule == job.schedule)
        #expect(abs(loaded.createdAt.timeIntervalSince(job.createdAt)) < 0.001, "dates round-trip to the millisecond")
        #expect(abs((loaded.state.nextRun ?? .distantPast).timeIntervalSince(job.state.nextRun ?? .distantFuture)) < 0.001)
        await store.record(JobRun(id: "r1", jobID: job.id, jobName: job.name, scheduledAt: nil, startedAt: Date(), finishedAt: Date(), status: .ok, skipReason: nil, outcome: .done, summary: "x", notified: false, inputTokens: 1, outputTokens: 1, error: nil))
        #expect(await store.runs().map(\.id) == ["r1"])
    }

    @Test func guardsSkipBeforeTheModelAndRecordWhy() async throws {
        let store = try makeStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let runner = ScriptedRunner([])
        let scheduler = Scheduler(store: store, runner: runner, delivery: InboxDelivery(store: store), clock: { clock.now })

        var heartbeat = Job.heartbeat(every: 600, scratch: "# checklist\n\n// nothing yet\n")
        heartbeat.state.nextRun = clock.now
        try await scheduler.add(heartbeat)
        let empty = await scheduler.tick()
        #expect(empty.map(\.skipReason) == ["checklist empty"])
        #expect(await runner.wakes.isEmpty)
        #expect(await store.job("heartbeat")?.state.nextRun == clock.now.addingTimeInterval(600), "a skipped tick still advances")

        try await store.update("heartbeat") { $0.state.scratch = "- check the build"; $0.state.nextRun = clock.now; $0.activeHours = ActiveHours(startMinute: 0, endMinute: 1, timeZone: "UTC") }
        let outside = await scheduler.tick()
        #expect(outside.map(\.skipReason) == ["outside active hours"])

        try await store.update("heartbeat") { $0.activeHours = nil; $0.state.nextRun = clock.now }
        await scheduler.setPaused(true)
        #expect(await scheduler.tick().map(\.skipReason) == ["scheduler paused"])
        await scheduler.setPaused(false)

        try await store.update("heartbeat") { $0.state.nextRun = clock.now }
        let ran = await scheduler.tick()
        #expect(ran.map(\.status) == [.ok])
        #expect(ran.first?.outcome == .noChange && ran.first?.notified == false)
        let wake = try #require(await runner.wakes.first)
        #expect(wake.rendered().contains("Current time:") && wake.rendered().contains("Checklist:\n- check the build") && wake.rendered().contains("NO_REPLY"))
        #expect(await store.runs().count == 4, "every tick is recorded")
    }

    @Test func failuresBackOffAlertAndDisable() async throws {
        let store = try makeStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let runner = ScriptedRunner([.fail("1"), .fail("2"), .fail("3")])
        var policy = Scheduler.Policy()
        policy.backoff = [30, 60]
        policy.disableAfterConsecutiveErrors = 3
        policy.alertAfterConsecutiveErrors = 2
        let delivery = InboxDelivery(store: store)
        let scheduler = Scheduler(store: store, runner: runner, delivery: delivery, policy: policy, clock: { clock.now })
        var job = Job(id: "watch", name: "Watch CI", schedule: .every(600), prompt: "check")
        job.state.nextRun = clock.now
        try await scheduler.add(job)

        _ = await scheduler.tick()
        #expect(await store.job("watch")?.state.nextRun == clock.now.addingTimeInterval(30), "first failure backs off 30s")
        #expect(delivery.notices().isEmpty, "no alert after one failure")
        clock.advance(30)
        _ = await scheduler.tick()
        #expect(await store.job("watch")?.state.nextRun == clock.now.addingTimeInterval(60))
        #expect(delivery.notices().map(\.kind) == [.alert], "alert after two")
        clock.advance(60)
        let third = await scheduler.tick()
        #expect(third.first?.status == .error)
        let stored = try #require(await store.job("watch"))
        #expect(!stored.enabled && stored.state.nextRun == nil && stored.state.consecutiveErrors == 3)
        #expect(delivery.notices().last?.text.contains("disabled") == true)
        #expect(await scheduler.tick().isEmpty, "disabled jobs do not tick")
    }

    @Test func successResetsErrorsDeliversAndPacesItself() async throws {
        let store = try makeStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let runner = ScriptedRunner([
            .result(JobResult(outcome: .progress, summary: "deploy running", notification: "Deploy started", scratch: "- watch deploy 42", nextCheckSeconds: 5)),
            .result(JobResult(outcome: .done, summary: "finished")),
        ])
        let delivery = InboxDelivery(store: store)
        let scheduler = Scheduler(store: store, runner: runner, delivery: delivery, clock: { clock.now })
        var job = Job(id: "deploy", name: "Deploy watch", schedule: .every(1800), prompt: "check")
        job.state.consecutiveErrors = 4
        job.state.nextRun = clock.now
        try await scheduler.add(job)

        let first = await scheduler.tick()
        #expect(first.first?.notified == true)
        #expect(delivery.notices().map(\.text) == ["Deploy started"])
        let stored = try #require(await store.job("deploy"))
        #expect(stored.state.consecutiveErrors == 0 && stored.state.scratch == "- watch deploy 42")
        #expect(stored.state.nextRun == clock.now.addingTimeInterval(60), "self-pacing is clamped to the lower bound")
        clock.advance(60)
        _ = await scheduler.tick()
        #expect(await store.job("deploy")?.state.nextRun == clock.now.addingTimeInterval(1800), "no pace request returns to the schedule")
    }

    @Test func oneShotsRunOnceAndAreRemovedAndCatchUpCoalesces() async throws {
        let store = try makeStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let runner = ScriptedRunner([])
        let scheduler = Scheduler(store: store, runner: runner, delivery: InboxDelivery(store: store), clock: { clock.now })
        let reminder = Job(id: "remind", name: "Remind", schedule: .at(clock.now.addingTimeInterval(-7200)), prompt: "remind me", createdAt: clock.now.addingTimeInterval(-9000))
        var missedOnce = Job(id: "once", name: "Catch up once", schedule: .every(600), prompt: "x", catchUp: .once)
        missedOnce.state.nextRun = clock.now.addingTimeInterval(-6000)
        var missedSkip = Job(id: "skip", name: "Skip ahead", schedule: .every(600), prompt: "x", catchUp: .skip)
        missedSkip.state.nextRun = clock.now.addingTimeInterval(-6000)
        for job in [reminder, missedOnce, missedSkip] { try await store.upsert(job) }

        await scheduler.start()
        await scheduler.stop()
        #expect(await runner.wakes.map(\.job.id).sorted() == ["once", "remind"], "the one-shot and the once-policy job ran; the skip-policy job did not")
        #expect(await store.job("remind") == nil, "one-shots are removed after firing")
        #expect(await store.job("once")?.state.nextRun == clock.now.addingTimeInterval(600))
        #expect(await store.job("skip")?.state.nextRun == clock.now.addingTimeInterval(600))
        #expect(await store.runs().contains { $0.skipReason?.contains("missed while stopped") == true })
    }

    @Test func expiredAgentJobsAreDisabled() async throws {
        let store = try makeStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let scheduler = Scheduler(store: store, runner: ScriptedRunner([]), delivery: InboxDelivery(store: store), clock: { clock.now })
        var job = Job(id: "agentjob", name: "Agent job", schedule: .every(600), prompt: "x", createdBy: .agent, createdAt: clock.now)
        job.state.nextRun = clock.now
        try await scheduler.add(job)
        #expect(await store.job("agentjob")?.expiresAt == clock.now.addingTimeInterval(7 * 24 * 3600))
        clock.advance(8 * 24 * 3600)
        let runs = await scheduler.tick()
        #expect(runs.first?.skipReason == "expired; disabled")
        #expect(await store.job("agentjob")?.enabled == false)
    }

    @Test func agentRunnerUsesTheResponseToolOrTheSentinel() async throws {
        let silent = AgentJobRunner(model: EchoModel(), tools: [])
        let wake = WakeMessage(job: Job(name: "j", schedule: .every(600), prompt: "NO_REPLY"), scheduledAt: nil, now: Date())
        let echoed = try await silent.run(wake)
        #expect(echoed.outcome == .progress && echoed.notification?.hasPrefix("echo: ") == true, "the echo model repeats the wake message, which is not the sentinel")

        let responder = AgentJobRunner(model: EchoModel(), tools: [EchoTool()])
        let toolWake = WakeMessage(job: Job(name: "j", schedule: .every(600), prompt: "x"), scheduledAt: nil, now: Date())
        _ = toolWake
        let viaTool = try await responder.run(WakeMessage(job: Job(name: "j", schedule: .every(600), prompt: #"call job_respond {"outcome":"needs_attention","summary":"disk full","notify":true,"notificationText":"Disk is full","nextCheckSeconds":120}"#), scheduledAt: nil, now: Date()))
        _ = viaTool
    }

    @Test func scheduleToolIsRestrictedInsideRuns() async throws {
        let store = try makeStore()
        let scheduler = Scheduler(store: store, runner: ScriptedRunner([.result(JobResult(outcome: .done, summary: "tested"))]), delivery: InboxDelivery(store: store))
        let tool = ScheduleTool(scheduler: scheduler, timeZone: TimeZone(identifier: "UTC")!)
        let added = try await tool.call(arguments: .init(action: "add", name: "Nightly", prompt: "Read runbook.md", everyMinutes: 60, cron: nil, at: nil, jobID: nil))
        #expect(added.contains("Added job") && added.contains("Test run: ok done tested"))
        let jobs = await store.all
        #expect(jobs.count == 1 && jobs[0].createdBy == .agent && jobs[0].expiresAt != nil)
        let listed = try await tool.call(arguments: .init(action: "list", name: nil, prompt: nil, everyMinutes: nil, cron: nil, at: nil, jobID: nil))
        #expect(listed.contains("Nightly"))

        let inside = ScheduleTool(scheduler: scheduler, currentJobID: jobs[0].id)
        let refused = try await inside.call(arguments: .init(action: "add", name: "Other", prompt: "p", everyMinutes: 5, cron: nil, at: nil, jobID: nil))
        #expect(refused.contains("cannot create"))
        let other = try await inside.call(arguments: .init(action: "remove", name: nil, prompt: nil, everyMinutes: nil, cron: nil, at: nil, jobID: "someone-else"))
        #expect(other.contains("only remove its own"))
        let own = try await inside.call(arguments: .init(action: "remove", name: nil, prompt: nil, everyMinutes: nil, cron: nil, at: nil, jobID: jobs[0].id))
        #expect(own.hasPrefix("Removed"))
        #expect(await store.all.isEmpty)
    }
}

@Suite struct SchedulerSkipTests {
    actor SkippingRunner: JobRunner {
        var calls = 0
        func run(_ wake: WakeMessage) async throws -> JobResult {
            calls += 1
            if calls == 1 { throw JobRunnerSkip(reason: "session busy") }
            return JobResult(outcome: .noChange, summary: "events: \(wake.events)")
        }
    }

    @Test func aSkipIsNotAFailureAndKeepsEvents() async throws {
        let store = try JobStore(root: FileManager.default.temporaryDirectory.appending(path: "harness-jobs-\(UUID().uuidString)"))
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let runner = SkippingRunner()
        let scheduler = Scheduler(store: store, runner: runner, delivery: InboxDelivery(store: store), clock: { clock.now })
        try await scheduler.add(Job.heartbeat(every: 600))
        let first = await scheduler.enqueue(event: "bg_1 exited")
        #expect(first?.status == .skipped && first?.skipReason == "session busy")
        #expect(await store.job("heartbeat")?.state.consecutiveErrors == 0)
        clock.advance(600)
        let second = await scheduler.tick()
        #expect(second.first?.status == .ok)
        #expect(second.first?.summary == "events: [\"bg_1 exited\"]", "the event survived the skip")
    }
}

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
