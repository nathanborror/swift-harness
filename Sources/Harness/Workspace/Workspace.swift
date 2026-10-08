import Foundation

public enum WorkspaceError: Error, Sendable, LocalizedError, Equatable {
    case outsideWorkspace(path: String)
    case staleBookmark
    case accessDenied(path: String)

    public var errorDescription: String? {
        switch self {
        case .outsideWorkspace(let path): "Path is outside the workspace: \(path)"
        case .staleBookmark: "The workspace bookmark is stale and must be recreated from a user-chosen folder."
        case .accessDenied(let path): "The system denied access to the workspace folder: \(path)"
        }
    }
}

/// A folder the agent is allowed to work in.
///
/// On a sandboxed app this is a folder the person chose, held as a
/// security-scoped bookmark. Every tool path is resolved through `url(for:)`,
/// which rejects anything that escapes the root, including through symlinks.
/// Access to the scoped folder starts when the workspace is created and ends
/// when it is released.
public final class Workspace: Sendable {
    /// The root folder, with symlinks resolved.
    public let root: URL
    /// A refreshed bookmark when the one used to open the workspace was stale. Persist it.
    public let refreshedBookmark: Data?
    private let holdsSecurityScope: Bool

    /// Opens a folder the process can already reach, such as one in the app container or a test directory.
    public init(root: URL) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.refreshedBookmark = nil
        self.holdsSecurityScope = false
        try Self.ensureDirectory(self.root)
    }

    /// Opens a folder from a security-scoped bookmark created with `bookmark()`.
    public init(bookmark: Data) throws {
        var isStale = false
        #if os(macOS)
        let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
        #else
        let resolved = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        #endif
        guard resolved.startAccessingSecurityScopedResource() else {
            throw WorkspaceError.accessDenied(path: resolved.path)
        }
        self.holdsSecurityScope = true
        self.root = resolved.standardizedFileURL.resolvingSymlinksInPath()
        self.refreshedBookmark = isStale ? try Self.makeBookmark(for: resolved) : nil
        try Self.ensureDirectory(self.root)
    }

    /// Opens a folder the person just chose in a file picker. The picker already
    /// started security-scoped access, so this only records the root.
    public convenience init(userSelected url: URL) throws {
        try self.init(root: url)
    }

    deinit {
        if holdsSecurityScope {
            root.stopAccessingSecurityScopedResource()
        }
    }

    /// A bookmark that reopens this folder in a later launch.
    public func bookmark() throws -> Data {
        try Self.makeBookmark(for: root)
    }

    /// Resolves a path the model supplied. Relative paths are taken from the
    /// root. Absolute paths must already lie inside it.
    public func url(for path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let candidate: URL
        if expanded.hasPrefix("/") {
            candidate = URL(fileURLWithPath: expanded)
        } else {
            candidate = root.appending(path: expanded)
        }
        let standardized = candidate.standardizedFileURL
        guard Self.isInside(root, standardized) else {
            throw WorkspaceError.outsideWorkspace(path: path)
        }
        // Resolve symlinks on the existing part of the path so a link inside the
        // workspace cannot point out of it.
        let resolved = Self.resolvingExistingSymlinks(standardized)
        guard Self.isInside(root, resolved) else {
            throw WorkspaceError.outsideWorkspace(path: path)
        }
        return resolved
    }

    /// A path relative to the root, or nil when the URL is outside it.
    public func relativePath(for url: URL) -> String? {
        let resolved = Self.resolvingExistingSymlinks(url.standardizedFileURL)
        guard Self.isInside(root, resolved) else { return nil }
        let rootPath = root.path
        let path = resolved.path
        if path == rootPath { return "." }
        return String(path.dropFirst(rootPath.count + 1))
    }

    public func contains(_ url: URL) -> Bool {
        relativePath(for: url) != nil
    }

    // MARK: Helpers

    private static func isInside(_ root: URL, _ url: URL) -> Bool {
        let rootPath = root.path
        let path = url.path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private static func resolvingExistingSymlinks(_ url: URL) -> URL {
        var existing = url
        var trailing: [String] = []
        let manager = FileManager.default
        while !manager.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            trailing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in trailing { resolved.append(path: component) }
        return resolved.standardizedFileURL
    }

    private static func makeBookmark(for url: URL) throws -> Data {
        #if os(macOS)
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    private static func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw WorkspaceError.accessDenied(path: url.path) }
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
