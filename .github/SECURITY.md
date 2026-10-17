# Security Policy

## Supported Versions

The project is not backwards compatible, and as such only the latest version is supported with security updates.

## Reporting a Vulnerability

Do not disclose a vulnerability, credentials or private operational data in a public issue or
pull request. Follow the affected repository's own security policy when it has one.

For repositories using this default policy, open the affected repository's **Security** tab and
choose **Report a vulnerability** to submit a private report to its maintainers. Private reporting
is enabled for this shared automation repository at
[Report a vulnerability](https://github.com/devantler-tech/.github/security/advisories/new).
Use the affected repository's report form, not this repository's form for an unrelated product.

If that option is unavailable, request a private reporting channel without posting sensitive
details. Wait for a private channel before sending reproduction steps or impact information.

A useful report names the affected repository and version or commit, explains the impact, and
gives the smallest reproduction you can. Please test only against your own installations, never
against someone else's deployment or data.

## What Happens Next

- **Acknowledgement:** we accept or decline the report within three business days, and tell you
  which.
- **Assessment:** we confirm the issue and its severity, and tell you the result within seven days.
- **Fix:** we aim to release a fix within 14 days for critical and high severity issues, and
  within 90 days for others. We tell you if a fix will take longer.
- **Disclosure:** we keep the report private until a fixed release is available. We then publish
  a GitHub security advisory, with a CVE where one applies, and credit you unless you would rather
  stay anonymous.
- **Handling:** reports are triaged with the help of AI agents under the maintainer's
  supervision. A report stays inside the private advisory. Its proof of concept is never run: we
  reproduce the issue with our own tests.

## Out of Scope

- Vulnerabilities in third-party dependencies, unless our use of them makes the issue worse.
  Please report those upstream.
- Issues that need an already compromised machine or account, or physical access.
- Findings from automated scanners without a demonstrated impact.
