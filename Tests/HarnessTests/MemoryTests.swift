import Foundation
import FoundationModels
import Testing
@testable import Harness

@Suite struct MemoryTests {
    private func makeDirectory(limits: MemoryDirectory.Limits = .init()) throws -> MemoryDirectory {
        try MemoryDirectory(root: FileManager.default.temporaryDirectory.appending(path: "harness-memory-\(UUID().uuidString)"), limits: limits)
    }

    @Test func createsLayoutAndRendersEmptyFiles() throws {
        let directory = try makeDirectory()
        #expect(FileManager.default.fileExists(atPath: directory.indexURL.path))
        #expect(FileManager.default.fileExists(atPath: directory.notesURL.path))
        #expect(directory.renderIndex() == .init(text: "", truncated: false))
        let rendered = MemoryInstructions(directory: directory).rendered()
        #expect(rendered.contains("### MEMORY.md\n(empty)"))
        #expect(!rendered.contains("Recent notes"))
    }

    @Test func capsIndexAndTellsTheModel() throws {
        let directory = try makeDirectory(limits: .init(indexCharacters: 1_000, indexLines: 3))
        try (1...5).map { "- fact \($0)" }.joined(separator: "\n").write(to: directory.indexURL, atomically: true, encoding: .utf8)
        let rendering = directory.renderIndex()
        #expect(rendering.truncated)
        #expect(rendering.text.hasPrefix("- fact 1\n- fact 2\n- fact 3\n"))
        #expect(rendering.text.contains("over its limit"))
        #expect(try String(contentsOf: directory.indexURL, encoding: .utf8).contains("fact 5"), "the file on disk is untouched")
    }

    @Test func appendsDatedNotesAndRendersRecentOnes() throws {
        let directory = try makeDirectory()
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: today)!
        try directory.appendNote("first thing", date: today)
        try directory.appendNote("second thing", date: today)
        try directory.appendNote("older", date: yesterday)
        try directory.appendNote("ancient", date: twoDaysAgo)
        let todayText = try String(contentsOf: directory.noteURL(for: today), encoding: .utf8)
        #expect(todayText.hasPrefix("# "))
        #expect(todayText.contains("first thing") && todayText.contains("second thing"))
        let recent = directory.renderRecentNotes(now: today)
        #expect(recent.text.contains("first thing") && recent.text.contains("older"))
        #expect(!recent.text.contains("ancient"))
        let rendered = MemoryInstructions(directory: directory).rendered()
        #expect(rendered.contains("untrusted notes"))
    }

    @Test func searchesAllFilesByKeyword() throws {
        let directory = try makeDirectory()
        try "- 2026-10-08 Prefers Zed over Xcode (source: chat)".write(to: directory.indexURL, atomically: true, encoding: .utf8)
        try "Deploy runbook\nUse blue-green deploys on Fridays".write(to: directory.topicsURL.appending(path: "deploys.md"), atomically: true, encoding: .utf8)
        let matches = directory.search("zed xcode")
        #expect(matches.map(\.path) == ["MEMORY.md"])
        #expect(matches.first?.line == 1)
        let deploy = directory.search("Fridays")
        #expect(deploy.map(\.path) == ["topics/deploys.md"])
        #expect(deploy.first?.line == 2)
        #expect(directory.search("nothing here").isEmpty)
    }

    @Test func memoryToolsOperateOnTheMemoryRoot() async throws {
        let directory = try makeDirectory()
        let tools = try MemoryTools(directory: directory)
        #expect(tools.read.name == "memory_read")
        _ = try await tools.note.call(arguments: .init(text: "learned a thing"))
        let searched = try await tools.search.call(arguments: .init(query: "learned"))
        #expect(searched.contains("notes/") && searched.contains("learned a thing"))
        let empty = try await tools.search.call(arguments: .init(query: "zzz"))
        #expect(empty.contains("No memory lines match"))
        _ = try await tools.read.call(arguments: .init(path: "MEMORY.md", offset: nil, limit: nil))
        _ = try await tools.write.call(arguments: .init(path: "MEMORY.md", content: "- fact one\n"))
        #expect(directory.renderIndex().text == "- fact one")
        await #expect(throws: WorkspaceError.self) {
            _ = try await tools.read.call(arguments: .init(path: "../outside", offset: nil, limit: nil))
        }
    }
}
