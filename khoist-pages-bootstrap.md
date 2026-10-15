# KHoist documentation hosting

The user site is delivered by
[data-product-controller#425](https://github.com/devantler-tech/data-product-controller/pull/425).
This repository owns its GitHub settings; the product owns the content and
default-branch deployment workflow.

## Bootstrap prerequisite

Keep the configuration PR draft until the maintainer-approved Pages bootstrap has
completed and the live site settings match the declaration. The current managed
GitHub App cannot create or update Pages sites. Do not deploy the declaration
against an absent site: it would produce a permission error, as diagnosed in
[#232](https://github.com/devantler-tech/.github/issues/232).

The bootstrap writer must have the authority GitHub requires for creating the
site. This change grants no permissions, creates no token and does not change the
App's privileges. The maintainer must approve the one-time bootstrap procedure
through this owner before it is used.

The intended settings are:

| Setting | Value |
| --- | --- |
| Repository | `devantler-tech/data-product-controller` |
| Pages build type | `workflow` (GitHub Actions) |
| Custom domain | `khoist.devantler.tech` |
| Homepage | `https://khoist.devantler.tech/` |

There is no branch `source` block for a workflow-built site. A checked-in `CNAME`
file does not configure an Actions-built site's custom domain.

Read the live Pages settings with `gh api repos/devantler-tech/data-product-controller/pages`.
Confirm `build_type: workflow` and the exact `cname`. The REST response may retain
a legacy `source` branch even for workflow builds. The pinned provider's
[`flattenPages` implementation](https://github.com/integrations/terraform-provider-github/blob/v6.13.0/github/resource_github_repository.go)
normalizes that field to absent for workflow builds, so the declaration must omit it.
Once those settings match, the reviewed declaration preserves the provider's shape while retaining
the repository's existing management policies. Verify successful reconciliation
without Pages permission errors before treating configuration adoption as complete.

## Publication ownership

The [product documentation](https://github.com/devantler-tech/data-product-controller/pull/425)
owns publishing and user-facing verification. The product keeps its DNS declaration
beside its deployment files; [platform tenant registration](https://github.com/devantler-tech/platform/issues/4939)
owns reconciliation through the shared writer. Follow those owners' procedures for
DNS and public HTTPS. Matching Pages settings here proves configuration adoption,
not that the content is publicly available.

GitHub documents the
[Pages API permissions](https://docs.github.com/en/rest/pages/pages#create-a-github-pages-site)
and [custom-domain ordering](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site).
