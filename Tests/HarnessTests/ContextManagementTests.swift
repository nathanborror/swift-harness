import Foundation
import FoundationModels
import Testing
@testable import Harness

@Suite struct ContextManagementTests {
    private func output(_ index: Int, size: Int = 400) -> Transcript.Entry {
        .toolOutput(.init(id: "call-\(index)", toolName: "shell", segments: [.text(.init(content: String(repeating: "x", count: size)))]))
    }

    private func conversation(outputs: Int) -> [Transcript.Entry] {
        var entries: [Transcript.Entry] = []
        for index in 0..<outputs {
            entries.append(.prompt(.init(id: "p\(index)", segments: [.text(.init(content: "step \(index)"))])))
            entries.append(.toolCalls(.init(id: "tc\(index)", [Transcript.ToolCall(id: "call-\(index)", toolName: "shell", arguments: GeneratedContent("{}"))])))
            entries.append(output(index))
            entries.append(.response(.init(id: "r\(index)", segments: [.text(.init(content: "done \(index)"))])))
        }
        return entries
    }

    @Test func masksOldToolOutputsInBatchesOnceOverThreshold() {
        let policy = ContextPolicy(contextTokens: 10_000, maskAt: 0.1, keepRecentToolOutputs: 2, charactersPerToken: 1)
        let small = conversation(outputs: 2)
        #expect(ContextManagement.masked(small, policy: policy) == small, "under threshold nothing changes")

        let big = conversation(outputs: 5)
        let masked = ContextManagement.masked(big, policy: policy)
        let outputs = masked.compactMap { entry -> String? in
            if case .toolOutput(let value) = entry { return TranscriptText.segments(value.segments) }
            return nil
        }
        // 5 outputs, keep 2: cut = ((5-2)/2)*2 = 2, so the first two are masked.
        #expect(outputs.count == 5)
        #expect(outputs[0].hasPrefix("[Output of shell elided") && outputs[0].contains("400 characters"))
        #expect(outputs[1].hasPrefix("[Output of shell elided"))
        #expect(outputs[2].hasPrefix("xxxx") && outputs[4].hasPrefix("xxxx"))
        #expect(masked.count == big.count, "masking never removes entries")
        if case .toolOutput(let value) = masked[2] { #expect(value.id == "call-0", "ids are preserved so outputs still match calls") }

        let bigger = ContextManagement.masked(conversation(outputs: 6), policy: policy)
        let maskedCount = bigger.filter { if case .toolOutput(let v) = $0 { TranscriptText.segments(v.segments).hasPrefix("[Output") } else { false } }.count
        #expect(maskedCount == 4, "six outputs: cut = ((6-2)/2)*2 = 4")
    }

    @Test func splitIndexStartsTheTailAtAPrompt() {
        let entries = conversation(outputs: 3)
        #expect(Compactor.splitIndex(entries, keep: 3) == 8, "three from the end lands mid-turn, so back up to the prompt at index 8")
        #expect(Compactor.splitIndex(entries, keep: 100) == 0)
        #expect(Compactor.splitIndex(entries, keep: 0) == 8, "keeping nothing still keeps the last turn whole")
        #expect(Compactor.splitIndex([], keep: 3) == 0)
    }

    struct Profile: LanguageModelSession.DynamicProfile {
        let policy: ContextPolicy
        let directory: SessionDirectory
        let memory: MemoryDirectory
        let log: SessionLog

        var body: some LanguageModelSession.DynamicProfile {
            Profile {
                Instructions("test")
                EchoTool()
            }
            .model(EchoModel())
            .managingContext(policy: policy, summarizer: EchoModel(), directory: directory, memory: memory, log: log)
        }
    }

    @Test func compactsHistoryArchivesFlushesAndSummarizes() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "harness-context-\(UUID().uuidString)")
        let directory = try SessionDirectory(root: base.appending(path: "sessions"))
        let memory = try MemoryDirectory(root: base.appending(path: "memory"))
        let log = try directory.makeLog()
        // Window of 300 tokens at one character per token: compaction at 240 characters.
        let policy = ContextPolicy(contextTokens: 300, maskAt: 0.9, keepRecentToolOutputs: 1, compactAt: 0.8, keepRecentEntries: 2, charactersPerToken: 1)
        let session = LanguageModelSession(profile: Profile(policy: policy, directory: directory, memory: memory, log: log))

        for index in 0..<6 {
            _ = try await session.respond(to: "turn \(index) " + String(repeating: "word ", count: 12))
        }
        let entries = Array(session.transcript.history)
        guard case .prompt(let summaryPrompt)? = entries.first else {
            Issue.record("history should start with the summary prompt, got \(String(describing: entries.first))")
            return
        }
        let summaryText = TranscriptText.segments(summaryPrompt.segments)
        #expect(summaryText.hasPrefix("Earlier parts of this session were compacted."))
        #expect(summaryText.contains("echo: "), "the echo summarizer wrote the summary")
        #expect(summaryText.contains("archived at"))
        #expect(entries.count < 12, "compaction shrank the history, now \(entries.count)")

        let archives = try FileManager.default.contentsOfDirectory(atPath: directory.url.appending(path: "archive").path)
        #expect(!archives.isEmpty)
        let note = try String(contentsOf: memory.noteURL(), encoding: .utf8)
        #expect(note.contains("Flushed before compaction"))

        await log.close()
        let compactions = try SessionLog.read(url: log.url).filter { if case .compaction = $0.event { true } else { false } }
        #expect(!compactions.isEmpty)
    }
}
