import Foundation

/// A notice for the owner: a result worth seeing, or a failure alert.
public struct JobNotice: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case result
        case alert
    }

    public var id: String
    public var jobID: String
    public var jobName: String
    public var kind: Kind
    public var text: String
    public var createdAt: Date
    public var read: Bool

    public init(jobID: String, jobName: String, kind: Kind, text: String, createdAt: Date = Date()) {
        self.id = UUID().uuidString
        self.jobID = jobID
        self.jobName = jobName
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.read = false
    }
}

/// Where notices go. Failures and results travel the same way but are marked apart.
public protocol JobDelivery: Sendable {
    func deliver(_ notice: JobNotice) async
}

/// Appends notices to `inbox.jsonl` in the job store, so nothing is lost in a
/// chat scrollback. An app lists the inbox and marks notices read.
public struct InboxDelivery: JobDelivery {
    public let store: JobStore

    public init(store: JobStore) {
        self.store = store
    }

    public func deliver(_ notice: JobNotice) async {
        await store.append(notice, to: store.inboxURL)
    }

    public func notices() -> [JobNotice] {
        guard let data = try? Data(contentsOf: store.inboxURL) else { return [] }
        let decoder = JobStore.makeDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(JobNotice.self, from: $0) }
    }
}
