import Foundation
import Testing
@testable import Harness

@Suite struct ToolResultShaperTests {
    @Test func leavesSmallOutputAlone() {
        let shaper = ToolResultShaper(maximumCharacters: 100)
        let result = shaper.shape("hello", toolName: "t", callID: "1")
        #expect(result.text == "hello")
        #expect(!result.truncated)
        #expect(result.offloadedTo == nil)
    }

    @Test func replacesEmptyOutput() {
        let result = ToolResultShaper().shape("", toolName: "t", callID: "1")
        #expect(result.text == "(no output)")
    }

    @Test func truncatesAndOffloads() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "harness-shaper-\(UUID().uuidString)")
        let shaper = ToolResultShaper(maximumCharacters: 20, strategy: .headAndTail, outputsDirectory: dir)
        let input = String(repeating: "a", count: 50) + String(repeating: "z", count: 50)
        let result = shaper.shape(input, toolName: "shell", callID: "call/1")
        #expect(result.truncated)
        #expect(result.originalCharacters == 100)
        #expect(result.text.hasPrefix("aaaaaaaaaa"))
        #expect(result.text.contains("zzzzzzzzzz"))
        #expect(result.text.contains("80 characters truncated"))
        let offloaded = try #require(result.offloadedTo)
        #expect(result.text.contains(offloaded.path))
        #expect(try String(contentsOf: offloaded, encoding: .utf8) == input)
        #expect(offloaded.lastPathComponent == "shell-call_1.txt")
    }

    @Test func tailStrategyKeepsTheEnd() {
        let shaper = ToolResultShaper(maximumCharacters: 5, strategy: .tail)
        let result = shaper.shape("0123456789", toolName: "t", callID: "1")
        #expect(result.text.hasPrefix("56789"))
    }
}
