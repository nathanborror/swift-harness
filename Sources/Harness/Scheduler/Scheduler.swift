import Foundation

/// One scheduler in the harness process. The model is never the timer.
///
/// Every tick ends in a run record, whether it reached the model or was skipped
/// at a guard. Recurring jobs back off after errors and are disabled after too
/// many. Missed runs are coalesced to one. A job may pace itself within bounds.
public actor Scheduler {
    public struct Policy: Sendable, Equatable {
        public var backoff: [TimeInterval] = [30, 60, 300, 900, 3600]
        public var disableAfterConsecutiveErrors = 10
        public var alertAfterConsecutiveErrors = 2
        public var alertCooldown: TimeInterval = 3600
        public var selfPaceBounds: ClosedRange<TimeInterval> = 60...3600
        /// Agent-created jobs expire after this long unless renewed.
        public var agentJobLifetime: TimeInterval = 7 * 24 * 3600
        public var maximumCatchUpRuns = 5
        /// The job that event wakes run. The heartbeat by default.
        public var wakeJobID = "heartbeat"
        /// Minimum spacing between event wakes, and a flood guard on top of it.
        public var wakeInterval: TimeInterval = 30
        public var wakeFloodLimit = 5
        public var wakeFloodWindow: TimeInterval = 60

        public init() {}
    }

    public let store: JobStore
    public var policy: Policy
    private let runner: any JobRunner
    private let delivery: any JobDelivery
    private var running: Set<String> = []
    private var timer: Task<Void, Never>?
    public private(set) var isPaused = false
    private let clock: @Sendable () -> Date
    private var pendingEvents: [String] = []
    private var lastWake: Date?
    private var recentWakes: [Date] = []

    public init(store: JobStore, runner: any JobRunner, delivery: any JobDelivery, policy: Policy = Policy(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.runner = runner
        self.delivery = delivery
        self.policy = policy
        self.clock = clock
    }

    // MARK: Lifecycle

    /// Reconciles missed runs, then ticks on a timer until stopped.
    public func start() async {
        await catchUp()
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let delay = await self.delayUntilNextRun()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// A global switch. Paused ticks are recorded as skipped.
    public func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    public func add(_ job: Job) async throws {
        var job = job
        if job.createdBy == .agent, job.expiresAt == nil {
            job.expiresAt = job.createdAt.addingTimeInterval(policy.agentJobLifetime)
        }
        if job.state.nextRun == nil { job.state.nextRun = job.schedule.nextRun(after: clock()) }
        try await store.upsert(job)
    }

    /// Queues a system event for the next run of the wake job. With `wake`, the
    /// job runs now, subject to the wake rate limit; a limited wake is dropped
    /// and the event waits for the next tick. Returns the run when one happened.
    @discardableResult
    public func enqueue(event: String, wake: Bool = true) async -> JobRun? {
        pendingEvents.append(event)
        guard wake else { return nil }
        let now = clock()
        recentWakes = recentWakes.filter { now.timeIntervalSince($0) < policy.wakeFloodWindow }
        if let lastWake, now.timeIntervalSince(lastWake) < policy.wakeInterval { return nil }
        if recentWakes.count >= policy.wakeFloodLimit { return nil }
        guard let job = await store.job(policy.wakeJobID), job.enabled, !running.contains(job.id) else { return nil }
        lastWake = now
        recentWakes.append(now)
        return await execute(job, scheduledAt: nil, manual: true, now: now)
    }

    /// Runs a job now regardless of its schedule, as a visible test or on request.
    @discardableResult
    public func runNow(_ id: String) async -> JobRun? {
        guard let job = await store.job(id) else { return nil }
        return await execute(job, scheduledAt: nil, manual: true)
    }

    // MARK: Ticking

    func delayUntilNextRun() async -> TimeInterval {
        let now = clock()
        let next = await store.all.filter(\.enabled).compactMap(\.state.nextRun).min()
        guard let next else { return 60 }
        return min(max(next.timeIntervalSince(now), 1), 3600)
    }

    /// Runs every due job. Returns the records of ticks that happened.
    @discardableResult
    public func tick(now: Date? = nil) async -> [JobRun] {
        let now = now ?? clock()
        var runs: [JobRun] = []
        for job in await store.all where job.enabled {
            guard let due = job.state.nextRun, due <= now else { continue }
            if let run = await execute(job, scheduledAt: due, manual: false, now: now) { runs.append(run) }
        }
        return runs
    }

    /// After downtime: one-shots always run, recurring jobs run once or skip ahead.
    func catchUp() async {
        let now = clock()
        var immediate = 0
        for job in await store.all where job.enabled {
            guard let due = job.state.nextRun, due < now else { continue }
            if job.schedule.isRecurring, job.catchUp == .skip || immediate >= policy.maximumCatchUpRuns {
                try? await store.update(job.id) { $0.state.nextRun = $0.schedule.nextRun(after: now) }
                await store.record(JobRun(id: UUID().uuidString, jobID: job.id, jobName: job.name, scheduledAt: due, startedAt: now, finishedAt: now, status: .skipped, skipReason: "missed while stopped; skipped to next occurrence", outcome: nil, summary: nil, notified: false, inputTokens: 0, outputTokens: 0, error: nil))
            } else {
                immediate += 1
                _ = await execute(job, scheduledAt: due, manual: false, now: now)
            }
        }
    }

    // MARK: One run

    func execute(_ job: Job, scheduledAt: Date?, manual: Bool, now: Date? = nil) async -> JobRun? {
        let now = now ?? clock()
        var run = JobRun(id: UUID().uuidString, jobID: job.id, jobName: job.name, scheduledAt: scheduledAt, startedAt: now, finishedAt: nil, status: .skipped, skipReason: nil, outcome: nil, summary: nil, notified: false, inputTokens: 0, outputTokens: 0, error: nil)

        func skip(_ reason: String, advance: Bool = true) async -> JobRun {
            run.skipReason = reason
            run.finishedAt = now
            if advance, !manual { try? await store.update(job.id) { $0.state.nextRun = $0.schedule.nextRun(after: now) } }
            await store.record(run)
            return run
        }

        if let expiresAt = job.expiresAt, expiresAt <= now {
            try? await store.update(job.id) { $0.enabled = false }
            return await skip("expired; disabled", advance: false)
        }
        if isPaused, !manual { return await skip("scheduler paused") }
        if let hours = job.activeHours, !hours.contains(now), !manual { return await skip("outside active hours") }
        if running.contains(job.id) { return await skip("previous run still in progress", advance: false) }
        let events = job.id == policy.wakeJobID ? pendingEvents : []
        if job.skipsWhenScratchEmpty, job.scratchIsEmpty, events.isEmpty { return await skip("checklist empty") }

        running.insert(job.id)
        defer { running.remove(job.id) }
        if !events.isEmpty { pendingEvents.removeAll() }
        let wake = WakeMessage(job: job, scheduledAt: scheduledAt, now: now, events: events)
        do {
            let result = try await runner.run(wake)
            run.status = result.outcome == .failed ? .error : .ok
            run.outcome = result.outcome
            run.summary = result.summary
            run.inputTokens = result.inputTokens
            run.outputTokens = result.outputTokens
            if let text = result.notification {
                await delivery.deliver(JobNotice(jobID: job.id, jobName: job.name, kind: .result, text: text))
                run.notified = true
            }
            run.finishedAt = clock()
            if result.outcome == .failed {
                await recordFailure(job, run: &run, reason: result.summary)
            } else {
                await recordSuccess(job, result: result, now: run.finishedAt ?? now, manual: manual)
            }
        } catch {
            run.status = .error
            run.outcome = .failed
            run.error = error.localizedDescription
            run.finishedAt = clock()
            await recordFailure(job, run: &run, reason: error.localizedDescription)
        }
        await store.record(run)
        return run
    }

    private func recordSuccess(_ job: Job, result: JobResult, now: Date, manual: Bool) async {
        let policy = self.policy
        try? await store.update(job.id) { stored in
            stored.state.lastRun = now
            stored.state.lastStatus = .ok
            stored.state.lastOutcome = result.outcome
            stored.state.consecutiveErrors = 0
            if let scratch = result.scratch { stored.state.scratch = scratch }
            if !stored.schedule.isRecurring {
                stored.enabled = false
                stored.state.nextRun = nil
            } else if manual {
                // A manual run does not move the schedule.
            } else if let pace = result.nextCheckSeconds {
                let clamped = min(max(TimeInterval(pace), policy.selfPaceBounds.lowerBound), policy.selfPaceBounds.upperBound)
                stored.state.nextRun = now.addingTimeInterval(clamped)
            } else {
                stored.state.nextRun = stored.schedule.nextRun(after: now)
            }
        }
        if !job.schedule.isRecurring {
            try? await store.remove(job.id)
        }
    }

    private func recordFailure(_ job: Job, run: inout JobRun, reason: String) async {
        let now = run.finishedAt ?? clock()
        let policy = self.policy
        var errors = job.state.consecutiveErrors + 1
        var shouldAlert = false
        var disabled = false
        try? await store.update(job.id) { stored in
            stored.state.lastRun = now
            stored.state.lastStatus = .error
            stored.state.lastOutcome = .failed
            stored.state.consecutiveErrors += 1
            errors = stored.state.consecutiveErrors
            if !stored.schedule.isRecurring {
                stored.enabled = false
                stored.state.nextRun = nil
                disabled = true
            } else if errors >= policy.disableAfterConsecutiveErrors {
                stored.enabled = false
                stored.state.nextRun = nil
                disabled = true
            } else {
                let delay = policy.backoff[min(errors - 1, policy.backoff.count - 1)]
                stored.state.nextRun = now.addingTimeInterval(delay)
            }
            let cooledDown = stored.state.lastAlert.map { now.timeIntervalSince($0) >= policy.alertCooldown } ?? true
            if errors >= policy.alertAfterConsecutiveErrors, cooledDown || disabled {
                shouldAlert = true
                stored.state.lastAlert = now
            }
        }
        if shouldAlert {
            let text = disabled
                ? "Job \"\(job.name)\" was disabled after \(errors) consecutive failures. Last error: \(reason)"
                : "Job \"\(job.name)\" has failed \(errors) times in a row. Last error: \(reason)"
            await delivery.deliver(JobNotice(jobID: job.id, jobName: job.name, kind: .alert, text: text))
            run.notified = true
        }
    }
}
