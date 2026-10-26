# Repository custom properties

The catalogue owns three properties. Every active managed repository has an explicit value in
[`catalogue.json`](catalogue.json), including the deliberate automatic-merge opt-out for the adopted
private intake repository. The two existing policy switches retain their current effective values.

| Property | Purpose |
|---|---|
| `Type` | Portfolio purpose: application, infrastructure, library, marketplace, metadata, documentation or starter template. Templates describe the repository's purpose even where GitHub's template flag is not enabled. |
| `EnableAutoMerge` | Select the existing organization automatic-merge workflow policy. This does not grant approval or bypass any readiness, review or branch-protection requirement. |
| `ScanGitHubActions` | Select the existing organization workflow-vulnerability scanning policy; explicitly enabled everywhere. |

GitHub already supplies language, visibility, archival and template status. Do not mirror those as
new custom properties. `AutomaticallyRequestCopilotCodeReview` and `LintDocumentation` have no
declared consumer and are retired only after complete native organization-ruleset and Actions-policy
inventories confirm that no consumer still references them. This never requests a Copilot review.
An unreadable, partial or changed policy identity stops schema writes. An enterprise-sourced or
unexpected property is preserved and stops reconciliation for an ownership review.

## Ownership and reconciliation

Repository actors retain the existing permission to set values; Crossplane restores the reviewed
catalogue. Required values remain explicit rather than relying on defaults. Defaults are only the
GitHub fallback and do not establish compliance.

The installed provider v0.20.0 supports namespaced `RepositoryCustomProperty` resources. Generate
them with:

```sh
go -C scripts/custom-properties run . --root ../.. --render > deploy/repository-properties/properties.yaml
```

The resources permit Observe, Create and Update, with no Delete or LateInitialize. They intentionally
start without an imported external name: the provider's read returns effective defaults, so importing
a value equal to its default can leave it untouched forever. The first create operation writes the
explicit assignment; Upjet then records its returned identifier. Removing a managed resource cannot
erase the live value.

The provider exposes no organization-schema resource. The repository-owned
[`apply-custom-properties.yaml`](../.github/workflows/apply-custom-properties.yaml) therefore reconciles
the reviewed schema on main changes, daily and on demand, following the existing workflow-execution
policy pattern. It checks generated-source parity before minting an App token, reads every native
consumer before a mutation, verifies replacement definitions before retirement and reads back the
final schema. It never changes a ruleset or sets repository values. Token permission failure is a
blocker; do not widen the App or substitute a personal credential.

There is no transaction with another organization owner changing policies concurrently. The final
consumer recheck narrows that race, and subsequent runs detect schema drift.

## Delivery and evidence

Deploy platform#5389 first: it activates exactly this namespaced CRD and grants the existing tenant
Role its matching resource. Publish the catalogue only after that deployment is independently
verified. The schema workflow must succeed before new `Template` assignments can reconcile.

Run `bash tests/custom-properties.sh` and the existing deployment checks before a PR. The test uses
the real Kustomize output to reject missing, duplicate, undeclared or unsafe assignments, checks
generated parity and exercises schema refusal/readback behavior. After publication, independently
read the native schema, all repository values and Crossplane creation/reconciliation evidence; then
inspect representative repository settings pages for the missing-value warning. Effective API
defaults and Ready conditions alone do not establish explicit compliance or UI acceptance.
