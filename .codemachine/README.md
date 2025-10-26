# .codemachine - Agent Orchestrator Configuration

This directory contains the complete orchestration configuration for the activejob-temporal gem development using `.codemachine`, an intelligent agent orchestrator.

## Quick Start for Agents

**⚠️ IMPORTANT - ENVIRONMENT SETUP REQUIRED**

Before implementing any tasks, ensure the development environment is properly configured:

1. **Read the initialization guide**: [`INITIALIZATION.md`](./INITIALIZATION.md)
2. **Run environment setup**:
   ```bash
   cd /Users/schovi/work/activejob-temporal
   bundle install
   ```
3. **Verify Temporal gem is installed**:
   ```bash
   bundle exec ruby -e "require 'temporalio/client'; puts 'Ready!'"
   ```

## Directory Structure

```
.codemachine/
├── README.md                          ← You are here
├── INITIALIZATION.md                  ← Environment setup guide
├── template.json                      ← Workflow execution state
├── agents/                            ← Agent configurations
│   └── agents-config.json            ← Agent registry (currently empty)
├── prompts/
│   └── context.md                     ← Current task briefing (task-specific)
├── artifacts/                         ← Generated documentation & plans
│   ├── architecture/                 ← System design (C4 diagrams, API specs)
│   │   ├── 01_Context_and_Drivers.md
│   │   ├── 02_Architecture_Overview.md
│   │   ├── 03_System_Structure_and_Data.md
│   │   ├── 04_Behavior_and_Communication.md
│   │   ├── 05_Operational_Architecture.md
│   │   ├── 06_Rationale_and_Future.md
│   │   └── architecture_manifest.json ← Section reference index
│   ├── plan/                         ← Implementation roadmap
│   │   ├── 01_Plan_Overview_and_Setup.md
│   │   ├── 02_Iteration_I1.md to I5.md  ← 5 iterations, 50+ tasks
│   │   ├── 03_Verification_and_Glossary.md
│   │   └── plan_manifest.json        ← Section reference index
│   └── tasks/                        ← Task definitions
│       ├── tasks_I1.json to tasks_I5.json ← JSON task specs
│       └── tasks_manifest.json       ← Iteration → file mapping
├── inputs/                            ← Original requirements
│   └── specifications.md             ← v0.1 implementation spec
├── memory/                            ← Runtime state
│   └── behavior.json                 ← Orchestrator behavior flag
└── fallback/                          ← Fallback configurations (empty)
```

## Key Gem Update

### Previous Setup (Deprecated ❌)

The project previously used a **vendored copy** of the Temporal Ruby SDK:
- Location: `vendor/temporalio-sdk/`
- Gem name: `temporalio-sdk`
- Status: Temporary workaround (now removed)

### Current Setup (Active ✅)

The project now uses the **official, published `temporalio` gem**:
- Source: https://rubygems.org/gems/temporalio
- Gem name: `temporalio` (NOT `temporalio-sdk`)
- Installation: Standard `bundle install`
- Version: >= 1.0 (GA October 2025+)
- Status: Production-ready

### Updated Files

The following have been updated to reference the real gem:
- ✅ `Gemfile` - Removed vendor path conditional
- ✅ `activejob-temporal.gemspec` - Updated dependency name
- ✅ `Gemfile.lock` - Removed vendor entries
- ✅ `vendor/temporalio-sdk/` - **Deleted**
- ✅ `.codemachine/` - All references updated
- ✅ `lib/activejob/temporal/client.rb` - Requires correct path: `temporalio/client`

**All require statements in the codebase are already correct** and compatible with the real gem.

## Documentation Hierarchy

### 1. For Task Understanding: `prompts/context.md`
- Task-specific briefing generated for each iteration
- Contains: task details, architectural context, code references, implementation tips
- Auto-generated but can be customized per task

### 2. For System Design: `artifacts/architecture/`
- **01_Context_and_Drivers.md** - Vision, objectives, assumptions, requirements
- **02_Architecture_Overview.md** - Style, tech stack, trade-off rationale
- **03_System_Structure_and_Data.md** - C4 diagrams, component structure, data model
- **04_Behavior_and_Communication.md** - API design, sequence diagrams, interaction flows
- **05_Operational_Architecture.md** - Cross-cutting concerns, deployment, security
- **06_Rationale_and_Future.md** - Design decisions, risks, evolution roadmap

### 3. For Implementation Roadmap: `artifacts/plan/`
- **01_Plan_Overview_and_Setup.md** - Project goals, structure, tech stack overview
- **02_Iteration_I1-I5.md** - Detailed plans for 5 iterations (25+ pages total)
- **03_Verification_and_Glossary.md** - Testing strategy, CI/CD, quality gates, glossary

### 4. For Task Details: `artifacts/tasks/`
- **tasks_I1.json through tasks_I5.json** - 50+ task definitions with:
  - Acceptance criteria (testable)
  - Dependencies and parallelization hints
  - Inputs and deliverables
  - Agent type hints (SetupAgent, BackendAgent, DocumentationAgent, etc.)

