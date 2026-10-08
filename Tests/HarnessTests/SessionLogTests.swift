import Foundation
import FoundationModels
import Testing
@testable import Harness

@Suite struct SessionLogTests {
    @Test func appendsAndReadsBackRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "harness-sessions-\(UUID().uuidString)")
        let directory = try SessionDirectory(root: root)
        let log = try directory.makeLog()
        await log.record(.sessionStarted(sessionID: directory.sessionID, modelID: "m"))
        await log.record(.prompt(Transcript(entries: [.prompt(.init(id: "p", segments: [.text(.init(content: "hi"))]))])))
        await log.record(.note("done"))
        await log.close()

        let records = try SessionLog.read(url: directory.logURL)
        #expect(records.map(\.sequence) == [0, 1, 2])
        guard case .prompt(let transcript) = records[1].event, case .prompt(let prompt)? = transcript.first else {
            Issue.record("expected prompt record")
            return
        }
        #expect(prompt.id == "p")

        let reopened = try directory.makeLog()
        let record = await reopened.record(.note("later"))
        #expect(record.sequence == 3)
        await reopened.close()

        #expect(try SessionDirectory.list(in: root).map(\.sessionID) == [directory.sessionID])
    }

    @Test func savesAndLoadsTranscript() throws {
        let directory = try SessionDirectory(root: FileManager.default.temporaryDirectory.appending(path: "harness-sessions-\(UUID().uuidString)"))
        #expect(try directory.loadTranscript() == nil)
        let transcript = Transcript(entries: [
            .prompt(.init(id: "p", segments: [.text(.init(content: "hi"))])),
            .response(.init(id: "r", segments: [.text(.init(content: "hello"))])),
        ])
        try directory.saveTranscript(transcript)
        #expect(try directory.loadTranscript() == transcript)
    }

    @Test func sessionIDsSortByTime() {
        let earlier = SessionDirectory.makeSessionID(date: Date(timeIntervalSince1970: 1_000))
        let later = SessionDirectory.makeSessionID(date: Date(timeIntervalSince1970: 2_000_000))
        #expect(earlier < later)
    }
}
