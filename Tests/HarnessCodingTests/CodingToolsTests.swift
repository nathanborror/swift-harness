import Foundation
import FoundationModels
import Testing
@testable import Harness
@testable import HarnessCoding

@Suite struct CodingToolsTests {
    private func makeTools() throws -> (CodingTools, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "harness-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = try Workspace(root: root)
        return (CodingTools(workspace: workspace, limits: .init(readLines: 3, readBytes: 100, shellTimeout: 5)), workspace.root)
    }

    @Test func readPagesAndListsDirectories() async throws {
        let (tools, root) = try makeTools()
        try "one\ntwo\nthree\nfour\nfive".write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appending(path: "sub"), withIntermediateDirectories: true)

        let first = try await tools.read.call(arguments: .init(path: "f.txt", offset: nil, limit: nil))
        #expect(first == "one\ntwo\nthree\n\n(Showing lines 1-3 of 5. Use offset=4 to continue.)")
        let rest = try await tools.read.call(arguments: .init(path: "f.txt", offset: 4, limit: nil))
        #expect(rest == "four\nfive")
        let past = try await tools.read.call(arguments: .init(path: "f.txt", offset: 9, limit: nil))
        #expect(past.contains("past the end"))
        let listing = try await tools.read.call(arguments: .init(path: ".", offset: nil, limit: nil))
        #expect(listing == "f.txt\nsub/")
    }

    @Test func readSuggestsSimilarNames() async throws {
        let (tools, root) = try makeTools()
        try "x".write(to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        await #expect(throws: FileToolError.notFound(path: "Packag.swift", suggestions: [root.appending(path: "Package.swift").path])) {
            _ = try await tools.read.call(arguments: .init(path: "Packag.swift", offset: nil, limit: nil))
        }
    }

    @Test func editRequiresReadAndMatchesExactlyOnce() async throws {
        let (tools, root) = try makeTools()
        let file = root.appending(path: "a.txt")
        try "hello world\nhello again\n".write(to: file, atomically: true, encoding: .utf8)

        await #expect(throws: FileToolError.notRead(path: "a.txt")) {
            _ = try await tools.edit.call(arguments: .init(path: "a.txt", edits: [.init(oldText: "hello", newText: "bye")], replaceAll: nil))
        }
        _ = try await tools.read.call(arguments: .init(path: "a.txt", offset: nil, limit: nil))
        await #expect(throws: FileToolError.textNotUnique(path: "a.txt", index: 0, occurrences: 2)) {
            _ = try await tools.edit.call(arguments: .init(path: "a.txt", edits: [.init(oldText: "hello", newText: "bye")], replaceAll: nil))
        }
        await #expect(throws: FileToolError.textNotFound(path: "a.txt", index: 0)) {
            _ = try await tools.edit.call(arguments: .init(path: "a.txt", edits: [.init(oldText: "nope", newText: "bye")], replaceAll: nil))
        }
        let summary = try await tools.edit.call(arguments: .init(path: "a.txt", edits: [.init(oldText: "hello world", newText: "bye world"), .init(oldText: "again", newText: "once more")], replaceAll: nil))
        #expect(summary == "Edited a.txt: 2 replacements.")
        #expect(try String(contentsOf: file, encoding: .utf8) == "bye world\nhello once more\n")

        let all = try await tools.edit.call(arguments: .init(path: "a.txt", edits: [.init(oldText: "o", newText: "0")], replaceAll: true))
        #expect(all.hasPrefix("Edited a.txt: "))
        #expect(try String(contentsOf: file, encoding: .utf8) == "bye w0rld\nhell0 0nce m0re\n")
    }

    @Test func editRefusesFilesChangedSinceRead() async throws {
        let (tools, root) = try makeTools()
        let file = root.appending(path: "b.txt")
        try "v1".write(to: file, atomically: true, encoding: .utf8)
        _ = try await tools.read.call(arguments: .init(path: "b.txt", offset: nil, limit: nil))
        try "v2 changed".write(to: file, atomically: true, encoding: .utf8)
        await #expect(throws: FileToolError.changedSinceRead(path: "b.txt")) {
            _ = try await tools.edit.call(arguments: .init(path: "b.txt", edits: [.init(oldText: "v2", newText: "v3")], replaceAll: nil))
        }
    }

    @Test func editPreservesCRLFAndBOM() async throws {
        let (tools, root) = try makeTools()
        let file = root.appending(path: "c.txt")
        try "\u{FEFF}line one\r\nline two\r\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await tools.read.call(arguments: .init(path: "c.txt", offset: nil, limit: nil))
        _ = try await tools.edit.call(arguments: .init(path: "c.txt", edits: [.init(oldText: "line one\nline two", newText: "first\nsecond")], replaceAll: nil))
        #expect(try Data(contentsOf: file) == Data([0xEF, 0xBB, 0xBF]) + Data("first\r\nsecond\r\n".utf8))
    }

    @Test func writeCreatesParentsAndGuardsOverwrites() async throws {
        let (tools, root) = try makeTools()
        let created = try await tools.write.call(arguments: .init(path: "deep/dir/new.txt", content: "fresh"))
        #expect(created == "Wrote deep/dir/new.txt (5 bytes).")
        #expect(try String(contentsOf: root.appending(path: "deep/dir/new.txt"), encoding: .utf8) == "fresh")

        try "old".write(to: root.appending(path: "existing.txt"), atomically: true, encoding: .utf8)
        await #expect(throws: FileToolError.notRead(path: "existing.txt")) {
            _ = try await tools.write.call(arguments: .init(path: "existing.txt", content: "clobber"))
        }
        _ = try await tools.read.call(arguments: .init(path: "existing.txt", offset: nil, limit: nil))
        let overwrote = try await tools.write.call(arguments: .init(path: "existing.txt", content: "new"))
        #expect(overwrote.hasPrefix("Overwrote existing.txt"))
        let afterWrite = try await tools.edit.call(arguments: .init(path: "existing.txt", edits: [.init(oldText: "new", newText: "newer")], replaceAll: nil))
        #expect(afterWrite.hasPrefix("Edited"), "a write counts as a read for the next edit")
    }

    @Test func toolsRejectPathsOutsideTheWorkspace() async throws {
        let (tools, _) = try makeTools()
        await #expect(throws: WorkspaceError.self) {
            _ = try await tools.read.call(arguments: .init(path: "../escape.txt", offset: nil, limit: nil))
        }
        await #expect(throws: WorkspaceError.self) {
            _ = try await tools.write.call(arguments: .init(path: "/tmp/escape.txt", content: "x"))
        }
    }

    #if os(macOS)
    @Test func shellRunsInWorkspaceAndReportsExitCodes() async throws {
        let (tools, root) = try makeTools()
        let pwd = try await tools.shell.call(arguments: .init(command: "pwd; printf 'err\\n' 1>&2; echo done", workdir: nil, timeoutSeconds: nil, background: nil))
        #expect(pwd.contains(root.lastPathComponent))
        #expect(pwd.contains("err"))
        #expect(pwd.hasSuffix("done"))
        let failing = try await tools.shell.call(arguments: .init(command: "echo bad; exit 3", workdir: nil, timeoutSeconds: nil, background: nil))
        #expect(failing == "bad\n\n[exit code 3]")
        let empty = try await tools.shell.call(arguments: .init(command: "true", workdir: nil, timeoutSeconds: nil, background: nil))
        #expect(empty == "(no output)")
        try FileManager.default.createDirectory(at: root.appending(path: "nested"), withIntermediateDirectories: true)
        let nested = try await tools.shell.call(arguments: .init(command: "basename \"$PWD\"", workdir: "nested", timeoutSeconds: nil, background: nil))
        #expect(nested == "nested")
        await #expect(throws: WorkspaceError.self) {
            _ = try await tools.shell.call(arguments: .init(command: "pwd", workdir: "..", timeoutSeconds: nil, background: nil))
        }
    }

    @Test func shellKillsAtTimeout() async throws {
        let (tools, _) = try makeTools()
        let started = Date()
        let output = try await tools.shell.call(arguments: .init(command: "echo start; sleep 30; echo never", workdir: nil, timeoutSeconds: 1, background: nil))
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(output.hasPrefix("start"))
        #expect(output.contains("did not complete within 1 seconds"))
        #expect(!output.contains("never"))
    }
    #endif
}
