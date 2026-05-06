# CLAUDE.md

> Configuration file used by Claude Code (the AI coding assistant) during this
> project. Auto-loaded into the model's context at session start. Not part of
> the deliverable — included in the repo so the development workflow is
> reproducible. Reviewers can skip this file; the project overview also lives
> in `README.md`.

## Project overview

This is a 2-hour performance task for the Charter School Growth Fund (CSGF) Analytics Engineer role. We load Oklahoma 2024–25 assessment + enrollment data into DuckDB, build a dbt model at school×subject grain (% proficient grades 3–8 for ELA and Math, with a suppression flag), analyze suppression impact, and write a non-technical performance summary.

Stack mirrors CSGF's: DuckDB + dbt for modeling, Python for validation, plain markdown for the deliverable writeup (Quarto skipped to honor the time budget).

## Strategy

- **Two raw tables** loaded by a standalone Python script (`prep/load_raw.py`) before dbt runs. CSV via DuckDB's native reader; XLSX via pandas (DuckDB's spatial extension is flaky on Windows).
- **dbt 3-tier layering** (materialization defaults set in `dbt_project.yml`):
  - `staging/` — 1:1 with sources, rename + cast only, no filters, no joins, no derived metrics. Views.
  - `intermediate/` — joins, filters, unpivot, derived flags. Views.
  - `marts/` — final aggregations. Tables (the deliverable).
- **Source name** in `sources.yml` is `oklahoma` — the single place state origin is documented; model names stay clean.
- **Compound join key** in `stg_enrollment`: `"District Code" || LPAD(CAST("School Code" AS VARCHAR), 3, '0')`. School Code alone isn't unique across districts; this matches the assessment file's `FullCode`. Verify the LPAD width before relying on it.
- **Aggregation**: enrollment-weighted proficiency across grades 3–8, not simple average. School-level rates should reflect actual student counts. October enrollment is a proxy for tested-n.
- **Suppression**: defined relative to the *enrollment universe*. A grade counts as missing if (a) the school had enrollment > 0 in it but no assessment row OR (b) `IndicatorValue`/`Advanced`/`Proficient` is blank. Four tiers: Complete / Partial / Severely Suppressed / No Data.
- **% proficient** = `Advanced + Proficient` columns (NOT the `IndicatorValue` column, which is Oklahoma's custom A–F score and is misleading here).
- **Tests**: `dbt_utils.unique_combination_of_columns` on the mart grain `[school_code, subject]` and on intermediate `[school_code, subject, grade]`. `accepted_range` on `pct_proficient`. `accepted_values` on `subject` and `suppression_flag`.

## Direction

What "good" looks like for the reviewer:
- Clean dbt patterns (3-tier, tests where they catch bugs, schema docs)
- Sound aggregation choice with reasoning documented
- Suppression treated as both *structural* (missing rows, the harder-to-spot kind) and *explicit* (blank values)
- Recommendation framing that acknowledges suppression's impact varies by question type (state averages vs. school comparisons vs. small-school/subgroup analysis), backed by the state-level delta number
- Honest AI-use notes with one specific override

Cut order under time pressure: NICE items first, then drop the intermediate grain test, then narrative gets terser.

---

## Behavioral guidelines

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
