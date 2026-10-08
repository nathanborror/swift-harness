import Foundation
import FoundationModels
import Testing
@testable import Harness

@Suite struct EvalTests {
    @Test func decodesTaskJSONWithGraders() throws {
        let json = """
        {"name":"t","prompt":"do it","suite":"regression","setup":{"files":{"a.txt":"x"},"command":null},
         "graders":[{"type":"fileContains","path":"a.txt","text":"x"},{"type":"command","command":"true"},{"type":"judge","rubric":"good"},{"type":"maxToolCalls","count":3}],
         "timeoutSeconds":10}
        """
        let task = try JSONDecoder().decode(EvalTask.self, from: Data(json.utf8))
        #expect(task.graders == [.fileContains(path: "a.txt", text: "x"), .command(command: "true", exitCode: 0), .judge(rubric: "good", files: nil), .maxToolCalls(count: 3)])
        let encoded = try JSONEncoder().encode(task)
        #expect(try JSONDecoder().decode(EvalTask.self, from: encoded) == task)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Grader.self, from: Data(#"{"type":"nope"}"#.utf8))
        }
    }

    @Test func loadsTheRepositoryTasks() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "evals/tasks")
        let tasks = try EvalTask.loadAll(in: root)
        #expect(tasks.map(\.task.name) == ["answer-from-file", "fix-add", "leave-it-alone"])
        #expect(tasks.allSatisfy { !$0.task.graders.isEmpty })
    }

    private func makeRunner() -> EvalRunner {
        let output = FileManager.default.temporaryDirectory.appending(path: "harness-evals-\(UUID().uuidString)")
        return EvalRunner(outputRoot: output) { workspace, sessionRoot in
            AgentConfiguration(model: EchoModel(), workspace: workspace, sessionRoot: sessionRoot, policy: .allowAll, includesExplorer: false)
        }
    }

    @Test func runsTrialsInCleanWorkspacesAndGrades() async throws {
        let passing = EvalTask(
            name: "write-file",
            prompt: #"call write {"path":"out.txt","content":"hello"}"#,
            setup: .init(files: ["seed.txt": "seeded"]),
            graders: [.fileContains(path: "out.txt", text: "hello"), .fileExists(path: "seed.txt"), .toolCalled(name: "write"), .maxToolCalls(count: 1), .responseContains(text: "Wrote out.txt")]
        )
        let failing = EvalTask(
            name: "wrong-expectation",
            prompt: "just talk",
            graders: [.fileExists(path: "never.txt"), .toolNotCalled(name: "write")]
        )
        let report = try await makeRunner().run(tasks: [(passing, nil), (failing, nil)], trials: 2, model: "echo")
        #expect(report.trials.count == 4)
        let summaries = report.tasks
        #expect(summaries.map(\.task) == ["write-file", "wrong-expectation"])
        #expect(summaries[0].passes == 2 && summaries[0].trials == 2)
        #expect(summaries[1].passes == 0)
        let failure = try #require(report.trials.first { $0.task == "wrong-expectation" })
        #expect(failure.graders.map(\.passed) == [false, true])
        #expect(report.rendered().contains("2/4 trials passed"))
        #expect(report.rendered().contains("fileExists never.txt: missing"))

        let first = try #require(report.trials.first)
        #expect(FileManager.default.fileExists(atPath: first.workspacePath + "/out.txt"))
        #expect(first.sessionPath.map { FileManager.default.fileExists(atPath: $0 + "/events.jsonl") } == true)
        let workspaces = Set(report.trials.map(\.workspacePath))
        #expect(workspaces.count == 4, "every trial gets its own workspace")
        let runRoot = URL(fileURLWithPath: first.workspacePath).deletingLastPathComponent().deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: runRoot.appending(path: "report.json").path))
    }

    @Test func seedCopiesTaskFilesFolder() async throws {
        let taskDirectory = FileManager.default.temporaryDirectory.appending(path: "harness-task-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: taskDirectory.appending(path: "files/nested"), withIntermediateDirectories: true)
        try "deep".write(to: taskDirectory.appending(path: "files/nested/file.txt"), atomically: true, encoding: .utf8)
        let workspace = try Workspace(root: FileManager.default.temporaryDirectory.appending(path: "harness-ws-\(UUID().uuidString)"))
        try await EvalTask(name: "t", prompt: "p", graders: []).seed(workspace: workspace, taskDirectory: taskDirectory)
        #expect(try String(contentsOf: workspace.root.appending(path: "nested/file.txt"), encoding: .utf8) == "deep")
    }

    #if os(macOS)
    @Test func commandGraderRunsInTheWorkspace() async throws {
        let workspace = try Workspace(root: FileManager.default.temporaryDirectory.appending(path: "harness-ws-\(UUID().uuidString)"))
        try "x".write(to: workspace.root.appending(path: "present.txt"), atomically: true, encoding: .utf8)
        let result = AgentRunResult(response: "", directory: try SessionDirectory(root: workspace.root.appending(path: ".s")), usage: .init(input: .init(totalTokenCount: 0, cachedTokenCount: 0), output: .init(totalTokenCount: 0, reasoningTokenCount: 0)), toolCalls: [], duration: 0, transcript: Transcript())
        let context = GradingContext(task: EvalTask(name: "t", prompt: "p", graders: []), workspace: workspace, result: result, judge: nil)
        #expect(await Grader.command(command: "test -f present.txt", exitCode: 0).grade(context).passed == true)
        #expect(await Grader.command(command: "test -f absent.txt", exitCode: 0).grade(context).passed == false)
        #expect(await Grader.judge(rubric: "r", files: nil).grade(context).passed == nil)
    }
    #endif
}
