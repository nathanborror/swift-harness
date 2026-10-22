import Foundation
import Harness
import FoundationModels

/// A check on the outcome of a trial. Deterministic graders look at the
/// workspace and the transcript; the judge asks a model against a rubric.
public enum Grader: Codable, Sendable, Equatable {
    case fileContains(path: String, text: String)
    case fileNotContains(path: String, text: String)
    case fileEquals(path: String, text: String)
    case fileExists(path: String)
    case fileMissing(path: String)
    /// Runs a shell command in the workspace and passes when it exits with the expected code. macOS only.
    case command(command: String, exitCode: Int)
    case responseContains(text: String)
    case responseNotContains(text: String)
    case toolCalled(name: String)
    case toolNotCalled(name: String)
    case maxToolCalls(count: Int)
    /// A model reads the task, the response, and named files and returns pass, fail, or unknown.
    case judge(rubric: String, files: [String]?)

    private enum CodingKeys: String, CodingKey { case type, path, text, command, exitCode, name, count, rubric, files }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "fileContains": self = .fileContains(path: try container.decode(String.self, forKey: .path), text: try container.decode(String.self, forKey: .text))
        case "fileNotContains": self = .fileNotContains(path: try container.decode(String.self, forKey: .path), text: try container.decode(String.self, forKey: .text))
        case "fileEquals": self = .fileEquals(path: try container.decode(String.self, forKey: .path), text: try container.decode(String.self, forKey: .text))
        case "fileExists": self = .fileExists(path: try container.decode(String.self, forKey: .path))
        case "fileMissing": self = .fileMissing(path: try container.decode(String.self, forKey: .path))
        case "command": self = .command(command: try container.decode(String.self, forKey: .command), exitCode: try container.decodeIfPresent(Int.self, forKey: .exitCode) ?? 0)
        case "responseContains": self = .responseContains(text: try container.decode(String.self, forKey: .text))
        case "responseNotContains": self = .responseNotContains(text: try container.decode(String.self, forKey: .text))
        case "toolCalled": self = .toolCalled(name: try container.decode(String.self, forKey: .name))
        case "toolNotCalled": self = .toolNotCalled(name: try container.decode(String.self, forKey: .name))
        case "maxToolCalls": self = .maxToolCalls(count: try container.decode(Int.self, forKey: .count))
        case "judge": self = .judge(rubric: try container.decode(String.self, forKey: .rubric), files: try container.decodeIfPresent([String].self, forKey: .files))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown grader type \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fileContains(let path, let text): try container.encode("fileContains", forKey: .type); try container.encode(path, forKey: .path); try container.encode(text, forKey: .text)
        case .fileNotContains(let path, let text): try container.encode("fileNotContains", forKey: .type); try container.encode(path, forKey: .path); try container.encode(text, forKey: .text)
        case .fileEquals(let path, let text): try container.encode("fileEquals", forKey: .type); try container.encode(path, forKey: .path); try container.encode(text, forKey: .text)
        case .fileExists(let path): try container.encode("fileExists", forKey: .type); try container.encode(path, forKey: .path)
        case .fileMissing(let path): try container.encode("fileMissing", forKey: .type); try container.encode(path, forKey: .path)
        case .command(let command, let exitCode): try container.encode("command", forKey: .type); try container.encode(command, forKey: .command); try container.encode(exitCode, forKey: .exitCode)
        case .responseContains(let text): try container.encode("responseContains", forKey: .type); try container.encode(text, forKey: .text)
        case .responseNotContains(let text): try container.encode("responseNotContains", forKey: .type); try container.encode(text, forKey: .text)
        case .toolCalled(let name): try container.encode("toolCalled", forKey: .type); try container.encode(name, forKey: .name)
        case .toolNotCalled(let name): try container.encode("toolNotCalled", forKey: .type); try container.encode(name, forKey: .name)
        case .maxToolCalls(let count): try container.encode("maxToolCalls", forKey: .type); try container.encode(count, forKey: .count)
        case .judge(let rubric, let files): try container.encode("judge", forKey: .type); try container.encode(rubric, forKey: .rubric); try container.encodeIfPresent(files, forKey: .files)
        }
    }

    public var label: String {
        switch self {
        case .fileContains(let path, _): "fileContains \(path)"
        case .fileNotContains(let path, _): "fileNotContains \(path)"
        case .fileEquals(let path, _): "fileEquals \(path)"
        case .fileExists(let path): "fileExists \(path)"
        case .fileMissing(let path): "fileMissing \(path)"
        case .command(let command, _): "command \(command.prefix(40))"
        case .responseContains(let text): "responseContains \(text.prefix(30))"
        case .responseNotContains(let text): "responseNotContains \(text.prefix(30))"
        case .toolCalled(let name): "toolCalled \(name)"
        case .toolNotCalled(let name): "toolNotCalled \(name)"
        case .maxToolCalls(let count): "maxToolCalls \(count)"
        case .judge: "judge"
        }
    }
}

