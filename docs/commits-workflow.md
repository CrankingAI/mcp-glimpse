# Commits and workflow

How we move work through the repo. These are the working defaults; the imperative
summary lives in [AGENTS.md](../AGENTS.md) under Workflow.

## Conventional Commits

Every commit message follows the [Conventional Commits](https://www.conventionalcommits.org)
spec: a `type(scope): subject` line, with the body and footers as needed.

```text
feat(api): add /version endpoint
fix(web): correct og:image dimensions to 1200x630
chore(deps): bump pinned @google/design.md
docs(observability): note round() requirement in workbooks
```

Common types: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `build`, `ci`.
Breaking changes use `!` after the type/scope or a `BREAKING CHANGE:` footer. The
subject is terse, imperative, lowercase, no trailing period.

## Plan before you implement

For any non-trivial change, state the plan first, then implement. A short plan
catches the wrong approach before code exists. Trivial one-liners skip the
ceremony — judgment, not bureaucracy.

## Terse replies

No end-of-turn recaps, no "I hope this helps," no restating what the diff already
shows. Say what changed and what (if anything) needs a decision, then stop. The
code and the commit message carry the rest.

## Small PRs

Keep pull requests small and single-purpose — one logical change per PR. Small PRs
review faster, revert cleanly, and bisect well. Split unrelated work rather than
bundling it. A PR's description states the intent and the verification done; let
the diff speak for the detail.

## Ship and fix as needed

The standing principle: **prefer shipping and iterating over withholding until
perfect.** Get a coherent, verified change out, then refine in follow-ups. This
applies to the kit itself and to every repo seeded from it. "Done enough to ship,
then fix as needed" beats an indefinitely-polished branch that never lands.
