import Foundation

/// One event from a `text/event-stream` body.
public struct ServerSentEvent: Sendable, Equatable {
    public var event: String?
    public var data: String
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// An incremental parser for the Server-Sent Events wire format.
///
/// Feed it one line at a time, without the trailing newline. It returns an
/// event when a blank line closes one. Comment lines, which start with a
/// colon, are dropped. OpenRouter sends `: OPENROUTER PROCESSING` as a
/// keepalive, so a parser that hands those to a JSON decoder breaks.
public struct ServerSentEventParser: Sendable {
    private var eventName: String?
    private var dataLines: [String] = []
    private var lastID: String?

    public init() {}

    public mutating func feed(_ line: String) -> ServerSentEvent? {
        if line.isEmpty {
            return flush()
        }
        if line.hasPrefix(":") {
            return nil
        }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = line[...]
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        case "id": lastID = String(value)
        default: break
        }
        return nil
    }

    /// Returns any event still buffered when the stream ends without a closing blank line.
    public mutating func flush() -> ServerSentEvent? {
        guard !dataLines.isEmpty || eventName != nil else { return nil }
        let event = ServerSentEvent(event: eventName, data: dataLines.joined(separator: "\n"), id: lastID)
        eventName = nil
        dataLines = []
        return event
    }
}
