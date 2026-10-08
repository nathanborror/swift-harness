import Foundation

/// Jobs and run records on disk, as a JSON file and a JSONL log.
///
/// ```text
/// <root>/
///   jobs.json     every job with its state
///   runs.jsonl    one record per tick, including skips
///   inbox.jsonl   notices for the owner, from InboxDelivery
/// ```
public actor JobStore {
    public nonisolated let root: URL
    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public nonisolated var jobsURL: URL { root.appending(path: "jobs.json") }
    public nonisolated var runsURL: URL { root.appending(path: "runs.jsonl") }
    public nonisolated var inboxURL: URL { root.appending(path: "inbox.jsonl") }

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = Self.makeEncoder(pretty: true)
        self.encoder = encoder
        let decoder = Self.makeDecoder()
        self.decoder = decoder
        var jobs: [String: Job] = [:]
        var order: [String] = []
        if let data = try? Data(contentsOf: root.appending(path: "jobs.json")), let loaded = try? decoder.decode([Job].self, from: data) {
            for job in loaded {
                jobs[job.id] = job
                order.append(job.id)
            }
        }
        self.jobs = jobs
        self.order = order
    }

    public var all: [Job] { order.compactMap { jobs[$0] } }

    public func job(_ id: String) -> Job? { jobs[id] }

    public func upsert(_ job: Job) throws {
        if jobs[job.id] == nil { order.append(job.id) }
        jobs[job.id] = job
        try save()
    }

    public func remove(_ id: String) throws {
        jobs[id] = nil
        order.removeAll { $0 == id }
        try save()
    }

    public func update(_ id: String, _ change: (inout Job) -> Void) throws {
        guard var job = jobs[id] else { return }
        change(&job)
        jobs[id] = job
        try save()
    }

    private func save() throws {
        let data = try encoder.encode(all)
        try data.write(to: jobsURL, options: [.atomic])
    }

    public func record(_ run: JobRun) {
        append(run, to: runsURL)
    }

    public func runs(limit: Int = 100) -> [JobRun] {
        guard let data = try? Data(contentsOf: runsURL) else { return [] }
        let lines = data.split(separator: 0x0A)
        return lines.suffix(limit).compactMap { try? decoder.decode(JobRun.self, from: $0) }
    }

    /// ISO 8601 with fractional seconds, so dates survive a round trip exactly.
    static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func makeEncoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = (try? dateStyle.parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
        }
        return decoder
    }

    func append(_ value: some Encodable, to url: URL) {
        let lineEncoder = Self.makeEncoder(pretty: false)
        guard var data = try? lineEncoder.encode(value) else { return }
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
