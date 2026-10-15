# Issue tracker: GitHub

Issues and specs for this repo live as GitHub Issues in `sababif-bit/prodflow`. Use the authenticated `gh` CLI.
If `gh` is not on PATH (terminal opened before install), use `C:\Program Files\GitHub CLI\gh.exe`.
In Git Bash, pass `gh api` endpoints **without** a leading slash (`repos/...`), otherwise the path gets rewritten.

## Approval (overrides anything a skill says)

Every write to GitHub needs the user's explicit approval for that specific action: creating, editing,
commenting on, labelling or closing issues, adding sub-issue or blocking relationships, creating labels,
and creating or merging PRs. Always show the exact title, body, labels and relationships as a draft first.
Reading is fine without approval.

Approving a ticket breakdown is not approval to publish. Ask separately before creating each GitHub Issue
or adding issue relationships.

## Language

GitHub Issues (titles, bodies, acceptance criteria) are written in **English**, consistent with the existing
issues. Project documentation is written in German, except `docs/agents/*.md`, which is in English.

## Numbering

- Backlog numbers (`docs/backlog.md`, #1–#18) are **not** GitHub numbers. GitHub Issues and PRs share one
  number space. Always write "Backlog #N", "GitHub Issue #N" or "PR #N", never a bare `#N`.
- Issue titles start with `[Backlog #N]` when the work maps to a backlog item, e.g.
  `[Backlog #6] First deployment to EC2`.
- Implementation branches: `feature/<GitHub-issue-number>-<name>`, e.g. `feature/12-caddy-https`.

## Labels

- Do **not** apply `ready-for-agent` or any other triage label unless the user explicitly approves it.
- The labels defined in `docs/backlog.md` (`backend`, `frontend`, `devops`, `docs`, `stretch`) do not exist
  on GitHub yet. Apply them only after the user has approved creating them. Until then, publish issues
  without labels.

## Conventions

Verified with `gh` 2.102.0 (2026-10-15): sub-issues and issue dependencies are supported natively.

- **Create an issue**: `gh issue create --title "..." --body-file <file>` (body from a file in the session scratchpad).
- **Read an issue**: `gh issue view <number> --json number,title,body,labels,comments`.
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with `--label`/`--state` filters as needed.
- **Sub-issue of a parent**: `gh issue create --parent <parent> ...`, or afterwards
  `gh issue edit <parent> --add-sub-issue <child>` / `gh issue edit <child> --parent <parent>`.
- **Blocking edges** (native issue dependencies): `gh issue create --blocked-by <n>,<n> ...`, or afterwards
  `gh issue edit <child> --add-blocked-by <blocker>`. Publish blockers first so their numbers exist.
- **Inspect relationships** (read-only): `gh api repos/sababif-bit/prodflow/issues/<n> --jq '{sub_issues_summary, issue_dependencies_summary}'`.
- **Comment**: `gh issue comment <number> --body "..."`
- **Close**: `gh issue close <number> --comment "..."`

GitHub shares one number space across issues and PRs: resolve a bare number with `gh pr view <n>`, falling back to `gh issue view <n>`.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.)_

## When a skill says "publish to the issue tracker"

Draft the GitHub issue(s), show them to the user, and create them only after explicit approval.

## When a skill says "fetch the relevant ticket"

Read it as in **Read an issue** above.
