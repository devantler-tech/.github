# `repository-rulesets/` — repo-scoped rulesets as code

Declarative management of individual repositories' **`RepositoryRuleset`** resources as
Crossplane managed resources, via
[provider-upjet-github](https://github.com/crossplane-contrib/provider-upjet-github).
Org-wide `OrganizationRuleset` resources live in the sibling
[`../organization-rulesets/`](../organization-rulesets/), whose
[`README.md`](../organization-rulesets/README.md) documents the shared **Observe-first**
adoption convention and the provider importability matrix.

**One `RepositoryRuleset` per file**, named `<verb>-on-<repo>.yaml` so the rule and its
target repo are clear from the filename. external-name = `<repo>:<id>`.

| File | Repo | Ruleset | Policy |
|---|---|---|---|
| `restrict-deletions-on-ksail.yaml` | `ksail` | Restrict deletions (scoped to `refs/heads/benchmark-data`) | Observe (read-only import) |
| `require-merge-queue-on-platform.yaml` | `platform` | Require merge queue | Observe (read-only import) |
