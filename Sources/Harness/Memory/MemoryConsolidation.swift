import Foundation
import FoundationModels

/// One decision about a candidate note line.
@Generable(description: "One consolidation decision.")
public struct ConsolidationOperation: Sendable, Equatable {
    @Guide(description: "add, merge, supersede, or drop", .anyOf(["add", "merge", "supersede", "drop"]))
    public var kind: String
    @Guide(description: "The candidate number this decision is about")
    public var candidate: Int
    @Guide(description: "For add, merge, and supersede: the final one-line entry for the index, general rather than an instance, without a date")
    public var text: String?
    @Guide(description: "For merge and supersede: the exact existing index line being replaced")
    public var replaces: String?
}

@Generable(description: "The consolidation plan: one decision per candidate.")
public struct ConsolidationPlan: Sendable, Equatable {
    public var operations: [ConsolidationOperation]
}

/// Decides what to do with candidate notes. The default asks a model; tests script it.
public protocol ConsolidationPlanner: Sendable {
    func plan(index: String, candidates: [String]) async throws -> ConsolidationPlan
}

public struct ModelConsolidationPlanner: ConsolidationPlanner {
    public let model: any LanguageModel

    public init(model: any LanguageModel) {
        self.model = model
    }

    public func plan(index: String, candidates: [String]) async throws -> ConsolidationPlan {
        let numbered = candidates.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let prompt = """
            You maintain an agent's memory index. Below is the current index and a numbered list of candidate notes from recent sessions. Return one decision per candidate: add it as a new index line, merge it into an existing line, supersede an existing line that is no longer true, or drop it because it is an instance rather than a rule, derivable from the files or tools at hand, transient, or already covered. Write entries as general rules and durable facts, one line each, and keep what is specific such as paths and names.

            <index>
            \(index.isEmpty ? "(empty)" : index)
            </index>

            <candidates>
            \(numbered)
            </candidates>
            """
        let session = LanguageModelSession(model: model, instructions: "You curate a memory index. Be strict: most notes should be dropped or merged.")
        return try await session.respond(to: prompt, generating: ConsolidationPlan.self).content
    }
}

/// Promotes recent notes into `MEMORY.md` under deterministic gates.
///
/// Candidates are note lines from the last few days that are not already in
/// the index. The planner returns operations only; this type writes the
/// entries, rejects a rewrite that drops too much or grows past the cap, keeps
/// the previous index as an undo copy, and appends a diary line for review.
public struct MemoryConsolidation: Sendable {
    public struct Result: Sendable, Equatable {
        public var candidates: Int
        public var added: Int
        public var merged: Int
        public var superseded: Int
        public var dropped: Int
        public var rejected: String?
    }

    public let directory: MemoryDirectory
    public let planner: any ConsolidationPlanner
    /// Notes from this many days back are candidates.
    public let days: Int
    /// A rewrite that removes more than this share of existing entries is rejected.
    public let maximumRemovedShare: Double

    public init(directory: MemoryDirectory, planner: any ConsolidationPlanner, days: Int = 7, maximumRemovedShare: Double = 0.25) {
        self.directory = directory
        self.planner = planner
        self.days = days
        self.maximumRemovedShare = maximumRemovedShare
    }

