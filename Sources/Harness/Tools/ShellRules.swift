import Foundation

/// Permission rules for the shell tool.
///
/// A rule matches a pattern anywhere in the command string, so chained and
/// piped commands are covered. This is a tripwire, not a boundary: a command
/// can be written to slip past any pattern. The boundary is the App Sandbox
/// and the workspace. The rules exist so the obvious cases never need a person
/// and the irreversible ones always get one.
public enum ShellRules {
    /// Patterns no run may execute. Each pair is a case-insensitive regular expression and the reason returned to the model.
    public static let denyPatterns: [(pattern: String, reason: String)] = [
        (#"(^|[\s;&|])sudo\s"#, "privilege escalation is not allowed"),
        (#"(^|[\s;&|])su(\s|$)"#, "switching users is not allowed"),
        (#"(^|[\s;&|])rm\s+(-[a-zA-Z]*[rR][a-zA-Z]*\s+)+(-[a-zA-Z]+\s+)*(/|~|\$HOME|\*|\.\.)(\s|$|/)"#, "recursive deletion of the root, home, parent, or a wildcard is not allowed"),
        (#"(^|[\s;&|])(mkfs|diskutil\s+(erase|partition|reformat)|fdisk|newfs)"#, "disk formatting is not allowed"),
        (#"(^|[\s;&|])dd\s+.*of=/dev/"#, "writing raw device images is not allowed"),
        (#">\s*/dev/(disk|rdisk|sd|nvme)"#, "writing to a block device is not allowed"),
        (#":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#, "fork bombs are not allowed"),
        (#"(^|[\s;&|])(shutdown|reboot|halt|poweroff)(\s|$)"#, "power commands are not allowed"),
        (#"(^|[\s;&|])chmod\s+(-[a-zA-Z]*R[a-zA-Z]*\s+)+.*\s(/|~|\$HOME)(\s|$)"#, "recursive permission changes on the root or home are not allowed"),
        (#"(^|[\s;&|])chown\s+(-[a-zA-Z]*R[a-zA-Z]*\s+)+.*\s(/|~|\$HOME)(\s|$)"#, "recursive ownership changes on the root or home are not allowed"),
        (#"(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba|z|da)?sh(\s|$)"#, "piping a download into a shell is not allowed"),
        (#"(^|[\s;&|])git\s+push\b.*(--force\b|-f\b|--force-with-lease\b|\+[A-Za-z])"#, "force pushes are not allowed"),
        (#"(^|[\s;&|])(launchctl|systemctl)\s+(load|unload|bootstrap|enable|disable)"#, "changing system services is not allowed"),
        (#"(^|[\s;&|])history\s+-c"#, "clearing shell history is not allowed"),
        (#"(^|[\s;&|])crontab\s+(-r|-e)"#, "changing cron entries is not allowed"),
    ]

    /// Patterns that need a person: hard to reverse, or reaching outside the workspace.
    public static let askPatterns: [(pattern: String, reason: String)] = [
        (#"(^|[\s;&|])rm\s+(-[a-zA-Z]*[rR][a-zA-Z]*\s+)"#, "recursive deletion"),
        (#"(^|[\s;&|])git\s+push\b"#, "pushing to a remote"),
        (#"(^|[\s;&|])git\s+(reset\s+--hard|checkout\s+--\s|clean\s+-[a-zA-Z]*[fd]|restore\s+(--staged\s+)?\.|branch\s+-D|stash\s+drop|rebase\b)"#, "discarding or rewriting git work"),
        (#"(^|[\s;&|])(curl|wget|nc|ncat|ssh|scp|sftp|rsync|telnet|ftp)(\s|$)"#, "network access"),
        (#"(^|[\s;&|])(npm|pnpm|yarn)\s+publish\b"#, "publishing a package"),
        (#"(^|[\s;&|])cargo\s+publish\b"#, "publishing a crate"),
        (#"(^|[\s;&|])(pip3?|uv\s+pip|npm|pnpm|yarn|brew|gem|cargo)\s+(install|add|uninstall|remove)\b"#, "installing or removing software"),
        (#"(^|[\s;&|])(docker|podman|kubectl|terraform|aws|gcloud|az)(\s|$)"#, "infrastructure commands"),
        (#"(^|[\s;&|])(kill|killall|pkill)(\s|$)"#, "stopping processes"),
        (#"(^|[\s;&|])(defaults\s+write|osascript|open\s+-a)\b"#, "changing system settings or driving other apps"),
        (#"(^|[\s;&|])(mv|cp)\s+.*\s(/|~)(\s|$)"#, "moving or copying onto the root or home"),
        (#"(^|[\s;&|])(security|keychain|ssh-keygen)\b"#, "touching credentials"),
    ]

    public static func denyRules(toolName: String = "shell") -> [PermissionRule] {
        denyPatterns.map { entry in
            PermissionRule(name: "shell:deny:\(entry.reason)", decision: .deny, reason: entry.reason, matches: matcher(toolName: toolName, pattern: entry.pattern))
        }
    }

    public static func askRules(toolName: String = "shell") -> [PermissionRule] {
        askPatterns.map { entry in
            PermissionRule(name: "shell:ask:\(entry.reason)", decision: .ask, reason: entry.reason, matches: matcher(toolName: toolName, pattern: entry.pattern))
        }
    }

    /// Deny, then ask, then allow the rest of the shell.
    public static func rules(toolName: String = "shell") -> [PermissionRule] {
        denyRules(toolName: toolName) + askRules(toolName: toolName) + [.tool(toolName, .allow)]
    }

    static func matcher(toolName: String, pattern: String) -> @Sendable (ToolInvocation) -> Bool {
        // Regex is not Sendable; compiling per call is cheap for a command string.
        { invocation in
            guard invocation.toolName == toolName, let command = invocation.string("command"),
                let regex = try? Regex(pattern).ignoresCase()
            else { return false }
            return command.firstMatch(of: regex) != nil
        }
    }

    /// True when a pattern in the set matches the command. For tests and audits.
    public static func matches(_ command: String, pattern: String) -> Bool {
        guard let regex = try? Regex(pattern).ignoresCase() else { return false }
        return command.firstMatch(of: regex) != nil
    }
}

extension PermissionPolicy {
    /// For a coding agent a person is watching: the shell runs freely except for
    /// the dangerous patterns, which are denied, and the irreversible or
    /// network-reaching ones, which ask. Read-only tools are allowed; edits,
    /// writes, and anything destructive ask.
    public static let coding = PermissionPolicy(
        rules: ShellRules.rules() + [.readOnly(.allow), .destructive(.ask)],
        fallback: .ask
    )

    /// For an unattended run in a sandboxed workspace: like `coding`, but edits
    /// and writes are allowed and the ask patterns are denied, since nobody is
    /// there to answer.
    public static let unattended = PermissionPolicy(
        rules: ShellRules.denyRules() + ShellRules.askRules().map { PermissionRule(name: $0.name, decision: .deny, reason: $0.reason, matches: $0.matches) } + [
            .tool("shell", .allow), .tool("edit", .allow), .tool("write", .allow),
            .readOnly(.allow), .destructive(.deny, reason: "no one is present to confirm a destructive action"),
        ],
        fallback: .deny
    )
}
