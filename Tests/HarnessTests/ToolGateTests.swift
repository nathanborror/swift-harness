import Foundation
import FoundationModels
import Testing
@testable import Harness

@Generable
struct EchoArguments {
    var text: String
}

struct EchoTool: AnnotatedTool {
    let name = "echo"
    let description = "Echoes text"
    var annotations: ToolAnnotations = .readOnly
    func call(arguments: EchoArguments) async throws -> String { arguments.text }
}

struct FailingTool: Tool {
    struct Failure: Error, LocalizedError { var errorDescription: String? { "disk on fire" } }
    let name = "fail"
    let description = "Always fails"
    func call(arguments: EchoArguments) async throws -> String { throw Failure() }
}

struct DeleteTool: AnnotatedTool {
    let name = "delete"
    let description = "Deletes things"
    var annotations: ToolAnnotations = .destructive
    func call(arguments: EchoArguments) async throws -> String { "deleted \(arguments.text)" }
}

actor ScriptedPrompter: PermissionPrompter {
    private var responses: [PermissionResponse]
    private(set) var asked: [String] = []
    init(_ responses: [PermissionResponse]) { self.responses = responses }
    func confirm(_ invocation: ToolInvocation) async -> PermissionResponse {
        asked.append(invocation.toolName)
        return responses.isEmpty ? .deny : responses.removeFirst()
    }
}

@Suite struct ToolGateTests {
    private func makeLog() throws -> SessionLog {
        try SessionLog(url: FileManager.default.temporaryDirectory.appending(path: "harness-gate-\(UUID().uuidString)/events.jsonl"))
    }

    @Test func allowedToolRunsAndIsShaped() async throws {
        let log = try makeLog()
        let gate = ToolGate(policy: .default, shaper: ToolResultShaper(maximumCharacters: 10), log: log)
        let tool = gate.gate(EchoTool())
        #expect(tool.name == "echo")
        #expect(tool.parameters.name == EchoTool().parameters.name)
        let short = try await tool.call(arguments: EchoArguments(text: "hi"))
        #expect(short == "hi")
        let long = try await tool.call(arguments: EchoArguments(text: String(repeating: "x", count: 50)))
        #expect(long.contains("truncated"))
        let records = try SessionLog.read(url: log.url)
        let kinds = records.map { record -> String in
            switch record.event {
            case .permission(_, let decision, _, _, _): "permission:\(decision.rawValue)"
            case .toolResult(_, _, let truncated, _, _, _): "result:\(truncated)"
            default: "other"
            }
        }
        #expect(kinds == ["permission:allow", "result:false", "permission:allow", "result:true"])
    }

    @Test func failureBecomesToolOutputNotAThrow() async throws {
        let gate = ToolGate(policy: .allowAll)
        let output = try await gate.gate(FailingTool()).call(arguments: EchoArguments(text: "x"))
        #expect(output.hasPrefix("Error: fail failed: disk on fire"))
    }

    @Test func denialReturnsTextAndEscalatesAfterLimit() async throws {
        let gate = ToolGate(policy: .readOnlyOnly, limits: .init(maxConsecutiveDenials: 2, maxTotalDenials: 10))
        let tool = gate.gate(DeleteTool())
        let first = try await tool.call(arguments: EchoArguments(text: "a"))
        #expect(first.hasPrefix("Denied: delete was not run"))
        await #expect(throws: ToolGateError.self) {
            _ = try await tool.call(arguments: EchoArguments(text: "b"))
        }
    }

    @Test func askGoesToPrompterAndAllowAlwaysPersists() async throws {
        let prompter = ScriptedPrompter([.deny, .allowAlways])
        let gate = ToolGate(policy: .default, prompter: prompter)
        let tool = gate.gate(DeleteTool())
        let denied = try await tool.call(arguments: EchoArguments(text: "a"))
        #expect(denied.contains("declined"))
        let allowed = try await tool.call(arguments: EchoArguments(text: "b"))
        #expect(allowed == "deleted b")
        let again = try await tool.call(arguments: EchoArguments(text: "c"))
        #expect(again == "deleted c")
        #expect(await prompter.asked == ["delete", "delete"], "third call should not prompt after allow-always")
    }

    @Test func askWithoutPrompterDenies() async throws {
        let gate = ToolGate(policy: .default)
        let output = try await gate.gate(DeleteTool()).call(arguments: EchoArguments(text: "a"))
        #expect(output.contains("no one is available"))
    }
}
