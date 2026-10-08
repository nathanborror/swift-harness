import Foundation
import FoundationModels

/// Loads a skill's instructions as tool output, which keeps the cached
/// prefix intact. The model picks the skill from the catalog in the
/// instructions; the person can also invoke one by name through the app.
public struct SkillTool: AnnotatedTool {
    @Generable(description: "Load a skill's instructions.")
    public struct Arguments {
        @Guide(description: "The skill name exactly as listed in available_skills")
        public var name: String
    }

    public let name = "skill"
    public let description = "Loads the full instructions for a skill listed in available_skills. Call it before starting a task that matches a skill's description."
    public let annotations: ToolAnnotations = .readOnly
    let catalog: SkillCatalog

    public init(catalog: SkillCatalog) {
        self.catalog = catalog
    }

    public func call(arguments: Arguments) async throws -> String {
        guard let skill = catalog.skill(named: arguments.name) else {
            let names = catalog.skills.map(\.name).joined(separator: ", ")
            return "No skill named \"\(arguments.name)\". Available skills: \(names.isEmpty ? "none" : names)."
        }
        let body = try skill.body()
        return "Skill \(skill.name) (directory: \(skill.directory.path))\n\n\(body)"
    }
}

/// The skill catalog and its loading tool, as dynamic instructions.
public struct SkillsInstructions: DynamicInstructions, Sendable {
    public let catalog: SkillCatalog
    public let budget: Int

    public init(catalog: SkillCatalog, budget: Int = 8_000) {
        self.catalog = catalog
        self.budget = budget
    }

    public var body: some DynamicInstructions {
        if !catalog.skills.isEmpty {
            Instructions(catalog.rendered(budget: budget))
            SkillTool(catalog: catalog)
        }
    }
}
