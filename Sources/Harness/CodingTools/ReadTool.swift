import Foundation
import FoundationModels

/// Reads a window of a text file, or lists a directory.
public struct ReadTool: AnnotatedTool {
    @Generable(description: "Read a file or list a directory.")
    public struct Arguments {
        @Guide(description: "Path relative to the workspace, or an absolute path inside it")
        public var path: String
        @Guide(description: "First line to show, counting from 1. Defaults to 1.")
        public var offset: Int?
        @Guide(description: "Maximum number of lines to show")
        public var limit: Int?
    }

    public let name = "read"
    public let description = "Reads a text file as a window of lines, or lists a directory. Large files are paged: the footer says how to continue. Prefer a generous window over many tiny reads."
    public let annotations: ToolAnnotations = .readOnly
    let context: CodingToolContext

    public init(context: CodingToolContext) {
        self.context = context
    }

    public func call(arguments: Arguments) async throws -> String {
        let url = try context.workspace.url(for: arguments.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CodingToolError.notFound(path: arguments.path, suggestions: CodingToolSupport.suggestions(for: url))
        }
        if isDirectory.boolValue {
            return try listDirectory(url)
        }
        let text = try CodingToolSupport.readText(at: url, path: arguments.path)
        await context.reads.recordRead(url)
        return window(of: text, offset: arguments.offset, limit: arguments.limit)
    }

    func window(of text: String, offset: Int?, limit: Int?) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let total = lines.count
        let start = max((offset ?? 1) - 1, 0)
        guard start < total else {
            return "(file has \(total) lines; offset \(start + 1) is past the end)"
        }
        let requested = max(limit ?? context.limits.readLines, 1)
        var end = min(start + requested, total)
        var selected = lines[start..<end].joined(separator: "\n")
        var cutByBytes = false
        if selected.utf8.count > context.limits.readBytes {
            cutByBytes = true
            var kept: [Substring] = []
            var bytes = 0
            for line in lines[start..<end] {
                let lineBytes = line.utf8.count + 1
                if bytes + lineBytes > context.limits.readBytes, !kept.isEmpty { break }
                kept.append(line)
                bytes += lineBytes
            }
            end = start + kept.count
            selected = kept.joined(separator: "\n")
        }
        if end >= total, !cutByBytes {
            return selected.isEmpty ? "(empty file)" : selected
        }
        return selected + "\n\n(Showing lines \(start + 1)-\(end) of \(total). Use offset=\(end + 1) to continue.)"
    }

    private func listDirectory(_ url: URL) throws -> String {
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        guard !names.isEmpty else { return "(empty directory)" }
        return names.map { name in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.appending(path: name).path, isDirectory: &isDirectory)
            return isDirectory.boolValue ? name + "/" : name
        }.joined(separator: "\n")
    }
}
