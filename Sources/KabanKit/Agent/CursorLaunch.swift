import Foundation
import KabanProtocol

public enum CursorLaunchFailure: Error, Equatable {
    case modelRequired
}

public struct CursorPromptParts: Equatable, Sendable {
    public var skill: String
    public var title: String
    public var body: String
    public var handoff: String?
    public var additions: [PromptAddition]
    public var grants: [String]
    public init(skill: String, title: String, body: String, handoff: String? = nil, additions: [PromptAddition] = [], grants: [String] = []) {
        self.skill = skill
        self.title = title
        self.body = body
        self.handoff = handoff
        self.additions = additions
        self.grants = grants
    }
}

public struct CursorLaunchPlan: Equatable, Sendable {
    public var arguments: [String]
    public var prompt: String
    /// Non-nil only when resume was requested with a session id the caller already verified.
    public var sessionId: String?
    public var environment: [String: String]
    public var redactedEnvironment: [String: String] {
        Dictionary(uniqueKeysWithValues: environment.map { key, value in
            let upper = key.uppercased()
            let secret = ["KEY", "TOKEN", "SECRET", "PASSWORD"].contains { upper.contains($0) }
            return (key, secret ? "<redacted>" : value)
        })
    }
}

public enum CursorLaunch {
    public static func render(_ parts: CursorPromptParts) -> String {
        var sections: [String] = []
        let skill = parts.skill.trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append(skill.isEmpty ? "Skill file was not loaded." : "Skill:\n\(skill)")
        sections.append("Task: \(parts.title)\n\(parts.body)")
        if let handoff = parts.handoff?.trimmingCharacters(in: .whitespacesAndNewlines), !handoff.isEmpty {
            sections.append("Handoff:\n\(handoff)")
        }
        if !parts.additions.isEmpty {
            sections.append(parts.additions.map(renderAddition).joined(separator: "\n"))
        }
        if !parts.grants.isEmpty {
            sections.append("Grants:\n" + parts.grants.joined(separator: "\n"))
        }
        sections.append("Finish only with a final MCP call: complete_stage, return_to_stage, or request_human. A process exit is not completion.")
        return sections.joined(separator: "\n\n")
    }

    /// `--approve-mcps` is left for the MCP preflight. Resume without a verified id starts a new session.
    public static func plan(model: String, readOnly: Bool, resumeRequested: Bool, verifiedSessionId: String?, prompt: String, environment: [String: String]) throws -> CursorLaunchPlan {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PipelineValidator.hasExplicitModel(ModelID(rawValue: trimmed)) else { throw CursorLaunchFailure.modelRequired }
        var arguments = ["-p", "--output-format", "stream-json", "--model", trimmed]
        if !readOnly { arguments.append("--force") }
        let session = verifiedSessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resume = resumeRequested ? session.flatMap { $0.isEmpty ? nil : $0 } : nil
        if let resume { arguments.append(contentsOf: ["--resume", resume]) }
        arguments.append(prompt)
        return CursorLaunchPlan(arguments: arguments, prompt: prompt, sessionId: resume, environment: environment)
    }

    private static func renderAddition(_ addition: PromptAddition) -> String {
        switch addition {
        case .gateOutput(let text): return "Gate output:\n\(text)"
        case .finishReminder: return "The previous run ended without a final MCP call."
        case .humanAnswer(let text): return "Human answer:\n\(text)"
        case .humanComments(let text): return "Human comments:\n\(text)"
        case .returnIssues(let stage, let issues): return "Returned from \(stage.rawValue):\n" + issues.joined(separator: "\n")
        case .mergeConflict(let files): return "Merge conflict:\n" + files.joined(separator: "\n")
        case .readOnlyViolation: return "The read-only stage left changes."
        }
    }
}
