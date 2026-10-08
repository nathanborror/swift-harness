import Foundation

/// Bounds a tool result before it enters the context window.
///
/// Oversized output is written to a file and replaced by an excerpt plus a
/// note that says what was cut and how to get the rest.
public struct ToolResultShaper: Sendable {
    public enum Strategy: Sendable {
        /// Keep the start. Right for file reads and listings.
        case head
        /// Keep the end. Right for command output, where errors and summaries come last.
        case tail
        /// Keep both ends and cut the middle.
        case headAndTail
    }

    public var maximumCharacters: Int
    public var strategy: Strategy
    /// Where full output goes when it is cut. Nil disables offloading.
    public var outputsDirectory: URL?
    /// What an empty result becomes, so silence is never ambiguous.
    public var emptyPlaceholder: String

    public init(maximumCharacters: Int = 30_000, strategy: Strategy = .headAndTail, outputsDirectory: URL? = nil, emptyPlaceholder: String = "(no output)") {
        self.maximumCharacters = maximumCharacters
        self.strategy = strategy
        self.outputsDirectory = outputsDirectory
        self.emptyPlaceholder = emptyPlaceholder
    }

    public struct Result: Sendable, Equatable {
        public let text: String
        public let originalCharacters: Int
        public let truncated: Bool
        public let offloadedTo: URL?
    }

    public func shape(_ output: String, toolName: String, callID: String) -> Result {
        let count = output.count
        guard count > 0 else {
            return Result(text: emptyPlaceholder, originalCharacters: 0, truncated: false, offloadedTo: nil)
        }
        guard count > maximumCharacters else {
            return Result(text: output, originalCharacters: count, truncated: false, offloadedTo: nil)
        }
        let offloaded = offload(output, toolName: toolName, callID: callID)
        let excerpt = excerpt(of: output)
        var note = "\n\n...\(count - excerpt.kept) characters truncated...\n\nThe tool call succeeded but the output was truncated."
        if let offloaded {
            note += " Full output saved to: \(offloaded.path)\nRead that file with an offset and limit to view specific sections."
        } else {
            note += " Narrow the request to see the rest."
        }
        return Result(text: excerpt.text + note, originalCharacters: count, truncated: true, offloadedTo: offloaded)
    }

    private func excerpt(of output: String) -> (text: String, kept: Int) {
        switch strategy {
        case .head:
            let kept = String(output.prefix(maximumCharacters))
            return (kept, kept.count)
        case .tail:
            let kept = String(output.suffix(maximumCharacters))
            return (kept, kept.count)
        case .headAndTail:
            let headCount = maximumCharacters / 2
            let tailCount = maximumCharacters - headCount
            let head = String(output.prefix(headCount))
            let tail = String(output.suffix(tailCount))
            return (head + "\n\n[... middle of output omitted ...]\n\n" + tail, head.count + tail.count)
        }
    }

    private func offload(_ output: String, toolName: String, callID: String) -> URL? {
        guard let outputsDirectory else { return nil }
        let safeTool = toolName.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let safeCall = callID.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let url = outputsDirectory.appending(path: "\(String(safeTool))-\(String(safeCall)).txt")
        do {
            try FileManager.default.createDirectory(at: outputsDirectory, withIntermediateDirectories: true)
            try output.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
