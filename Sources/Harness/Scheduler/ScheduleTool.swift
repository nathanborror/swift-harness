import Foundation
import FoundationModels

/// Lets the model create, list, run, and remove jobs.
///
/// Inside a scheduled run the tool is restricted to the run's own job: it can
/// report status or remove itself, and cannot create other schedules.
public struct ScheduleTool: AnnotatedTool {
    @Generable(description: "Manage scheduled jobs.")
    public struct Arguments {
        @Guide(description: "add, list, remove, or run", .anyOf(["add", "list", "remove", "run"]))
        public var action: String
        @Guide(description: "For add: a short job name")
        public var name: String?
        @Guide(description: "For add: the prompt the job runs. Point at a runbook file rather than restating it.")
        public var prompt: String?
        @Guide(description: "For add: an interval in minutes, for a repeating job")
        public var everyMinutes: Int?
        @Guide(description: "For add: a five-field cron expression in the person's time zone, instead of an interval")
        public var cron: String?
        @Guide(description: "For add: an ISO 8601 time for a one-time job, instead of an interval")
        public var at: String?
        @Guide(description: "For remove or run: the job id")
        public var jobID: String?
    }

    public let name = "schedule"
    public let description: String
    public let annotations: ToolAnnotations = .mutating
    let scheduler: Scheduler
    let timeZone: TimeZone
    /// The job this tool is running inside, if any. Restricts the tool to that job.
    let currentJobID: String?

    public init(scheduler: Scheduler, timeZone: TimeZone = .current, currentJobID: String? = nil) {
        self.scheduler = scheduler
        self.timeZone = timeZone
        self.currentJobID = currentJobID
        self.description = currentJobID == nil
            ? "Creates, lists, runs, and removes scheduled jobs. Never use shell sleep or polling as a timer; schedule a job instead. Confirm the person's time zone before adding a cron job. Times are in \(timeZone.identifier). A new job runs once immediately as a test."
            : "Reports on or removes the job this run belongs to. Scheduled runs cannot create other jobs."
    }

    public func call(arguments: Arguments) async throws -> String {
        switch arguments.action {
        case "list":
            let jobs = await scheduler.store.all.filter { currentJobID == nil || $0.id == currentJobID }
            guard !jobs.isEmpty else { return "No jobs." }
            let formatter = ISO8601DateFormatter()
            return jobs.map { job in
                "\(job.id)  \(job.name)  \(job.enabled ? "enabled" : "disabled")  next: \(job.state.nextRun.map(formatter.string) ?? "-")  last: \(job.state.lastOutcome?.rawValue ?? "-")"
            }.joined(separator: "\n")
        case "remove":
            guard let id = arguments.jobID else { return "jobID is required." }
            if let currentJobID, id != currentJobID { return "A scheduled run may only remove its own job." }
            try await scheduler.store.remove(id)
            return "Removed job \(id)."
        case "run":
            guard let id = arguments.jobID else { return "jobID is required." }
            if currentJobID != nil { return "A scheduled run cannot start other jobs." }
            guard let run = await scheduler.runNow(id) else { return "No job \(id)." }
            return "Ran \(run.jobName): \(run.status.rawValue) \(run.outcome?.rawValue ?? "") \(run.summary ?? run.skipReason ?? "")"
        case "add":
            if currentJobID != nil { return "A scheduled run cannot create jobs." }
            guard let name = arguments.name, let prompt = arguments.prompt else { return "name and prompt are required." }
            let schedule: JobSchedule
            if let minutes = arguments.everyMinutes {
                schedule = .every(TimeInterval(max(minutes, 1) * 60))
            } else if let cron = arguments.cron {
                schedule = .cron(try CronExpression(cron), timeZone: timeZone.identifier)
            } else if let at = arguments.at, let date = ISO8601DateFormatter().date(from: at) {
                schedule = .at(date)
            } else {
                return "Give everyMinutes, cron, or an ISO 8601 time in at."
            }
            let job = Job(name: name, schedule: schedule, prompt: prompt, createdBy: .agent)
            try await scheduler.add(job)
            let test = await scheduler.runNow(job.id)
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = timeZone
            let next = await scheduler.store.job(job.id)?.state.nextRun
            var text = "Added job \(job.id) \"\(name)\". Next run: \(next.map(formatter.string) ?? "-") (\(timeZone.identifier)). Agent-created jobs expire after 7 days unless renewed."
            if let test { text += "\nTest run: \(test.status.rawValue) \(test.outcome?.rawValue ?? "") \(test.summary ?? test.error ?? test.skipReason ?? "")" }
            return text
        default:
            return "Unknown action \(arguments.action)."
        }
    }
}
