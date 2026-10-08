import Foundation
import FoundationModels

/// Masks old tool outputs and compacts the history when the window fills.
///
/// Attach with `.managingContext(policy:summarizer:...)`. Place it on the
/// profile that owns the session; it reads and rewrites the session history
/// through `@SessionProperty`.
public struct ContextManagement: LanguageModelSession.DynamicProfileModifier, Sendable {
    public let policy: ContextPolicy
    /// The model that writes compaction summaries. A cheaper model is fine.
    public let summarizer: any LanguageModel
    /// Where the pre-compaction history is archived. Nil skips archiving.
    public let directory: SessionDirectory?
    /// Where durable facts are flushed before compaction. Nil skips the flush.
    public let memory: MemoryDirectory?
    public let log: SessionLog?

    @SessionProperty(\.history)
    private var history

    public init(policy: ContextPolicy, summarizer: any LanguageModel, directory: SessionDirectory? = nil, memory: MemoryDirectory? = nil, log: SessionLog? = nil) {
        self.policy = policy
        self.summarizer = summarizer
        self.directory = directory
        self.memory = memory
        self.log = log
    }

    public func body(content: Content) -> some LanguageModelSession.DynamicProfile {
        let policy = self.policy
        return content
            .historyTransform { entries in Self.masked(entries, policy: policy) }
            .onResponse { await compactIfNeeded() }
    }

    // MARK: Masking (stateless)

    /// Replaces old tool outputs with a pointer once the estimate passes the mask
    /// threshold. The cut index moves in steps of `keepRecentToolOutputs`, so the
    /// view stays byte-identical between steps and the provider cache holds.
    static func masked(_ entries: [Transcript.Entry], policy: ContextPolicy) -> [Transcript.Entry] {
        guard policy.estimatedTokens(entries) > policy.maskThresholdTokens else { return entries }
        let outputIndexes = entries.indices.filter { if case .toolOutput = entries[$0] { true } else { false } }
        let keep = max(policy.keepRecentToolOutputs, 1)
        guard outputIndexes.count > keep else { return entries }
        let cut = ((outputIndexes.count - keep) / keep) * keep
        guard cut > 0 else { return entries }
        var result = entries
        for index in outputIndexes.prefix(cut) {
            guard case .toolOutput(let output) = entries[index] else { continue }
            let characters = TranscriptText.segments(output.segments).count
            let pointer = "[Output of \(output.toolName) elided to save context: \(characters) characters. It was shown earlier in this session; run the tool again if you need it.]"
            result[index] = .toolOutput(Transcript.ToolOutput(id: output.id, toolName: output.toolName, segments: [.text(.init(content: pointer))]))
        }
        return result
    }

    // MARK: Compaction (stateful)

    private func compactIfNeeded() async {
        let entries = Array(history)
        guard policy.estimatedTokens(entries) > policy.compactThresholdTokens, entries.count > policy.keepRecentEntries else { return }
        do {
            let compacted = try await Compactor(policy: policy, summarizer: summarizer, directory: directory, memory: memory, log: log).compact(entries)
            history = Transcript.HistoryView(compacted)
        } catch {
            await log?.record(.note("Compaction failed and the history was left as is: \(error.localizedDescription)"))
        }
    }
}

/// Archives, flushes, summarizes, and returns the new history.
struct Compactor: Sendable {
    let policy: ContextPolicy
    let summarizer: any LanguageModel
    let directory: SessionDirectory?
    let memory: MemoryDirectory?
    let log: SessionLog?

    static let summaryTemplate = """
        Summarize the conversation below for an agent that will continue the work with this summary as its only record of it. Use exactly these headings and keep it factual:
        ## Objective
        ## Key decisions and rationale
        ## Files and commands
        ## User messages
        Preserve the user's requests nearly verbatim.
        ## Progress
        ## Open issues
        ## Next step
        """

    static let flushTemplate = """
        From the conversation below, list facts worth remembering in a later session: durable decisions, user preferences, lessons from failures, and where things live. One line each, specific, with a file path or source where possible. Skip anything already obvious from the workspace and never include secrets. If there is nothing durable, reply with exactly NONE.
        """

