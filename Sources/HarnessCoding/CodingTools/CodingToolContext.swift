import Foundation
import Harness

/// Shared state for the coding tools: the file tools' context, the shell's
/// time limits, and background processes.
public final class CodingToolContext: Sendable {
    public struct Limits: Sendable, Equatable {
        /// Lines returned by one read when no limit is given.
        public var readLines: Int
        /// Bytes returned by one read at most.
        public var readBytes: Int
        /// Shell time limit when the model gives none.
        public var shellTimeout: TimeInterval
        /// The longest time limit the model may ask for.
        public var shellTimeoutMaximum: TimeInterval

        public init(readLines: Int = 2_000, readBytes: Int = 50_000, shellTimeout: TimeInterval = 120, shellTimeoutMaximum: TimeInterval = 600) {
            self.readLines = readLines
            self.readBytes = readBytes
            self.shellTimeout = shellTimeout
            self.shellTimeoutMaximum = shellTimeoutMaximum
        }
    }

    /// What read, edit, and write share, including the record of what was read.
    public let files: FileToolContext
    public let limits: Limits
    #if os(macOS)
    /// Long-running commands, when the shell tool may run in the background.
    public let processes: BackgroundProcessManager?
    #endif

    public var workspace: Workspace { files.workspace }

    public init(workspace: Workspace, limits: Limits = Limits(), backgroundOutputs: URL? = nil) {
        self.files = FileToolContext(workspace: workspace, limits: FileToolContext.Limits(readLines: limits.readLines, readBytes: limits.readBytes))
        self.limits = limits
        #if os(macOS)
        self.processes = backgroundOutputs.map { BackgroundProcessManager(outputsDirectory: $0) }
        #endif
    }
}
