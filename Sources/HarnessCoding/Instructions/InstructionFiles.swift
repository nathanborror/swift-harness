import Foundation
import Harness
import FoundationModels

/// Human-written instruction files found in the workspace, such as `AGENTS.md`.
///
/// Files are read from the workspace root down to a subdirectory, broadest
/// first, and concatenated under a size cap. Keep them short and let them point
/// at deeper documents: an instruction file is a map, not a manual.
public struct InstructionFiles: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        public let url: URL
        public let text: String
    }

    public let files: [File]
    public let truncated: Bool

    public static let defaultNames = ["AGENTS.md", "HARNESS.md"]

    /// Loads instruction files along the path from the workspace root to `directory`.
    public static func load(workspace: Workspace, directory: String? = nil, names: [String] = defaultNames, maximumBytes: Int = 32 * 1024) -> InstructionFiles {
        var folders: [URL] = [workspace.root]
        if let directory, let target = try? workspace.url(for: directory) {
            var current = target
            var chain: [URL] = []
            while current.path != workspace.root.path, current.pathComponents.count > workspace.root.pathComponents.count {
                chain.insert(current, at: 0)
                current = current.deletingLastPathComponent()
            }
            folders += chain
        }
        var files: [File] = []
        var bytes = 0
        var truncated = false
        for folder in folders {
            for name in names {
                let url = folder.appending(path: name)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if bytes + text.utf8.count > maximumBytes { truncated = true; continue }
                bytes += text.utf8.count
                files.append(File(url: url, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        return InstructionFiles(files: files, truncated: truncated)
    }

    public init(files: [File], truncated: Bool) {
        self.files = files
        self.truncated = truncated
    }

    public var isEmpty: Bool { files.isEmpty }

    /// The files as one block, each introduced by its path.
    public func rendered() -> String {
        var sections = files.map { "## Instructions from \($0.url.lastPathComponent) (\($0.url.path))\n\($0.text)" }
        if truncated { sections.append("[Some instruction files were skipped because the combined size exceeded the limit.]") }
        return sections.joined(separator: "\n\n")
    }

    public var instructions: Instructions? {
        isEmpty ? nil : Instructions(rendered())
    }
}
