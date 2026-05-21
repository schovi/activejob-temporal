# Issue Triage Handoff

This handoff records how the GitHub Project issue queue is sorted and how to resume blocked work without repeating the triage audit.

Live project board: https://github.com/users/schovi/projects/3

State captured on 2026-05-21:

- Total project issue items: 59
- Done: 53
- Blocked: 6
- Open unblocked issues: 0
- Open issues missing Priority: 0
- Open issues missing Value: 0

The project board is the live source of truth for Status, Priority, Value, and Unblocker fields. This document is a durable repo handoff for the current blocked queue.

## Field Model

Status:

- `Done` means the issue has been implemented, verified, reviewed, documented, committed, pushed, and closed.
- `Blocked` means the issue is still valid, but waiting on an external dependency, credential, asset, upstream API, or product decision.
- `Ready`, `In progress`, and `In review` are for unblocked work that can move through implementation.
- `Backlog` is for valid work that is not currently next in priority order.

Priority:

- `P0` is urgent correctness, security, release, or CI breakage.
- `P1` is high-priority product or maintenance work with near-term user impact.
- `P2` is important work that should be handled when unblocked, but is not urgent.
- `P3` is optional polish, discovery, or low-impact documentation.

Value:

- `High` removes operational risk, supports dependency health, or unlocks recurring maintenance.
- `Medium` improves product capability, release reliability, or developer workflow.
- `Low` improves presentation, discoverability, or non-critical project hygiene.

Labels:

- `status: blocked` mirrors the project `Blocked` status so blocked items are visible outside the project board.
- Area labels identify the primary owner surface, such as `area: dependencies`, `area: workflows`, `area: docs`, `area: devops`, or `area: code-quality`.

The `Unblocker` project field should state the concrete event that must happen before implementation resumes.

## Current Blocked Queue

| Issue | Priority | Value | Area | Unblocker |
| --- | --- | --- | --- | --- |
| [#49 TASK.048 - Add Dependabot configuration for dependency updates](https://github.com/schovi/activejob-temporal/issues/49) | P2 | High | Dependencies | GitHub Dependabot Bundler updater supports Ruby 4+ and creates the first update PR. |
| [#23 TASK.041 - Add bulk enqueue API](https://github.com/schovi/activejob-temporal/issues/23) | P2 | Medium | Workflows | Temporal Ruby SDK/server exposes a documented single-RPC multi-start workflow API, or acceptance criteria change to allow a loop helper. |
| [#47 TASK.046 - Add semantic release automation](https://github.com/schovi/activejob-temporal/issues/47) | P2 | Medium | DevOps | Decide release policy and configure RubyGems trusted publishing or `GEM_HOST_API_KEY` with any approval gate. |
| [#33 TASK.028 - Add RubyDoc.info badge to README](https://github.com/schovi/activejob-temporal/issues/33) | P2 | Low | Docs | Publish activejob-temporal to RubyGems and wait for RubyDoc to generate docs. |
| [#48 TASK.047 - Add CodeClimate integration for maintainability tracking](https://github.com/schovi/activejob-temporal/issues/48) | P2 | Low | Code Quality | Add repository to Qlty/CodeClimate and provide generated maintainability badge/public score. |
| [#32 TASK.027 - Add video walkthrough / screencast](https://github.com/schovi/activejob-temporal/issues/32) | P3 | Low | Docs | Record and publish walkthrough video or provide a checked-in GIF/public URL for embedding. |

## Resume Checklist

Before taking a blocked issue:

1. Recheck the external prerequisite named in `Unblocker`.
2. Remove the `status: blocked` label only after the prerequisite exists.
3. Move the project Status from `Blocked` to `Ready`.
4. Implement against the issue acceptance criteria.
5. Validate locally under Ruby 4.0.3 only, for example `rvm 4.0.3 do bundle exec rubocop` and the relevant test target.
6. Get a separate-agent review before committing.
7. Commit and push.
8. Wait for GitHub Actions.
9. Comment with validation evidence and close the issue.

Do not install Ruby 3 or use Ruby 3 as a local validation fallback.
