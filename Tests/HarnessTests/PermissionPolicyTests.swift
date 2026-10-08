import Foundation
import FoundationModels
import Testing
@testable import Harness

@Suite struct PermissionPolicyTests {
    private func invocation(_ tool: String, args: String = "{}", annotations: ToolAnnotations? = nil) throws -> ToolInvocation {
        ToolInvocation(toolName: tool, arguments: try GeneratedContent(json: args), annotations: annotations)
    }

    @Test func firstMatchingRuleWins() throws {
        let policy = PermissionPolicy(rules: [
            .tool("shell", where: "command", satisfies: { $0.hasPrefix("rm ") }, .deny, reason: "no deletes"),
            .tool("shell", .allow),
            .readOnly(.allow),
        ], fallback: .ask)
        #expect(try policy.evaluate(invocation("shell", args: #"{"command":"rm -rf x"}"#)).decision == .deny)
        #expect(try policy.evaluate(invocation("shell", args: #"{"command":"ls"}"#)).decision == .allow)
        #expect(try policy.evaluate(invocation("read", annotations: .readOnly)).decision == .allow)
        #expect(try policy.evaluate(invocation("write", annotations: .mutating)).decision == .ask)
        #expect(try policy.evaluate(invocation("shell", args: #"{"command":"rm -rf x"}"#)).reason == "no deletes")
    }

    @Test func defaultPolicyAllowsReadOnlyAndAsksOtherwise() throws {
        #expect(try PermissionPolicy.default.evaluate(invocation("read", annotations: .readOnly)).decision == .allow)
        #expect(try PermissionPolicy.default.evaluate(invocation("edit", annotations: .mutating)).decision == .ask)
        #expect(try PermissionPolicy.default.evaluate(invocation("mystery")).decision == .ask)
        #expect(try PermissionPolicy.readOnlyOnly.evaluate(invocation("edit")).decision == .deny)
    }
}
