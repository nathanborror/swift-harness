import Foundation

/// Work that ran past its time limit and was stopped, such as a scheduled job.
public struct TimeLimitError: Error, Sendable, LocalizedError, Equatable {
    public let seconds: Int

    public init(seconds: Int) {
        self.seconds = seconds
    }

    public var errorDescription: String? {
        "Did not complete within \(seconds) seconds and was stopped."
    }
}
