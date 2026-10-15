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
Confirm `build_type: workflow`, the exact `cname`, and no source branch. Once those
settings match, the reviewed declaration preserves the live shape while retaining
the repository's existing management policies. Verify successful reconciliation
without Pages permission errors before treating configuration adoption as complete.

## DNS, publication and HTTPS

Configure the custom domain in Pages before adding DNS. The public record is a
DNS-only CNAME from `khoist.devantler.tech` to `devantler-tech.github.io`.

The [platform ExternalDNS integration](https://github.com/devantler-tech/platform/issues/4939)
owns this record through GitOps. Deploy and verify its explicit-record admission
boundary before enabling CRD discovery on the existing writer, retaining the
current TXT registry, owner, zone filter and routed-service discovery. This path
needs neither a direct Cloudflare settings change nor another credential.
Do not change the shared Gateway's DNS target to publish a static site.

After the site's reviewed source and configuration have shipped, run the product's
documentation workflow from `main`. Confirm its Pages deployment, DNS resolution,
valid custom-domain HTTPS and the published tutorial and search. Enforce HTTPS
through the approved settings owner once GitHub has provisioned the certificate.
Source merge, configuration adoption and public availability are separate results.

GitHub documents the
[Pages API permissions](https://docs.github.com/en/rest/pages/pages#create-a-github-pages-site)
and [custom-domain ordering](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site).
