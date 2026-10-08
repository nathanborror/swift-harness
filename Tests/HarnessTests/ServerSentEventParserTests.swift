import Testing
@testable import Harness

@Suite struct ServerSentEventParserTests {
    @Test func parsesDataEventsAndSkipsComments() {
        var parser = ServerSentEventParser()
        #expect(parser.feed(": OPENROUTER PROCESSING") == nil)
        #expect(parser.feed("data: {\"a\":1}") == nil)
        let event = parser.feed("")
        #expect(event == ServerSentEvent(data: "{\"a\":1}"))
        #expect(parser.feed("") == nil)
    }

    @Test func joinsMultiLineDataAndReadsEventName() {
        var parser = ServerSentEventParser()
        _ = parser.feed("event: ping")
        _ = parser.feed("data: one")
        _ = parser.feed("data:two")
        let event = parser.feed("")
        #expect(event == ServerSentEvent(event: "ping", data: "one\ntwo"))
    }

    @Test func flushReturnsPendingEventAtEndOfStream() {
        var parser = ServerSentEventParser()
        _ = parser.feed("data: [DONE]")
        #expect(parser.flush()?.data == "[DONE]")
        #expect(parser.flush() == nil)
    }
}
