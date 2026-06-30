<!--
================================================================================
 Salesforce Quality Gate — Pull Request Template
================================================================================
 The "Salesforce Quality Gate Orchestrator" workflow parses this body to decide
 the Apex test execution level for the validation run. Resolution order:
   1. Applied PR label  (test-level:<Level>)        — highest precedence
   2. Checked checkbox   in the block below
   3. RunLocalTests      (safe default)              — lowest precedence

 IMPORTANT: Check EXACTLY ONE box. Keep the inner `- [ ] <Level>` code-span
 intact — the parser matches on it literally. To select a level, change its
 OUTER box from "- [ ]" to "- [x]".
================================================================================
-->

## PR Description

<!-- Describe the change. Note whether static analysis (PMD / Code Analyzer) passed. -->

### Salesforce Pipeline Quality Gate Override

Please select **EXACTLY ONE** test execution level for this validation run:

- [ ] `- [ ] NoTestRun` (Sandboxes and Scratch Orgs only)
- [ ] `- [ ] RunSpecifiedTests` (Executes only target classes listed below)
- [ ] `- [ ] RunLocalTests` (Standard default regression validation)
- [ ] `- [ ] RunAllTestsInOrg` (Full compilation and managed package test run)

**Specified Target Apex Classes (Mandatory for RunSpecifiedTests):**
```text
ExampleBatchEngineTest, ExampleTriggerTest
```

<!--
 Header-size guardrail: the comma/space-separated list above must stay under
 8 KB. If you need dozens of classes, group them into an Apex Test Suite and
 use RunLocalTests/RunAllTestsInOrg, or split the change into smaller PRs.
-->

---

### Review Checklist
- [ ] Static code analysis (PMD / Salesforce Code Analyzer) verified
- [ ] Target environment confirmed (sandbox vs production policy honored)
- [ ] Security Review requested / approved
- [ ] Lead Architect sign-off (required for `main` / `release/**`)
