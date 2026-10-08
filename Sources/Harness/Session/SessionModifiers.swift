import Foundation
import FoundationModels

/// Records every transcript entry the session produces into a `SessionLog`.
public struct SessionLogging: LanguageModelSession.DynamicProfileModifier, Sendable {
    let log: SessionLog

    public init(log: SessionLog) {
        self.log = log
    }

    public func body(content: Content) -> some LanguageModelSession.DynamicProfile {
        let log = self.log
        return content
            .onPrompt { prompt in
                await log.record(.prompt(Transcript(entries: [.prompt(prompt)])))
            }
            .onReasoning { reasoning in
                await log.record(.reasoning(Transcript(entries: [.reasoning(reasoning)])))
            }
            .onResponse { response in
                await log.record(.response(Transcript(entries: [.response(response)])))
            }
            .onToolCall { call in
                await log.record(.toolCall(Transcript(entries: [.toolCalls(Transcript.ToolCalls([call]))])))
            }
            .onToolOutput { _, output in
                await log.record(.toolOutput(Transcript(entries: [.toolOutput(output)])))
            }
    }
}

/// Saves the session history to disk after every response and tool output,
/// so a crashed or quit app can resume from `SessionDirectory.loadTranscript()`.
public struct TranscriptPersistence: LanguageModelSession.DynamicProfileModifier, Sendable {
    let directory: SessionDirectory
    let log: SessionLog?

    @SessionProperty(\.history)
    private var history

    public init(directory: SessionDirectory, log: SessionLog? = nil) {
        self.directory = directory
        self.log = log
    }

    public func body(content: Content) -> some LanguageModelSession.DynamicProfile {
        content
            .onResponse { await save() }
            .onToolOutput { await save() }
    }

    private func save() async {
        do {
            try directory.saveTranscript(Transcript(entries: Array(history)))
        } catch {
            await log?.record(.note("Transcript save failed: \(error.localizedDescription)"))
        }
    }
}

extension LanguageModelSession.DynamicProfile {
    /// Logs transcript entries to the session log.
    public func logging(to log: SessionLog) -> some LanguageModelSession.DynamicProfile {
        modifier(SessionLogging(log: log))
    }

    /// Saves the transcript into the session directory after each turn.
    public func persistingTranscript(in directory: SessionDirectory, log: SessionLog? = nil) -> some LanguageModelSession.DynamicProfile {
        modifier(TranscriptPersistence(directory: directory, log: log))
    }
}
