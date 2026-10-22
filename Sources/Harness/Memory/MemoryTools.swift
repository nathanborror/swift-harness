import Foundation
import FoundationModels

/// Appends an observation to today's note.
public struct MemoryNoteTool: AnnotatedTool {
    @Generable(description: "Append a note to today's memory file.")
    public struct Arguments {
        @Guide(description: "One observation, decision, or piece of running context, in a sentence or two")
        public var text: String
    }

    public let name = "memory_note"
    public let description = "Appends a dated note to today's memory file. Use it for observations and running context while you work. It cannot edit or delete earlier notes."
    public let annotations: ToolAnnotations = .mutating
    let directory: MemoryDirectory

    public init(directory: MemoryDirectory) {
        self.directory = directory
    }

    public func call(arguments: Arguments) async throws -> String {
        let url = try directory.appendNote(arguments.text)
        return "Noted in \(directory.relativePath(url))."
    }
}

/// Keyword search across every memory file.
public struct MemorySearchTool: AnnotatedTool {
    @Generable(description: "Search memory files.")
    public struct Arguments {
        @Guide(description: "Words that must all appear on a matching line")
        public var query: String
    }

    public let name = "memory_search"
    public let description = "Searches every memory file for lines containing all the given words. Returns path:line and the line. Use it before answering anything about earlier sessions, decisions, dates, or preferences."
    public let annotations: ToolAnnotations = .readOnly
    let directory: MemoryDirectory
    let limit: Int

    public init(directory: MemoryDirectory, limit: Int = 20) {
        self.directory = directory
        self.limit = limit
    }

    public func call(arguments: Arguments) async throws -> String {
        let matches = directory.search(arguments.query, limit: limit)
        guard !matches.isEmpty else { return "No memory lines match \"\(arguments.query)\". This means no match was found, not that nothing relevant exists; try fewer or different words." }
        var lines = matches.map { "\($0.path):\($0.line): \($0.text)" }
        if matches.count >= limit { lines.append("(first \(limit) matches shown; narrow the query for more)") }
        return lines.joined(separator: "\n")
    }
}

/// The memory tool set: read, edit, and write over the memory directory plus
/// note and search. Read, edit, and write are the file tools rooted at the
/// memory folder, so the same stale-read rules apply.
public struct MemoryTools: Sendable {
    public let directory: MemoryDirectory
    public let context: FileToolContext

    public init(directory: MemoryDirectory) throws {
        self.directory = directory
        self.context = FileToolContext(workspace: try Workspace(root: directory.root))
    }

    public var read: ReadTool { ReadTool(context: context, name: "memory_read") }
    public var edit: EditTool { EditTool(context: context, name: "memory_edit") }
    public var write: WriteTool { WriteTool(context: context, name: "memory_write") }
    public var note: MemoryNoteTool { MemoryNoteTool(directory: directory) }
    public var search: MemorySearchTool { MemorySearchTool(directory: directory) }

    public func gated(by gate: ToolGate) -> [any Tool] {
        [gate.gate(read), gate.gate(edit), gate.gate(write), gate.gate(note), gate.gate(search)]
    }
}
