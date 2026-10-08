import Foundation
import Testing
@testable import Harness

@Suite struct WorkspaceTests {
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "harness-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func resolvesRelativeAndAbsolutePathsInsideRoot() throws {
        let root = try makeRoot()
        let workspace = try Workspace(root: root)
        let relative = try workspace.url(for: "src/main.swift")
        #expect(relative.path.hasSuffix("/src/main.swift"))
        #expect(workspace.contains(relative))
        let absolute = try workspace.url(for: workspace.root.appending(path: "notes.md").path)
        #expect(workspace.relativePath(for: absolute) == "notes.md")
        #expect(workspace.relativePath(for: workspace.root) == ".")
    }

    @Test func rejectsTraversalAndForeignAbsolutePaths() throws {
        let workspace = try Workspace(root: try makeRoot())
        #expect(throws: WorkspaceError.self) { try workspace.url(for: "../outside.txt") }
        #expect(throws: WorkspaceError.self) { try workspace.url(for: "a/../../outside.txt") }
        #expect(throws: WorkspaceError.self) { try workspace.url(for: "/etc/passwd") }
        #expect(workspace.relativePath(for: URL(fileURLWithPath: "/etc/passwd")) == nil)
    }

    @Test func rejectsSymlinksThatEscape() throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        let workspace = try Workspace(root: root)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "escape"), withDestinationURL: outside)
        #expect(throws: WorkspaceError.self) { try workspace.url(for: "escape/secret.txt") }
        try FileManager.default.createDirectory(at: root.appending(path: "inner"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "alias"), withDestinationURL: root.appending(path: "inner"))
        let resolved = try workspace.url(for: "alias/file.txt")
        #expect(resolved.path.hasSuffix("/inner/file.txt"))
    }

    @Test func bookmarkRoundTrips() throws {
        let root = try makeRoot()
        let workspace = try Workspace(root: root)
        let bookmark = try workspace.bookmark()
        let reopened = try Workspace(bookmark: bookmark)
        #expect(reopened.root == workspace.root)
        #expect(reopened.refreshedBookmark == nil)
    }
}
