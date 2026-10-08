import Foundation
import FoundationModels
import Testing
@testable import Harness

@Suite struct SkillsTests {
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "harness-skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSkill(_ root: URL, folder: String, frontmatter: String, body: String = "Do the thing.") throws {
        let dir = root.appending(path: folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\n\(frontmatter)\n---\n\n\(body)\n".write(to: dir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    }

    @Test func discoversAndParsesLeniently() throws {
        let root = try makeRoot()
        try writeSkill(root, folder: "pdf-processing", frontmatter: "name: pdf-processing\ndescription: Extract PDF text: forms, merges. Use when handling PDFs.\nlicense: MIT")
        try writeSkill(root, folder: "nameless", frontmatter: "description: \"Quoted: with colon\"")
        try writeSkill(root, folder: "broken", frontmatter: "name: broken")
        try FileManager.default.createDirectory(at: root.appending(path: "not-a-skill"), withIntermediateDirectories: true)

        let catalog = SkillCatalog.discover(in: [root])
        #expect(catalog.skills.map(\.name) == ["nameless", "pdf-processing"])
        let pdf = try #require(catalog.skill(named: "pdf-processing"))
        #expect(pdf.description == "Extract PDF text: forms, merges. Use when handling PDFs.")
        #expect(pdf.metadata["license"] == "MIT")
        #expect(try pdf.body() == "Do the thing.")
        #expect(catalog.skill(named: "nameless")?.description == "Quoted: with colon")
    }

    @Test func laterRootsOverrideEarlierOnes() throws {
        let home = try makeRoot()
        let project = try makeRoot()
        try writeSkill(home, folder: "deploy", frontmatter: "name: deploy\ndescription: home version")
        try writeSkill(project, folder: "deploy", frontmatter: "name: deploy\ndescription: project version")
        let catalog = SkillCatalog.discover(in: [home, project])
        #expect(catalog.skills.count == 1)
        #expect(catalog.skills.first?.description == "project version")
    }

    @Test func rendersUnderBudgetByShorteningThenDropping() throws {
        let root = try makeRoot()
        for index in 0..<6 {
            try writeSkill(root, folder: "skill-\(index)", frontmatter: "name: skill-\(index)\ndescription: " + String(repeating: "word ", count: 200))
        }
        let catalog = SkillCatalog.discover(in: [root])
        let full = catalog.rendered(budget: 100_000)
        #expect(full.contains("<available_skills>") && full.contains("<location>"))
        let shortened = catalog.rendered(budget: 2_500)
        #expect(shortened.count <= 2_500)
        #expect(shortened.contains("…"))
        let tiny = catalog.rendered(budget: 500)
        #expect(tiny.count < shortened.count)
        #expect(tiny.contains("<omitted"))
        #expect(SkillCatalog(skills: []).rendered() == "")
    }

    @Test func skillToolLoadsBodyOrListsNames() async throws {
        let root = try makeRoot()
        try writeSkill(root, folder: "haiku", frontmatter: "name: haiku\ndescription: Write haiku", body: "Three lines. Five, seven, five syllables.")
        let tool = SkillTool(catalog: SkillCatalog.discover(in: [root]))
        let loaded = try await tool.call(arguments: .init(name: "haiku"))
        #expect(loaded.contains("Skill haiku") && loaded.contains("Five, seven, five"))
        let missing = try await tool.call(arguments: .init(name: "nope"))
        #expect(missing.contains("Available skills: haiku"))
    }

    @Test func instructionFilesLoadRootToDirectory() throws {
        let root = try makeRoot()
        let workspace = try Workspace(root: root)
        try "Root rules".write(to: root.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appending(path: "pkg/sub"), withIntermediateDirectories: true)
        try "Package rules".write(to: root.appending(path: "pkg/AGENTS.md"), atomically: true, encoding: .utf8)
        let files = InstructionFiles.load(workspace: workspace, directory: "pkg/sub")
        #expect(files.files.map(\.text) == ["Root rules", "Package rules"])
        #expect(files.rendered().contains("## Instructions from AGENTS.md"))
        let capped = InstructionFiles.load(workspace: workspace, directory: "pkg/sub", maximumBytes: 12)
        #expect(capped.files.map(\.text) == ["Root rules"])
        #expect(capped.truncated)
        #expect(InstructionFiles.load(workspace: try Workspace(root: try makeRoot())).instructions == nil)
    }
}
