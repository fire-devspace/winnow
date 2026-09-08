[Back to main README](../README.md)

# Website and product explanations

This directory is the static website and the public explanation of Winnow's
features, architecture, testing, and limitations. The app also bundles five
technical guides and site.css so those explanations are available offline.

[The journey inventory](journeys.json) and
[app test source](../UITests/README.md) feed [build-site](../scripts/build-site),
which generates home and Advanced pages. Other pages are authored directly.
[signing.js](signing.js) runs the homepage’s signing examples: a stolen hardware
key, a separate approved payment, shared savings, and a possible future loan.
Each scene plays once, has replay controls, and shows a still version for reduced
motion. Approvals travel to the payment; MuSig2 approvals merge into one on-chain
signature, while shared spending reveals its three keys and two-approval rule.
On mobile, app journeys start folded into expandable rows; linked journeys open
automatically. Without JavaScript, all scenes and journeys remain readable. The drawings come from
the page generator and use [site.css](site.css); no animation library is needed.
[The roadmap](roadmap.html) separates planned work from current behavior.
[Architecture](architecture.html) links directly to the focused technical guides.
Those HTML files are the maintained explanations; no separate paper or paper
index is needed. [_redirects](_redirects) sends old paper URLs to the architecture page.

Run `scripts/build-site --check` and, with real LFS images downloaded,
`scripts/check-site` from the root. [Website CI](../.github/workflows/site.yml)
validates and deploys this same tree. Those checks cover generation, local links,
and images, not rendered-browser layout or the truth of every prose claim.
[Testing](testing.html), [screenshots](screenshots/README.md), and
[security evidence](security/README.md) explain the supporting records.
