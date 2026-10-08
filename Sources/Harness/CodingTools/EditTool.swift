import Foundation
import FoundationModels

/// Replaces exact text in a file the model has already read.
public struct EditTool: AnnotatedTool {
    @Generable(description: "One replacement: the exact existing text and what replaces it.")
    public struct Edit {
        @Guide(description: "Exact text to find, including whitespace. Keep it as short as possible while still unique.")
        public var oldText: String
        @Guide(description: "Replacement text")
        public var newText: String
    }

    @Generable(description: "Edit a file by exact string replacement.")
    public struct Arguments {
        @Guide(description: "Path relative to the workspace, or an absolute path inside it")
        public var path: String
        @Guide(description: "Replacements applied in order, each against the result of the previous one", .minimumCount(1))
        public var edits: [Edit]
        @Guide(description: "Replace every occurrence instead of requiring exactly one")
        public var replaceAll: Bool?
    }

    public let name: String
    public let description = "Edits a file by replacing exact text. Each old_text must appear exactly once unless replace_all is set. Read the file first; the edit is refused if the file changed since."
    public let annotations: ToolAnnotations = .mutating
    let context: CodingToolContext

    public init(context: CodingToolContext, name: String = "edit") {
        self.context = context
        self.name = name
    }

    public func call(arguments: Arguments) async throws -> String {
        let url = try context.workspace.url(for: arguments.path)
        switch await context.reads.status(of: url) {
        case .unread: throw CodingToolError.notRead(path: arguments.path)
        case .changed: throw CodingToolError.changedSinceRead(path: arguments.path)
        case .unchanged: break
        }
        let path = arguments.path
        let edits = arguments.edits.map { ($0.oldText, $0.newText) }
        let replaceAll = arguments.replaceAll ?? false
        let summary = try await context.edits.perform {
            try Self.apply(edits, to: url, path: path, replaceAll: replaceAll)
        }
        await context.reads.recordRead(url)
        return summary
    }

    static func apply(_ edits: [(old: String, new: String)], to url: URL, path: String, replaceAll: Bool) throws -> String {
        let (original, hasBOM) = try CodingToolSupport.readFile(at: url, path: path)
        let usesCRLF = original.contains("\r\n")
        var working = original
        if usesCRLF { working = working.replacingOccurrences(of: "\r\n", with: "\n") }

        var replacements = 0
        for (index, edit) in edits.enumerated() {
            let occurrences = working.components(separatedBy: edit.old).count - 1
            guard !edit.old.isEmpty, occurrences > 0 else {
                throw CodingToolError.textNotFound(path: path, index: index)
            }
            if occurrences > 1, !replaceAll {
                throw CodingToolError.textNotUnique(path: path, index: index, occurrences: occurrences)
            }
            working = working.replacingOccurrences(of: edit.old, with: edit.new)
            replacements += occurrences
        }

        var output = working
        if usesCRLF { output = output.replacingOccurrences(of: "\n", with: "\r\n") }
        var bytes = Data(output.utf8)
        if hasBOM { bytes = CodingToolSupport.utf8BOM + bytes }
        try bytes.write(to: url, options: [.atomic])
        return "Edited \(path): \(replacements) replacement\(replacements == 1 ? "" : "s")."
    }
}
