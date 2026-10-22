import Foundation
import Testing
@testable import Harness
@testable import HarnessCoding

@Suite struct InstructionFilesTests {
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "harness-instructions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func instructionFilesLoadRootToDirectory() throws {
        let root = try makeRoot()
        let workspace = try Workspace(root: root)
        try "Root rules".write(to: root.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appending(path: "pkg/sub"), withIntermediateDirectories: true)
        try "Package rules".write(to: root.appending(path: "pkg/AGENTS.md"), atomically: true, encoding: .utf8)
        let files = InstructionFiles.load(workspace: workspace, directory: "pkg/sub")
        #expect(files.files.map(\.text) == ["Root rules", "Package rules"])
        #expect(files.rendered().contains("## Instructions from AGENTS.md"))
        let capped = InstructionFiles.load(workspace: workspace, directory: "pkg/sub", maximumBytes: 12)
        #expect(capped.files.map(\.text) == ["Root rules"])
        #expect(capped.truncated)
        #expect(InstructionFiles.load(workspace: try Workspace(root: try makeRoot())).instructions == nil)
    }
}