### 5. For Raw Spec: `inputs/specifications.md`
- Original v0.1 implementation specification
- Reference material for behavioral requirements
- Define scope, APIs, error semantics, security

## Workflow Execution

### Current State
```json
{
  "activeTemplate": "codemachine.workflow.js",
  "completedSteps": [0, 1, 2, 3, 4, 8],
  "notCompletedSteps": [6, 11],
  "resumeFromLastStep": true
}
```

The workflow can resume from the last incomplete step. Check `template.json` for current progress.

### How to Use This Orchestration

1. **Agent picks a task** from `artifacts/tasks/tasks_IN.json`
2. **System generates context** in `prompts/context.md` (task-specific)
3. **Agent reads**:
   - Current task details from JSON
   - Architectural context from `artifacts/architecture/`
   - Implementation guidance and code patterns
   - Test examples and edge cases
4. **Agent implements** the task in the codebase
5. **Agent verifies**:
   - All tests pass: `bundle exec rake spec`
   - Code quality: `bundle exec rake rubocop`
   - Acceptance criteria met
6. **System marks task complete** in the task JSON
7. **Workflow continues** to next task (or iteration)

## Important Notes for Implementation

### Temporal SDK References

All references in the codebase use the **official `temporalio` gem**:

```ruby
# Correct way (this is what the codebase does):
require "temporalio/client"          # ✅ From official gem
require "temporalio/workflow"        # ✅ From official gem

# Wrong (don't do this):
require "temporalio-sdk/client"      # ❌ Old vendor path
require "temporalio/sdk"             # ❌ Wrong gem name
```

### Testing with Temporalio

Tests should:
1. Mock `Temporalio::Client` for unit tests
2. Use Temporal test server for integration tests
3. See `spec/unit/client_spec.rb` for mocking patterns
4. See `spec/integration/` for test server setup (if present)

### Configuration Access

Configuration is accessed via `ActiveJob::Temporal.config`:

```ruby
# In lib/activejob/temporal/adapter.rb or similar:
target = ActiveJob::Temporal.config.target
namespace = ActiveJob::Temporal.config.namespace
timeout = ActiveJob::Temporal.config.default_activity_timeout
```

See `lib/activejob/temporal.rb` for the full config interface.

## Artifact Manifests

The system uses **anchor-based manifests** for fine-grained document referencing:

### Architecture Manifest (`architecture_manifest.json`)
Maps sections to files: `key` → `{ "file": "...", "anchor": "..." }`

Example:
```json
{
  "api-style": {
    "file": "04_Behavior_and_Communication.md",
    "anchor": "api-style"
  }
}
```

### Plan Manifest (`plan_manifest.json`)
Maps iteration/task sections: `key` → location

### Task Manifest (`tasks_manifest.json`)
Maps iterations to files: `{ "I1": "tasks_I1.json", ... }`

## CI/CD Expectations

The codebase includes:
- **Linting**: `bundle exec rake rubocop`
- **Testing**: `bundle exec rake spec`
- **Documentation**: `bundle exec rake yard`

All must pass before merging.

## Next Steps

1. **Setup environment** following [`INITIALIZATION.md`](./INITIALIZATION.md)
2. **Read architecture** starting with [`artifacts/architecture/01_Context_and_Drivers.md`](./artifacts/architecture/01_Context_and_Drivers.md)
3. **Review plan** in [`artifacts/plan/01_Plan_Overview_and_Setup.md`](./artifacts/plan/01_Plan_Overview_and_Setup.md)
4. **Pick a task** from the current iteration in `artifacts/plan/02_Iteration_IN.md`
5. **Load task details** from `artifacts/tasks/tasks_IN.json`
6. **Implement** using guidance in task-specific `prompts/context.md`
7. **Verify** with tests and linting
8. **Move to next task** when complete

## Troubleshooting

### "cannot load such file -- temporalio"
- Run: `bundle install`
- Check: `bundle show temporalio`

### "vendor/temporalio-sdk not found"
- Your Gemfile is outdated. Update it to remove the vendor path check.
- Delete `Gemfile.lock` and run `bundle install`

### Tests failing due to missing SDK
- Ensure `bundle install` completed successfully
- Verify: `bundle exec ruby -e "require 'temporalio/client'"`

## Questions?

Refer to:
- **Task briefing**: `prompts/context.md` (auto-generated, task-specific)
- **Architecture**: `artifacts/architecture/` (comprehensive system design)
- **Planning**: `artifacts/plan/` (implementation roadmap)
- **Environment**: [`INITIALIZATION.md`](./INITIALIZATION.md) (setup guide)
- **Specification**: `inputs/specifications.md` (raw requirements)

For agent orchestration questions, refer to the `.codemachine` documentation.
