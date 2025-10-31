# Code Refinement Task

The previous code submission did not pass verification. You must fix the following issues and resubmit your work.

---

## Original Task Description

Enhance inline YARD documentation across all implementation files to match the comprehensiveness of Version 1 while maintaining Version 2's clarity. Focus on: (1) Add @raise annotations for all exception types that can be raised by each method; (2) Add @example blocks for complex methods showing realistic usage with input and output; (3) Add @note sections for important behaviors and caveats; (4) Add @see references to related methods and Temporal SDK documentation URLs; (5) Ensure all public methods have complete YARD docs; (6) Add module/class-level documentation explaining purpose and design patterns. Target files: adapter.rb, cancel.rb, payload.rb, workflows/aj_workflow.rb, activities/aj_runner_activity.rb. Generate YARD documentation with yard doc and verify it builds without warnings.

---

## Issues Detected

*   **Insufficient @raise annotations:** The code currently has only 28 @raise annotations, but the acceptance criteria requires at least 30. You need to add 2 more @raise annotations to meet the requirement.

---

## Best Approach to Fix

You MUST add 2 more `@raise` annotations to methods that can raise exceptions. Review the following files for missing exception documentation:

1. **lib/activejob/temporal/retry_mapper.rb**:
   - The `discard_exception?` method (lines ~120-140) can raise exceptions if the job class is invalid or if exception matching fails. Add `@raise [ArgumentError]` or `@raise [NameError]` documentation.
   - The `select_retry_entry` method can raise exceptions during handler introspection.

2. **lib/activejob/temporal/search_attributes.rb**:
   - The `for` method already has one @raise, but the `extract_tenant_id` method (private) could document ArgumentError if the argument doesn't respond correctly.

3. **lib/activejob/temporal/client.rb**:
   - The `build` method can raise additional Temporal SDK exceptions beyond the documented ones. Consider adding `@raise [Temporalio::Error]` for general Temporal SDK errors or `@raise [OpenSSL::SSL::SSLError]` for TLS-related failures.

4. **lib/activejob/temporal/payload.rb**:
   - The `deserialize_args` method can raise `GlobalID::RecordNotFound` if an ActiveRecord object was deleted between enqueue and execution. Add this as a @raise annotation.

**Recommended additions:**
- Add `@raise [GlobalID::RecordNotFound]` to `Payload.deserialize_args` method
- Add `@raise [Temporalio::Error]` or `@raise [OpenSSL::SSL::SSLError]` to `Client.build` method

These are the most accurate and relevant exceptions to document, as they represent real failure modes users will encounter.
