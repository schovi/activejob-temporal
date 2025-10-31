# Architecture Decision Records (ADRs)

## What are ADRs?

Architecture Decision Records (ADRs) are documents that capture important architectural decisions made during the development of a project, along with their context and consequences. They serve as a historical record of why certain design choices were made, helping current and future maintainers understand the reasoning behind the codebase's structure.

## Why ADRs?

- **Preserve Context**: Capture the reasoning behind decisions when it's fresh, preventing knowledge loss over time
- **Onboard New Team Members**: Help new developers understand why the system works the way it does
- **Prevent Repeating History**: Document alternatives that were considered and rejected, avoiding revisiting settled questions
- **Enable Better Decision Making**: Understanding past decisions helps inform future architectural choices
- **Create Accountability**: Clear ownership and rationale for important technical decisions

## ADR Format

Each ADR follows a consistent structure:

1. **Title**: Short, descriptive name (e.g., "ADR 001: Structured JSON Logging")
2. **Status**: Current state of the decision
   - **Accepted**: Decision has been made and implemented
   - **Proposed**: Decision is under consideration
   - **Deprecated**: Decision is no longer valid but kept for historical context
   - **Superseded**: Replaced by a newer ADR (include reference)
3. **Context**: The problem, constraints, and requirements that led to this decision
4. **Decision**: What was decided and how it was implemented
5. **Consequences**: Both positive and negative outcomes of the decision
6. **Alternatives Considered**: Other approaches that were evaluated and why they were not chosen

## How to Create a New ADR

1. **Determine the Number**: Find the highest numbered ADR and increment by one (use zero-padding: 001, 002, etc.)

2. **Create the File**: Create a new file `docs/adr/XXX-short-title.md`

3. **Use the Template**:

```markdown
# ADR XXX: [Title]

## Status

[Accepted/Proposed/Deprecated/Superseded by ADR-YYY]

## Context

[2-3 paragraphs describing the problem, constraints, and requirements]

## Decision

[1-2 paragraphs describing what was decided]

[Code examples showing the implementation]

## Consequences

### Positive

- [Benefit 1]
- [Benefit 2]

### Negative

- [Drawback 1]
- [Drawback 2]

## Alternatives Considered

### [Alternative 1]

[Why it was not chosen]

### [Alternative 2]

[Why it was not chosen]
```

4. **Fill in Details**:
   - Be specific and technical in the Context section
   - Include code examples in the Decision section
   - Be honest about trade-offs in Consequences
   - Document why alternatives were rejected

5. **Review**: Ensure the ADR answers these questions:
   - What problem were we trying to solve?
   - What did we decide to do?
   - Why did we choose this approach over alternatives?
   - What are the implications of this decision?

## How to Supersede an ADR

When an architectural decision is replaced by a new approach:

1. Update the old ADR's status to `Superseded by ADR-XXX`
2. Create a new ADR documenting the new decision
3. In the new ADR's Context section, reference the previous ADR and explain why the change was necessary

## Resources

- [ADR GitHub Organization](https://adr.github.io/)
- [Joel Parker Henderson's ADR Templates](https://github.com/joelparkerhenderson/architecture-decision-record)
- [Michael Nygard's Original ADR Article](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions)

## Current ADRs

- [ADR 001: Structured JSON Logging](001-structured-logging.md)
- [ADR 002: ISO8601 Timestamps](002-iso8601-timestamps.md)
- [ADR 003: Adapter Helper Module](003-adapter-helper-module.md)
- [ADR 004: Idempotency Keys](004-idempotency-keys.md)