    func compact(_ entries: [Transcript.Entry]) async throws -> [Transcript.Entry] {
        let keep = max(policy.keepRecentEntries, 0)
        let split = Self.splitIndex(entries, keep: keep)
        let older = Array(entries[..<split])
        let recent = Array(entries[split...])
        guard !older.isEmpty else { return entries }

        var archivePath: String?
        if let directory {
            let archive = directory.url.appending(path: "archive", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            let url = archive.appending(path: "history-\(SessionDirectory.makeSessionID()).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(Transcript(entries: entries)).write(to: url, options: [.atomic])
            archivePath = url.path
        }

        let rendered = TranscriptText.render(older)
        if let memory {
            await flush(rendered, into: memory)
        }

        let session = LanguageModelSession(model: summarizer, instructions: "You write precise handoff summaries.")
        let summary = try await session.respond(to: "\(Self.summaryTemplate)\n\n<conversation>\n\(rendered)\n</conversation>").content

        var text = "Earlier parts of this session were compacted. Summary of the work so far:\n\n\(summary)"
        if let archivePath { text += "\n\nThe full earlier history is archived at \(archivePath)." }
        let summaryPrompt = Transcript.Entry.prompt(.init(segments: [.text(.init(content: text))]))
        let acknowledgement = Transcript.Entry.response(.init(segments: [.text(.init(content: "Understood. Continuing from the summary."))]))
        let reattached = Self.reattachments(from: older, stillPresentIn: recent, policy: policy)
        await log?.record(.compaction(archivedTo: archivePath, droppedEntries: older.count, keptEntries: recent.count, summaryCharacters: summary.count))
        return [summaryPrompt, acknowledgement] + reattached + recent
    }

    /// The last output per distinct call of each re-attached tool that would
    /// otherwise be lost, as a tool call and output pair. Losing a loaded skill
    /// degrades the agent silently, so it is carried across the compaction.
    static func reattachments(from older: [Transcript.Entry], stillPresentIn recent: [Transcript.Entry], policy: ContextPolicy) -> [Transcript.Entry] {
        guard !policy.reattachedTools.isEmpty else { return [] }
        func calls(in entries: [Transcript.Entry]) -> [(key: String, call: Transcript.ToolCall, output: Transcript.ToolOutput)] {
            var outputs: [String: Transcript.ToolOutput] = [:]
            for case .toolOutput(let output) in entries { outputs[output.id] = output }
            var found: [(String, Transcript.ToolCall, Transcript.ToolOutput)] = []
            for case .toolCalls(let group) in entries {
                for call in group where policy.reattachedTools.contains(call.toolName) {
                    guard let output = outputs[call.id] else { continue }
                    found.append(("\(call.toolName):\(call.arguments.jsonString)", call, output))
                }
            }
            return found
        }
        let kept = Set(calls(in: recent).map(\.key))
        var latest: [String: (Transcript.ToolCall, Transcript.ToolOutput)] = [:]
        var order: [String] = []
        for (key, call, output) in calls(in: older) where !kept.contains(key) {
            if latest[key] == nil { order.append(key) }
            latest[key] = (call, output)
        }
        var entries: [Transcript.Entry] = []
        var total = 0
        for key in order {
            guard let (call, output) = latest[key] else { continue }
            var text = TranscriptText.segments(output.segments)
            if text.count > policy.reattachCharactersPerOutput {
                text = String(text.prefix(policy.reattachCharactersPerOutput)) + "\n[truncated when re-attached after compaction]"
            }
            guard total + text.count <= policy.reattachCharactersTotal else { break }
            total += text.count
            let id = "reattached-\(call.id)"
            entries.append(.toolCalls(Transcript.ToolCalls(id: "reattached-calls-\(call.id)", [Transcript.ToolCall(id: id, toolName: call.toolName, arguments: call.arguments)])))
            entries.append(.toolOutput(Transcript.ToolOutput(id: id, toolName: output.toolName, segments: [.text(.init(content: "(re-attached after compaction)\n" + text))])))
        }
        return entries
    }

    /// Keeps the last `keep` entries, extended backward so the tail starts at a prompt
    /// and no tool call is separated from its output.
    static func splitIndex(_ entries: [Transcript.Entry], keep: Int) -> Int {
        guard !entries.isEmpty else { return 0 }
        var index = min(max(entries.count - keep, 0), entries.count - 1)
        while index > 0 {
            if case .prompt = entries[index] { break }
            index -= 1
        }
        return index
    }

    private func flush(_ rendered: String, into memory: MemoryDirectory) async {
        do {
            let session = LanguageModelSession(model: summarizer, instructions: "You extract durable facts for an agent's memory.")
            let reply = try await session.respond(to: "\(Self.flushTemplate)\n\n<conversation>\n\(rendered)\n</conversation>").content
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != "NONE", !trimmed.isEmpty else { return }
            try memory.appendNote("Flushed before compaction:\n" + trimmed.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
        } catch {
            await log?.record(.note("Memory flush before compaction failed: \(error.localizedDescription)"))
        }
    }
}

extension LanguageModelSession.DynamicProfile {
    /// Masks old tool outputs and compacts the history under the given policy.
    public func managingContext(policy: ContextPolicy, summarizer: any LanguageModel, directory: SessionDirectory? = nil, memory: MemoryDirectory? = nil, log: SessionLog? = nil) -> some LanguageModelSession.DynamicProfile {
        modifier(ContextManagement(policy: policy, summarizer: summarizer, directory: directory, memory: memory, log: log))
    }
}
