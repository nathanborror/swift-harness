import Foundation
import Harness
import FoundationModels

/// The built-in coding tool set for a workspace.
///
/// Read, edit, and write work on every platform. Shell exists on macOS only.
/// Wrap the tools with a `ToolGate` before giving them to a session.
public struct CodingTools: Sendable {
    public let context: CodingToolContext

    public init(workspace: Workspace, limits: CodingToolContext.Limits = CodingToolContext.Limits(), backgroundOutputs: URL? = nil) {
        self.context = CodingToolContext(workspace: workspace, limits: limits, backgroundOutputs: backgroundOutputs)
    }

    public init(context: CodingToolContext) {
        self.context = context
    }

    public var read: ReadTool { ReadTool(context: context.files) }
    public var edit: EditTool { EditTool(context: context.files) }
    public var write: WriteTool { WriteTool(context: context.files) }

    #if os(macOS)
    public var shell: ShellTool { ShellTool(context: context) }
    #endif

    /// Every tool available on this platform, each wrapped by the gate.
    public func gated(by gate: ToolGate) -> [any Tool] {
        var tools: [any Tool] = [gate.gate(read), gate.gate(edit), gate.gate(write)]
        #if os(macOS)
        tools.append(gate.gate(shell))
        if let processes = context.processes {
            tools.append(gate.gate(ProcessStatusTool(manager: processes)))
            tools.append(gate.gate(ProcessStopTool(manager: processes)))
        }
        #endif
        return tools
    }
}