    public func candidates(now: Date = Date()) -> [(text: String, source: String)] {
        let index = (try? String(contentsOf: directory.indexURL, encoding: .utf8)) ?? ""
        var found: [(String, String)] = []
        for offset in 0..<max(days, 1) {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: now) else { continue }
            let url = directory.noteURL(for: date)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") else { continue }
                var body = String(trimmed.dropFirst(2))
                // Strip the HH:mm stamp appendNote adds.
                if body.count > 6, body[body.index(body.startIndex, offsetBy: 2)] == ":", body[body.index(body.startIndex, offsetBy: 5)] == " " {
                    body = String(body.dropFirst(6))
                }
                guard !body.isEmpty, !index.contains(body) else { continue }
                found.append((body, directory.relativePath(url)))
            }
        }
        return found
    }

    @discardableResult
    public func run(now: Date = Date()) async throws -> Result {
        let candidates = candidates(now: now)
        guard !candidates.isEmpty else {
            return Result(candidates: 0, added: 0, merged: 0, superseded: 0, dropped: 0, rejected: nil)
        }
        let original = (try? String(contentsOf: directory.indexURL, encoding: .utf8)) ?? ""
        let plan = try await planner.plan(index: original, candidates: candidates.map(\.text))

        var lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let entriesBefore = lines.filter { $0.hasPrefix("- ") }.count
        let stamp = MemoryDirectory.dayFormatter.string(from: now)
        var result = Result(candidates: candidates.count, added: 0, merged: 0, superseded: 0, dropped: 0, rejected: nil)
        var additions: [String] = []

        for operation in plan.operations {
            let number = operation.candidate - 1
            guard candidates.indices.contains(number) else { continue }
            let source = candidates[number].source
            switch operation.kind {
            case "add":
                guard let text = operation.text, !text.isEmpty else { continue }
                additions.append("- \(stamp) \(text) (source: \(source))")
                result.added += 1
            case "merge", "supersede":
                guard let text = operation.text, !text.isEmpty, let replaces = operation.replaces,
                    let position = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == replaces.trimmingCharacters(in: .whitespaces) })
                else {
                    additions.append("- \(stamp) \(operation.text ?? candidates[number].text) (source: \(source))")
                    result.added += 1
                    continue
                }
                lines[position] = "- \(stamp) \(text) (source: \(source))"
                if operation.kind == "merge" { result.merged += 1 } else { result.superseded += 1 }
            default:
                result.dropped += 1
            }
        }

        // Two merges into the same text leave duplicate lines; keep the first.
        var seen = Set<String>()
        lines = lines.filter { line in
            guard line.hasPrefix("- ") else { return true }
            return seen.insert(line).inserted
        }
        lines += additions
        let rewritten = lines.joined(separator: "\n")
        let entriesAfter = lines.filter { $0.hasPrefix("- ") }.count
        let removed = max(entriesBefore - (entriesAfter - additions.count), 0)
        let limits = directory.limits
        if entriesBefore > 0, Double(removed) / Double(entriesBefore) > maximumRemovedShare {
            result.rejected = "rewrite removed \(removed) of \(entriesBefore) entries"
        } else if rewritten.count > limits.indexCharacters || entriesAfter > limits.indexLines {
            result.rejected = "rewrite exceeds the index limit"
        }

        let archive = directory.root.appending(path: "archive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try original.write(to: archive.appending(path: "MEMORY-\(SessionDirectory.makeSessionID(date: now)).md"), atomically: true, encoding: .utf8)

        let final: String
        if result.rejected != nil {
            // Fall back to appending the additions only; nothing existing is touched.
            final = (original.isEmpty ? "" : original + "\n") + additions.joined(separator: "\n")
            result.merged = 0
            result.superseded = 0
        } else {
            final = rewritten
        }
        try final.trimmingCharacters(in: .whitespacesAndNewlines).appending("\n").write(to: directory.indexURL, atomically: true, encoding: .utf8)

        let diary = directory.root.appending(path: "consolidation.md")
        let line = "- \(stamp): \(candidates.count) candidates, \(result.added) added, \(result.merged) merged, \(result.superseded) superseded, \(result.dropped) dropped\(result.rejected.map { ". Rewrite rejected: \($0); additions appended instead" } ?? "")\n"
        if let handle = try? FileHandle(forWritingTo: diary) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } else {
            try "# Consolidation diary\n\n\(line)".write(to: diary, atomically: true, encoding: .utf8)
        }
        return result
    }
}

/// Runs memory consolidation as a scheduled job.
public struct MemoryConsolidationRunner: JobRunner {
    public let consolidation: MemoryConsolidation

    public init(consolidation: MemoryConsolidation) {
        self.consolidation = consolidation
    }

    public func run(_ wake: WakeMessage) async throws -> JobResult {
        let result = try await consolidation.run(now: wake.now)
        let summary = "\(result.candidates) candidates: \(result.added) added, \(result.merged) merged, \(result.superseded) superseded, \(result.dropped) dropped" + (result.rejected.map { "; rewrite rejected (\($0))" } ?? "")
        return JobResult(outcome: result.candidates == 0 ? .noChange : .done, summary: summary)
    }
}

/// Routes jobs to runners by job ID, with a default for the rest.
public struct CompositeJobRunner: JobRunner {
    public let runners: [String: any JobRunner]
    public let fallback: any JobRunner

    public init(runners: [String: any JobRunner], fallback: any JobRunner) {
        self.runners = runners
        self.fallback = fallback
    }

    public func run(_ wake: WakeMessage) async throws -> JobResult {
        try await (runners[wake.job.id] ?? fallback).run(wake)
    }
}

extension Job {
    /// The nightly consolidation job. Pair it with a `MemoryConsolidationRunner` in a `CompositeJobRunner`.
    public static func memoryConsolidation(cron: String = "0 3 * * *", timeZone: TimeZone = .current) -> Job {
        Job(
            id: "memory-consolidation",
            name: "Memory consolidation",
            schedule: .cron((try? CronExpression(cron)) ?? (try! CronExpression("0 3 * * *")), timeZone: timeZone.identifier),
            prompt: "Promote recent notes into the memory index.",
            catchUp: .once,
            createdBy: .system
        )
    }
}