public struct GraderResult: Codable, Sendable, Equatable {
    public let grader: String
    /// Nil means the grader could not decide, which counts as a failure for the trial but is reported separately.
    public let passed: Bool?
    public let detail: String
}

/// What a grader may look at.
public struct GradingContext: Sendable {
    public let task: EvalTask
    public let workspace: Workspace
    public let result: AgentRunResult
    public let judge: (any LanguageModel)?
}

@Generable(description: "A verdict on whether a response meets a rubric.")
struct JudgeVerdict {
    @Guide(description: "pass when the rubric is clearly met, fail when it is clearly not, unknown when it cannot be decided from the evidence", .anyOf(["pass", "fail", "unknown"]))
    var verdict: String
    @Guide(description: "One sentence of reasoning")
    var reason: String
}

extension Grader {
    public func grade(_ context: GradingContext) async -> GraderResult {
        func file(_ path: String) -> String? {
            guard let url = try? context.workspace.url(for: path) else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        switch self {
        case .fileContains(let path, let text):
            guard let content = file(path) else { return GraderResult(grader: label, passed: false, detail: "file missing") }
            return GraderResult(grader: label, passed: content.contains(text), detail: content.contains(text) ? "found" : "text not found")
        case .fileNotContains(let path, let text):
            guard let content = file(path) else { return GraderResult(grader: label, passed: false, detail: "file missing") }
            return GraderResult(grader: label, passed: !content.contains(text), detail: content.contains(text) ? "text present" : "absent")
        case .fileEquals(let path, let text):
            guard let content = file(path) else { return GraderResult(grader: label, passed: false, detail: "file missing") }
            let equal = content.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines)
            return GraderResult(grader: label, passed: equal, detail: equal ? "equal" : "differs")
        case .fileExists(let path):
            let exists = (try? context.workspace.url(for: path)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            return GraderResult(grader: label, passed: exists, detail: exists ? "exists" : "missing")
        case .fileMissing(let path):
            let exists = (try? context.workspace.url(for: path)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            return GraderResult(grader: label, passed: !exists, detail: exists ? "present" : "missing")
        case .command(let command, let exitCode):
            #if os(macOS)
            guard let run = try? await ProcessRunner.run(command: command, directory: context.workspace.root, timeout: 120) else {
                return GraderResult(grader: label, passed: false, detail: "could not run")
            }
            let passed = !run.timedOut && Int(run.exitCode) == exitCode
            return GraderResult(grader: label, passed: passed, detail: "exit \(run.exitCode): \(run.output.suffix(200))")
            #else
            return GraderResult(grader: label, passed: nil, detail: "shell graders need macOS")
            #endif
        case .responseContains(let text):
            let found = context.result.response.localizedCaseInsensitiveContains(text)
            return GraderResult(grader: label, passed: found, detail: found ? "found" : "not in response")
        case .responseNotContains(let text):
            let found = context.result.response.localizedCaseInsensitiveContains(text)
            return GraderResult(grader: label, passed: !found, detail: found ? "present in response" : "absent")
        case .toolCalled(let name):
            let called = context.result.toolCalls.contains(name)
            return GraderResult(grader: label, passed: called, detail: called ? "called" : "never called; calls were \(context.result.toolCalls)")
        case .toolNotCalled(let name):
            let called = context.result.toolCalls.contains(name)
            return GraderResult(grader: label, passed: !called, detail: called ? "was called" : "not called")
        case .maxToolCalls(let count):
            let actual = context.result.toolCalls.count
            return GraderResult(grader: label, passed: actual <= count, detail: "\(actual) calls")
        case .judge(let rubric, let files):
            guard let judge = context.judge else { return GraderResult(grader: label, passed: nil, detail: "no judge model configured") }
            var evidence = "TASK:\n\(context.task.prompt)\n\nFINAL RESPONSE:\n\(context.result.response)"
            for path in files ?? [] {
                evidence += "\n\nFILE \(path):\n\(file(path) ?? "(missing)")"
            }
            let session = LanguageModelSession(model: judge, instructions: "You are a skeptical grader. Judge only from the evidence. Answer unknown when the evidence does not settle it.")
            do {
                let verdict = try await session.respond(to: "RUBRIC:\n\(rubric)\n\n\(evidence)", generating: JudgeVerdict.self).content
                let passed: Bool? = verdict.verdict == "pass" ? true : verdict.verdict == "fail" ? false : nil
                return GraderResult(grader: label, passed: passed, detail: verdict.reason)
            } catch {
                return GraderResult(grader: label, passed: nil, detail: "judge failed: \(error.localizedDescription)")
            }
        }
    }
}
