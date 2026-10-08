import Foundation

/// When a job runs.
public enum JobSchedule: Sendable, Equatable, Codable {
    /// Once, at a time. Deleted after it fires.
    case at(Date)
    /// On a fixed interval, measured from the previous run.
    case every(TimeInterval)
    /// At cron times in a time zone.
    case cron(CronExpression, timeZone: String)

    public var isRecurring: Bool {
        if case .at = self { return false }
        return true
    }

    /// The next run strictly after `date`.
    public func nextRun(after date: Date) -> Date? {
        switch self {
        case .at(let when): return when > date ? when : nil
        case .every(let interval): return date.addingTimeInterval(max(interval, 60))
        case .cron(let cron, let zone): return cron.nextDate(after: date, timeZone: TimeZone(identifier: zone) ?? .current)
        }
    }

    public var timeZone: TimeZone {
        if case .cron(_, let zone) = self, let timeZone = TimeZone(identifier: zone) { return timeZone }
        return .current
    }
}

/// Hours during which a job may run. Ticks outside the window are skipped.
public struct ActiveHours: Sendable, Equatable, Codable {
    /// Start and end as minutes after midnight. The window may wrap past midnight.
    public var startMinute: Int
    public var endMinute: Int
    public var timeZone: String

    public init(startMinute: Int, endMinute: Int, timeZone: String = TimeZone.current.identifier) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.timeZone = timeZone
    }

    public func contains(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if startMinute <= endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }
}

/// What happens after downtime when a run was missed.
public enum CatchUpPolicy: String, Sendable, Codable {
    /// Run once now, however many intervals were missed.
    case once
    /// Skip to the next future occurrence.
    case skip
}

public enum JobCreator: String, Sendable, Codable {
    case user
    case agent
    case system
}

public enum RunStatus: String, Sendable, Codable {
    case ok
    case error
    case skipped
}

/// How a run ended, in the model's own words through the response tool, or inferred.
public enum JobOutcome: String, Sendable, Codable, CaseIterable {
    case noChange = "no_change"
    case progress
    case done
    case blocked
    case needsAttention = "needs_attention"
    case failed
}

public struct JobLimits: Sendable, Equatable, Codable {
    public var timeoutSeconds: Int
    public var maximumToolCalls: Int

    public init(timeoutSeconds: Int = 600, maximumToolCalls: Int = 50) {
        self.timeoutSeconds = timeoutSeconds
        self.maximumToolCalls = maximumToolCalls
    }
}

public struct JobState: Sendable, Equatable, Codable {
    public var nextRun: Date?
    public var lastRun: Date?
    public var lastStatus: RunStatus?
    public var lastOutcome: JobOutcome?
    public var consecutiveErrors: Int = 0
    public var lastAlert: Date?
    /// A small checklist the job may rewrite each run. Kept out of the transcript.
    public var scratch: String = ""

    public init() {}
}

/// A scheduled unit of work. The prompt is a pointer to a runbook, not the runbook.
public struct Job: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var schedule: JobSchedule
    public var prompt: String
    /// Tool names the run may use. Fixed at creation; a run cannot widen it.
    public var toolNames: [String]?
    /// Skip the model when the scratch checklist has no actionable lines.
    public var skipsWhenScratchEmpty: Bool
    public var activeHours: ActiveHours?
    public var catchUp: CatchUpPolicy
    public var limits: JobLimits
    public var createdBy: JobCreator
    public var createdAt: Date
    /// Agent-created jobs expire so a forgotten loop cannot run forever.
    public var expiresAt: Date?
    public var state: JobState

    public init(
        id: String = UUID().uuidString,
        name: String,
        schedule: JobSchedule,
        prompt: String,
        enabled: Bool = true,
        toolNames: [String]? = nil,
        skipsWhenScratchEmpty: Bool = false,
        activeHours: ActiveHours? = nil,
        catchUp: CatchUpPolicy = .once,
        limits: JobLimits = JobLimits(),
        createdBy: JobCreator = .user,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        scratch: String = ""
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.schedule = schedule
        self.prompt = prompt
        self.toolNames = toolNames
        self.skipsWhenScratchEmpty = skipsWhenScratchEmpty
        self.activeHours = activeHours
        self.catchUp = catchUp
        self.limits = limits
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.state = JobState()
        self.state.scratch = scratch
        self.state.nextRun = schedule.nextRun(after: createdAt)
    }

    /// The heartbeat: a periodic check of a short checklist that usually says nothing.
    public static func heartbeat(every interval: TimeInterval = 30 * 60, scratch: String = "", activeHours: ActiveHours? = nil) -> Job {
        Job(
            id: "heartbeat",
            name: "Heartbeat",
            schedule: .every(interval),
            prompt: Self.heartbeatPrompt,
            skipsWhenScratchEmpty: true,
            activeHours: activeHours,
            catchUp: .skip,
            createdBy: .system,
            scratch: scratch
        )
    }

    public static let heartbeatPrompt = """
        Follow the heartbeat checklist when one is provided. Recurring tasks are scheduled jobs; create or change their schedules with the schedule tool, not the checklist. Do not infer or repeat old tasks from prior conversations. If nothing needs attention, reply NO_REPLY.
        """

    /// True when the scratch holds only blank lines, headings, or comments.
    public var scratchIsEmpty: Bool {
        state.scratch.split(separator: "\n").allSatisfy { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//")
        }
    }
}

/// The record of one tick, whether it reached the model or was skipped.
public struct JobRun: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var jobID: String
    public var jobName: String
    public var scheduledAt: Date?
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: RunStatus
    public var skipReason: String?
    public var outcome: JobOutcome?
    public var summary: String?
    public var notified: Bool
    public var inputTokens: Int
    public var outputTokens: Int
    public var error: String?

    public var duration: TimeInterval { (finishedAt ?? startedAt).timeIntervalSince(startedAt) }
}
