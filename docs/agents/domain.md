# Domain Docs

How the engineering skills (`grill-with-docs`, `domain-modeling`, `to-tickets`, `tdd`) consume and
update ProdFlow's domain documentation. Layout: **single context**.
**This file overrides the skills' defaults**, in particular `domain-modeling`'s `ADR-FORMAT.md`.

## Before exploring, read these

- **`GLOSSARY.md`** at the repo root (if it exists).
- **`docs/architecture.md`**: the ADR table (#1–#15 so far), security/authorization matrix, data model,
  and runtime architecture (implemented local vs. proposed AWS).
- **`docs/backlog.md`**: backlog items and their acceptance criteria.

If `GLOSSARY.md` does not exist, proceed silently; don't suggest creating it upfront.

## ADRs: one system only

- ADRs are **rows in the table in `docs/architecture.md`** (`| # | Entscheidung | Begründung | Verworfen |`).
- New ADRs continue the numbering: **#16, #17, …** Always check the highest existing number first.
- **Never create `docs/adr/`** or any second ADR system or ADR file.
- Never rewrite historical ADRs. Mark them instead, e.g. `*(abgelöst durch #16)*` or
  `*(teilweise abgelöst durch #16 – …)*`, and mark proposals as `*(Vorschlag, noch nicht umgesetzt)*`.
- Offer an ADR only when the decision is hard to reverse, surprising without context, and the result
  of a real trade-off (the `domain-modeling` criteria).
- Every new or changed ADR is a file change and needs the user's approval.

### Status of the AWS deployment decision

**ADR #15 was a proposal and is now implemented and refined as ADR #17** (one EC2 instance, Docker Compose, PostgreSQL containers, Caddy for HTTPS;
RDS and Nginx are not planned). ADR numbers #16–#19 are assigned (Swagger demo client, AWS deployment, pull-based deployment, secrets strategy, see GitHub Issue #23)
and the frontend decisions are #20–#23; the next new ADR is #24. The table in `docs/architecture.md` is the source of truth.

## Glossary

- **`GLOSSARY.md`** lives at the repo root. Create it only when the first domain term has been agreed with
  the user, and only with approval.
- Written in **German**. Each entry names the German business term and the code name, e.g.
  `**Fertigungsauftrag** (Code: \`ProductionOrder\`)`, followed by a one- to two-sentence definition and
  `_Vermeiden_:` with discouraged synonyms.
- Domain terms only, no implementation details (format otherwise per `domain-modeling`'s `GLOSSARY-FORMAT.md`).

## Use the glossary's vocabulary

When your output names a domain concept (issue title, test name, hypothesis, refactor proposal), use the
term as defined in `GLOSSARY.md`. Code identifiers stay English; prose in project docs is German.
If a concept is missing from the glossary, note it for `domain-modeling` instead of inventing language.

## Flag ADR conflicts

If your output contradicts an existing ADR, say so explicitly rather than silently overriding:

> _Widerspricht ADR #15 (EC2 + Docker Compose), aber neu zu prüfen, weil …_

## Language

- Project documentation (`docs/*.md`, `GLOSSARY.md`, ADR rows, devlog) is written in **German**.
- Agent configuration (`CLAUDE.md`, `docs/agents/*.md`) is written in **English**.
- GitHub Issues and their acceptance criteria are written in **English** (see `docs/agents/issue-tracker.md`).
