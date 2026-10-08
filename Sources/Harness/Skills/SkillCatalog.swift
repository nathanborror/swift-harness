import Foundation

/// One skill: a folder with a `SKILL.md` whose frontmatter names and describes it.
public struct Skill: Sendable, Equatable, Hashable {
    public let name: String
    public let description: String
    /// The `SKILL.md` file.
    public let location: URL
    /// Extra frontmatter fields, as written.
    public let metadata: [String: String]

    public var directory: URL { location.deletingLastPathComponent() }

    public init(name: String, description: String, location: URL, metadata: [String: String] = [:]) {
        self.name = name
        self.description = description
        self.location = location
        self.metadata = metadata
    }

    /// The instructions below the frontmatter.
    public func body() throws -> String {
        let text = try String(contentsOf: location, encoding: .utf8)
        return SkillCatalog.parseFrontmatter(text).body
    }
}

/// Discovers skills and renders the catalog the model sees.
///
/// Scan only folders you trust. A repository's skills are instructions to the
/// agent, and loading them is a trust decision the app makes, not this type.
public struct SkillCatalog: Sendable, Equatable {
    public let skills: [Skill]

    public init(skills: [Skill]) {
        self.skills = skills
    }

    /// Scans each root for immediate subdirectories containing `SKILL.md`.
    /// Later roots win on a name collision, so list the most specific root last.
    public static func discover(in roots: [URL]) -> SkillCatalog {
        var byName: [String: Skill] = [:]
        var order: [String] = []
        for root in roots {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            for name in names.sorted() {
                let location = root.appending(path: name).appending(path: "SKILL.md")
                guard let skill = load(location) else { continue }
                if byName[skill.name] == nil { order.append(skill.name) }
                byName[skill.name] = skill
            }
        }
        return SkillCatalog(skills: order.compactMap { byName[$0] })
    }

    /// The cross-client convention plus a per-app folder.
    public static func conventionalRoots(workspace: Workspace?, appSkills: URL? = nil) -> [URL] {
        var roots: [URL] = []
        if let appSkills { roots.append(appSkills) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots.append(home.appending(path: ".agents/skills"))
        if let workspace { roots.append(workspace.root.appending(path: ".agents/skills")) }
        return roots
    }

    public func skill(named name: String) -> Skill? {
        skills.first { $0.name == name }
    }

    /// Reads and validates one `SKILL.md`. Skips a file without a description.
    static func load(_ location: URL) -> Skill? {
        guard let text = try? String(contentsOf: location, encoding: .utf8) else { return nil }
        let parsed = parseFrontmatter(text)
        guard let description = parsed.fields["description"], !description.isEmpty else { return nil }
        let folder = location.deletingLastPathComponent().lastPathComponent
        let name = (parsed.fields["name"]?.isEmpty == false ? parsed.fields["name"]! : folder)
        let metadata = parsed.fields.filter { $0.key != "name" && $0.key != "description" }
        return Skill(name: String(name.prefix(64)), description: String(description.prefix(1_024)), location: location, metadata: metadata)
    }

    /// A lenient reader for the YAML subset skills use: `key: value` lines
    /// between `---` fences. A description containing a colon still parses.
    static func parseFrontmatter(_ text: String) -> (fields: [String: String], body: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([:], text)
        }
        lines.removeFirst()
        var fields: [String: String] = [:]
        var lastKey: String?
        while !lines.isEmpty {
            let line = lines.removeFirst()
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let open = value.first, (open == "\"" || open == "'"), value.last == open {
                    value = String(value.dropFirst().dropLast())
                }
                fields[key] = value
                lastKey = key
            } else if let lastKey, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Continuation of a folded multi-line value.
                fields[lastKey, default: ""] += (fields[lastKey]?.isEmpty == false ? " " : "") + line.trimmingCharacters(in: .whitespaces)
            }
        }
        return (fields, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Rendering

    /// The catalog block for the instructions, kept under a character budget.
    /// Descriptions are shortened first; skills are dropped only when names
    /// alone would not fit, and the block says so.
    public func rendered(budget: Int = 8_000) -> String {
        guard !skills.isEmpty else { return "" }
        let header = """
            ## Skills
            The following skills provide specialized instructions for specific tasks. When a task matches a skill's description, call the skill tool with its name to load the instructions before proceeding. Resolve relative paths a skill mentions against its directory.
            <available_skills>
            """
        let footer = "</available_skills>"
        var descriptionLimit = 1_024
        while descriptionLimit >= 80 {
            let entries = skills.map { entry($0, descriptionLimit: descriptionLimit) }
            let text = ([header] + entries + [footer]).joined(separator: "\n")
            if text.count <= budget { return text }
            descriptionLimit /= 2
        }
        var entries: [String] = []
        var omitted = 0
        var size = header.count + footer.count + 60
        for skill in skills {
            let line = "<skill><name>\(skill.name)</name></skill>"
            if size + line.count + 1 > budget { omitted += 1; continue }
            entries.append(line)
            size += line.count + 1
        }
        if omitted > 0 { entries.append("<omitted count=\"\(omitted)\">Catalog over budget; descriptions dropped.</omitted>") }
        return ([header] + entries + [footer]).joined(separator: "\n")
    }

    private func entry(_ skill: Skill, descriptionLimit: Int) -> String {
        var description = skill.description
        if description.count > descriptionLimit { description = String(description.prefix(descriptionLimit - 1)) + "…" }
        return """
            <skill>
            <name>\(Self.escape(skill.name))</name>
            <description>\(Self.escape(description))</description>
            <location>\(Self.escape(skill.location.path))</location>
            </skill>
            """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
