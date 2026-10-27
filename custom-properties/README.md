# Repository custom properties

The catalogue owns three properties. Every active managed repository has an explicit value in
[`catalogue.json`](catalogue.json), including the deliberate automatic-merge opt-out for the adopted
private intake repository.

| Property | Purpose |
|---|---|
| `Type` | Portfolio purpose: application, infrastructure, library, marketplace, metadata or documentation. Existing templates retain their native application/infrastructure classifications so the legacy CodeQL selector continues to cover them. |
| `EnableAutoMerge` | Select the existing organization automatic-merge workflow policy. This does not grant approval or bypass any readiness, review or branch-protection requirement. |
| `ScanGitHubActions` | Select the existing organization workflow-vulnerability scanning policy; explicitly enabled everywhere. |

GitHub already supplies language, visibility, archival and template status. Do not mirror those as
new custom properties. `LintDocumentation` and `AutomaticallyRequestCopilotCodeReview` are retired
after complete native organization-ruleset and Actions-policy inventories confirm no remaining
consumer. The only consumer that may be removed is the observed disabled legacy review ruleset
`14426508`, named `Automatically request Copilot code review`. The reconciler requires its
organization identity, disabled branch target, empty bypass list, default-branch-only selector,
the single retired-property selector set to true and the sole Copilot review rule. It rechecks the
complete record after all values are initialized and read back, then verifies its removal before
deleting either property. Any active, renamed, expanded or concurrently changed policy blocks
retirement. All active policies remain untouched. This never requests a Copilot review.
An unreadable, partial or changed policy identity stops schema writes. An enterprise-sourced or
unexpected property is preserved and stops reconciliation for an ownership review.

## Ownership and reconciliation

Repository actors retain the existing permission to set values; Crossplane restores the reviewed
catalogue. Required values remain explicit rather than relying on defaults. Defaults are only the
GitHub fallback and do not establish compliance.

GitHub rejects independent property creation when other required explicit values are missing.
The reviewed-main workflow therefore writes each repository's complete assignment atomically,
including either retiring switch as false while its definition still exists. It
reads back every assignment through the completely paged organization values collection before
retiring the unused definition. Repository names, organization ownership and unique native IDs
must agree; missing private entries or a failed later page block retirement. The native apply proved
that the organization writer can initialize every assignment while restricted to this repository,
but its repository selection made the organization readback incomplete. The writer stays restricted.
A separate, short-lived read-only token selects exactly the validated catalogue and supplies only
the organization-value readback. It explicitly requests both organization custom-property read
authority and repository metadata read access for the selected repositories, with no repository
content access. Repository selection alone does not request metadata authority when the token's
permissions are explicitly limited. Neither that token nor its alternate credential is passed to schema or value mutations.
The action revokes both tokens at job completion.

The readback selection is exactly the reviewed catalogue; changing that selection requires
maintainer direction, rather than an automatic response to incomplete results. Native full-portfolio readback,
including private entries, remains required after deployment; offline tests do not establish it.
Repeated runs reassert the same complete catalogue; an effective default alone never replaces a
successful explicit write.

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
final schema and all final repository values. It also initializes complete repository values through the
[organization values API](https://docs.github.com/en/rest/orgs/custom-properties#create-or-update-custom-property-values-for-organization-repositories)
using its existing custom-properties authority. The sole ruleset mutation is retirement of the
guarded disabled legacy review rule described above. Token permission failure is a
blocker; do not widen the App or substitute a personal credential.

There is no transaction with another organization owner changing policies concurrently. The final
consumer recheck narrows that race, and subsequent runs detect schema drift.

## Required App authority

GitHub separates definition management from value editing. The schema workflow's `botantler-1`
App needs **Custom properties: Admin** at organization scope
(`organization_custom_properties: admin`), plus its existing organization-administration write
authority for the consumer census and the guarded disabled-rule retirement. GitHub requires that write permission even for
[listing organization rulesets](https://docs.github.com/en/rest/orgs/rules#get-all-organization-repository-rulesets)
and [listing Actions policies](https://docs.github.com/en/rest/actions/policies#list-organization-actions-policies).
Other consumer policies are read-only; only the identified disabled legacy rule can be deleted.
Custom-properties write alone can edit values but cannot create, update or delete
property definitions. See the [schema API permissions](https://docs.github.com/en/rest/orgs/custom-properties#create-or-update-a-custom-property-for-an-organization).

Crossplane's `provider-upjet-github` App needs **Custom properties: Read and write** at repository
scope (`repository_custom_properties: write`). The catalogue preserves `org_and_repo_actors` so
that permission can set the explicit values. See the [repository value API permissions](https://docs.github.com/en/rest/repos/custom-properties#create-or-update-custom-property-values-for-a-repository).

These are deployment prerequisites, not grants made by the workflow. The maintainer must configure
and accept any required App permission updates before this catalogue is merged. An accepted
installation grant is required; the workflow's token request cannot supply missing authority. Inspect only permission metadata;
never print a private key or token, broaden an App automatically, or substitute personal credentials.

## Delivery and evidence

Deploy platform#5389 first: it activates exactly this namespaced CRD and grants the existing tenant
Role its matching resource. Publish the catalogue only after that deployment is independently
verified. The schema and complete-value workflow must succeed before individual Crossplane
assignments can reconcile. A future template classification change requires separate native policy
coverage evidence before its values can change.

Run `bash tests/custom-properties.sh` and the existing deployment checks before a PR. The test uses
the real Kustomize output to reject missing, duplicate, undeclared or unsafe assignments, checks
generated parity and exercises schema refusal/readback behavior. After publication, independently
read the native schema, all repository values and Crossplane creation/reconciliation evidence; then
inspect representative repository settings pages for the missing-value warning. Effective API
defaults and Ready conditions alone do not establish explicit compliance or UI acceptance.
