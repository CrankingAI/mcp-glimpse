# Site conventions — product-decision checklist

Root-level and `/.well-known/` files plus edge redirects. Most of these are **product
decisions**, not defaults — this doc presents them as a checklist with documented
questions so each repo decides per project. Where the seed can ship a sensible commented
stub it does; it never bakes an answer. Record material answers (and later
reversals) as ADRs ([docs/adr](adr/README.md)).

Fetches of the files below are logged at the Cloudflare edge by default —
who reads them, verified-bot classified. See [edge](edge.md).

Work the checklist when standing up a public surface.

## robots.txt

Ship `robots.txt` only when there is a reliable, stable public landing page to index.

> Product Q: Will this surface have a stable, indexable public landing page?

Do **not** `Disallow` the `/app/*` SPA layer here — it is excluded via the
`X-Robots-Tag: noindex,nofollow` response header instead (a disallowed path is never
fetched, so the header is never seen). See [seo-discoverability](seo-discoverability.md).

## sitemap.xml

Generated at build from the Astro public routes when a public shell exists. No manual
maintenance.

> Product Q: Public shell present? If yes, wire sitemap generation into the build.

## llms.txt / llms-full.txt

Root-level agent-legibility files. **Watch-list item** — low adoption today; ship cheaply,
do not oversell. See [watch-list](watch-list.md) and [seo-discoverability](seo-discoverability.md).

> Product Q: Curated `llms.txt` (hand-picked links) vs. fuller `llms-full.txt` (inlined
> content)? Decide per project.

## /.well-known/agent-card.json

A2A (Agent2Agent) discovery: agents find an A2A server's Agent Card at this
RFC 8615 path. (Earlier spec drafts used `agent.json`; current is
`agent-card.json`.) Only relevant when this repo exposes an A2A agent server —
a [watch-list](watch-list.md) interface, not a kit default.

> Product Q: Does this repo expose an agent that other agents should discover
> and call via A2A? If not (the default), ship nothing here.

## /.well-known/security.txt

RFC 9116 — contact + policy for vulnerability reports.

> Product Q: What is the security contact and disclosure policy URL?

Cross-references [security](security.md). Ship it for any internet-facing surface.

```text
# /.well-known/security.txt (RFC 9116)
Contact: mailto:security@mcpglimpse.com
Expires: {{EXPIRES_ISO8601}}
Policy: https://mcpglimpse.com/security-policy
```

## /.well-known/dnt-policy.txt

The kit's retention posture aligns with the
[EFF DNT policy](https://www.eff.org/dnt-policy) — raw client IP + UA live
≤ 10 days in the edge log, then auto-purge (see [edge](edge.md)). That
posture is unconditional. **Posting this file is more**: it is a formal,
public commitment to the *entire* EFF policy, including honoring `DNT:1`
identifier rules app-side — not just the log window.

> Product Q: Commit publicly? Only post `dnt-policy.txt` after confirming the
> app side honors `DNT:1` (identifier discarding for logged-in users). If
> unsure, keep the 10-day posture and do not post the file yet.

## /.well-known/change-password

W3C draft — a well-known redirect to the app's password-change URL (password-manager UX).
Only relevant when the app has authentication.

> Product Q: Does this app have authentication? If yes, point this at the change-password
> route. See [auth](auth.md).

```text
# /.well-known/change-password → 302 redirect
Location: https://mcpglimpse.com/app/settings/password
```

## Favicon set

> Product Q: Simple single favicon, or the broad set (Apple touch icons, `manifest`
> icons, multiple sizes)? Scope is a design call.

Broad set, when chosen:

```text
favicon.ico
favicon.svg
apple-touch-icon.png            # 180×180
icon-192.png
icon-512.png
```

## www → apex redirect

Redirect `www.mcpglimpse.com` to the apex domain so analytics and canonical URLs do not split.

> Product Q: Confirm apex as canonical. Implement at the **Cloudflare edge**
> (a zone redirect rule — free; `scripts/cf-zone-init.sh` creates it) or via
> DNS/SWA.

The Cloudflare redirect rule is the recorded clean approach; a DNS/SWA-level
redirect is the fallback for repos seeded with `--edge none`. See
[edge](edge.md).

## Legal pages — privacy policy & terms of service

> Product Q: Routes and page names for privacy policy and terms of service? (May already
> be tracked as separate tickets.)

Use the **privacy-policy-drafter** skill to draft the privacy policy — especially after
adding or removing analytics (App Insights RUM ties to this; see
[observability](observability.md)). The seed names the route and the skill; it does
**not** generate legal text.

> **Any third-party form/embed that collects user input is a privacy-policy
> event — even with zero backend change.** A hosted email/waitlist embed
> (Buttondown, Tally, a Google Form) collects personal data through someone
> else's script; a privacy page still claiming "no personal data collected" is
> then wrong and a **ship-blocker** (fleet finding, [backlog.md](backlog.md)
> §14 — caught in final review, easy to miss precisely because no backend
> changed). Release-checklist line: *did this change add any new data
> collection, first- or third-party?* If yes → re-run privacy-policy-drafter.

## PWA — out of scope

PWA support is **out of scope for now** (low interest). If that changes, add:
`manifest.webmanifest`, a service worker, and the full icon set. Recorded here only so the
decision is explicit, not forgotten.
