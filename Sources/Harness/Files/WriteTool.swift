import Foundation
import FoundationModels

/// Creates a file or rewrites one completely.
public struct WriteTool: AnnotatedTool {
    @Generable(description: "Write a whole file.")
    public struct Arguments {
        @Guide(description: "Path relative to the workspace, or an absolute path inside it")
        public var path: String
        @Guide(description: "The complete file contents")
        public var content: String
    }

    public let name: String
    public let description = "Creates a file or replaces its entire contents. Parent folders are created. Use it for new files and complete rewrites; use edit for changes. An existing file must be read before it is overwritten."
    public let annotations: ToolAnnotations = .mutating
    let context: FileToolContext

    public init(context: FileToolContext, name: String = "write") {
        self.context = context
        self.name = name
    }

    public func call(arguments: Arguments) async throws -> String {
        let url = try context.workspace.url(for: arguments.path)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue { throw FileToolError.isDirectory(path: arguments.path) }
        if exists {
            switch await context.reads.status(of: url) {
            case .unread: throw FileToolError.notRead(path: arguments.path)
            case .changed: throw FileToolError.changedSinceRead(path: arguments.path)
            case .unchanged: break
            }
        }
        let content = arguments.content
        try await context.edits.perform {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        await context.reads.recordRead(url)
        return "\(exists ? "Overwrote" : "Wrote") \(arguments.path) (\(content.utf8.count) bytes)."
    }
}
