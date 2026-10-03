import Foundation

/// Template committed for a new project (§3.1). There are no default models: every `model:` is empty,
/// so the project starts as `unavailable: pipeline_invalid` until the human picks explicit models.
public enum PipelineTemplate {
    public static let defaultYAML = """
    version: 1
    board:
      max_waiting_human: 3
      bounce_limit_total: 5
      max_runs_per_task: 12
    workspace:
      warm_paths: []
    git:
      preset: standard
      allow: []
      deny: []
    suspicious_files:
      patterns: [".env*", "*.pem", "*.key", "*.p12", "id_rsa*", "id_ed25519*"]
      max_file_mb: 5
      allow: [".env.example"]
    stages:
      - id: backlog
        name: Backlog
        kind: queue
        on_success: dev
      - id: dev
        name: Dev
        kind: agent
        wip: 3
        agent:
          harness: cursor-cli
          model:            # required: explicit id from `cursor-agent --list-models`; auto is not allowed
          skill: .kaban/skills/dev.md
          permissions: write
          mcp: [kaban]
        git: { extend: [rebase], when: return_reason == merge_conflict }
        retry: { max_attempts: 3, backoff: [30s, 2m] }
        timeouts: { stall: 10m, wall: 60m }
        on_success: test
      - id: test
        name: Test
        kind: agent
        wip: 2
        agent:
          model:
          skill: .kaban/skills/test.md
        returns_to: [{ stage: dev, limit: 3 }]
        on_success: ai-review
      - id: ai-review
        name: AI Review
        kind: agent
        wip: 2
        agent:
          model:
          skill: .kaban/skills/review.md
          permissions: read-only
        returns_to: [{ stage: dev, limit: 2 }]
        on_success: human-review
      - id: human-review
        name: Human Review
        kind: human
        wip: 5
        on_success: merge
      - id: merge
        name: Merge
        kind: merge
        on_conflict: { stage: dev, limit: 2 }
        on_success: done
      - id: done
        name: Done
        kind: terminal

    """
}
