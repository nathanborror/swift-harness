import Foundation
import FoundationModels

/// When and how the harness trims what the model sees.
///
/// Sizes are fractions of the model's context window. Masking is stateless and
/// cheap: old tool outputs are replaced by a pointer in the view sent to the
/// model, and the transcript on disk is untouched. Compaction is stateful: the
/// history itself is replaced by a summary plus the recent tail, after the full
/// history is archived and anything durable is flushed to memory.
public struct ContextPolicy: Sendable {
    /// The model's context window in tokens.
    public var contextTokens: Int
    /// Fraction of the window at which old tool outputs are masked.
    public var maskAt: Double
    /// Tool outputs kept verbatim when masking. The cut moves in steps of this size.
    public var keepRecentToolOutputs: Int
    /// Fraction of the window at which compaction runs.
    public var compactAt: Double
    /// Entries kept verbatim after compaction.
    public var keepRecentEntries: Int
    /// Characters per token for the size estimate. No tokenizer is available for arbitrary models.
    public var charactersPerToken: Double

    public init(contextTokens: Int, maskAt: Double = 0.5, keepRecentToolOutputs: Int = 8, compactAt: Double = 0.8, keepRecentEntries: Int = 20, charactersPerToken: Double = 3.5) {
        self.contextTokens = contextTokens
        self.maskAt = maskAt
        self.keepRecentToolOutputs = keepRecentToolOutputs
        self.compactAt = compactAt
        self.keepRecentEntries = keepRecentEntries
        self.charactersPerToken = charactersPerToken
    }

    public var maskThresholdTokens: Int { Int(Double(contextTokens) * maskAt) }
    public var compactThresholdTokens: Int { Int(Double(contextTokens) * compactAt) }

    public func estimatedTokens(_ entries: some Sequence<Transcript.Entry>) -> Int {
        var characters = 0
        for entry in entries { characters += TranscriptText.characters(in: entry) }
        return Int(Double(characters) / charactersPerToken)
    }
}

/// Plain-text views of transcript entries, for size estimates and summaries.
enum TranscriptText {
    static func characters(in entry: Transcript.Entry) -> Int {
        switch entry {
        case .instructions(let value): return segments(value.segments).count + value.toolDefinitions.reduce(0) { $0 + $1.name.count + $1.description.count + 200 }
        case .prompt(let value): return segments(value.segments).count
        case .response(let value): return segments(value.segments).count
        case .reasoning(let value): return segments(value.segments).count
        case .toolCalls(let value): return value.reduce(0) { $0 + $1.toolName.count + $1.arguments.jsonString.count }
        case .toolOutput(let value): return segments(value.segments).count
        @unknown default: return 0
        }
    }

    static func segments(_ segments: [Transcript.Segment]) -> String {
        var parts: [String] = []
        for segment in segments {
            switch segment {
            case .text(let text): parts.append(text.content)
            case .structure(let structure): parts.append(structure.content.jsonString)
            case .attachment: parts.append("[attachment]")
            @unknown default: continue
            }
        }
        return parts.joined(separator: "\n")
    }

    /// A readable rendering of entries, for the summarizer.
    static func render(_ entries: some Sequence<Transcript.Entry>) -> String {
        var lines: [String] = []
        for entry in entries {
            switch entry {
            case .instructions: continue
            case .prompt(let value): lines.append("USER: \(segments(value.segments))")
            case .response(let value): lines.append("ASSISTANT: \(segments(value.segments))")
            case .reasoning: continue
            case .toolCalls(let value):
                for call in value { lines.append("TOOL CALL \(call.toolName): \(call.arguments.jsonString)") }
            case .toolOutput(let value): lines.append("TOOL OUTPUT \(value.toolName): \(segments(value.segments))")
            @unknown default: continue
            }
        }
        return lines.joined(separator: "\n\n")
    }
}
