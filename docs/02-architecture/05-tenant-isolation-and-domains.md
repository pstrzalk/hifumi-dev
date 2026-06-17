# Tenant isolation and the preview domain

This service runs **untrusted, user-generated code** (the preview apps) on the
public internet, next to a **trusted control plane** (the generator — auth,
per-user OpenRouter keys, project data). The hard isolation problem is not the
container — that's handled (`preview-isolation.md` for the Docker/kamal-proxy
side, `Roast::Sandbox` for the codegen agent). The hard problem is the **browser
boundary** between the control plane and the previews, and that boundary is
decided almost entirely by **what domain previews are served from**.

If you fork this repo to host your own version, this is the single most important
architectural choice you'll make, so it gets its own document. Short version:
hifumi.dev serves previews as **subdomains of its own apex** (`<id>.preview.hifumi.dev`)
and hardens around the consequences; the only thing that actually *removes* the
problem is serving previews from a **separate registrable domain**.

---

## The model today

| Role | Host | Trust |
|---|---|---|
| Generator (control plane) | `hifumi.dev` | trusted — holds auth, BYOK keys, project data |
| Preview (user-built app) | `<id>.preview.hifumi.dev` | **untrusted** — arbitrary LLM/user-authored HTML/JS |

Both share the registrable domain `hifumi.dev` (`.dev` is the public suffix, so
`hifumi.dev` is the eTLD+1; `preview.hifumi.dev` is just a subdomain, **not** a
public suffix). That shared registrable domain is the whole issue.

## Why subdomains of your own apex are the obstacle

Browser security boundaries that you'd hope isolate the preview from the
generator are keyed on the **registrable domain**, not the origin — so a preview
subdomain is *inside* several of the generator's boundaries:

1. **Cookies are domain-scoped, not origin-scoped.** A preview can send
   `Set-Cookie: …; Domain=hifumi.dev`, which the browser then delivers to the
   generator *and* every sibling preview. That enables **cookie tossing /
   shadowing**: a malicious preview plants a `Domain=hifumi.dev` cookie that
   collides with the generator's own session cookie → **session fixation / login
   CSRF** (a victim ends up acting as the attacker on hifumi.dev). The generated
   apps are trivially attacker-controlled — a user just builds an app with
   whatever JS they like. (Confidentiality is preserved — a preview cannot
   *read* the generator's host-only cookie — but it can *write* a colliding one,
   and it can cookie-bomb the apex into `431`s.)

2. **`SameSite` treats subdomains as same-site.** `SameSite=Lax/Strict` is
   computed on the registrable domain, so a request from a preview page to
   `hifumi.dev` is *same-site* and carries the victim's cookies. `SameSite` gives
   **no** CSRF protection across this boundary — you're relying entirely on
   app-level CSRF tokens (Rails' authenticity token).

3. **`document.domain`** lets two pages on `*.hifumi.dev` relax the same-origin
   policy to the shared parent and script each other (legacy, but real).

(There was also a TLS wrinkle specific to per-host certs on these subdomains —
see `preview-tls-cert.md` / the 28.preview research — but that one is solved by
the pre-issued wildcard; it's not part of *this* class.)

## What this codebase does about it — and why it's a mitigation, not a cure

hifumi.dev stays on the shared apex (one domain already owned, hardening was the
cheap unblock) and blunts each known vector. All of this is shipped:

- **`__Host-` session cookie** (`config/initializers/session_store.rb`) — the
  browser rejects any `__Host-`-named cookie a subdomain tries to set for the
  parent, so the generator's session cookie becomes un-shadowable.
- **Secure cookies + HSTS** via `force_ssl` + `assume_ssl`
  (`config/environments/production.rb`).
- **Host-only cookies everywhere** — nothing sets an explicit cookie `Domain=`,
  so generator cookies don't fan out to subdomains by default.
- **Devise remember-me** marked `Secure` + `SameSite=Lax`
  (`config/initializers/devise.rb`).
- **`Origin-Agent-Cluster: ?1`** on every response
  (`config/initializers/security_headers.rb`) — disables `document.domain`.
- **CSRF tokens on** (Rails default) — the actual defense against same-site
  forgery from a preview page, since `SameSite` can't help here.

**Why it's not a cure.** These close the *known* holes, but previews are still
structurally **same-site** with the control plane. Every defense above is a
patch over individual symptoms; a new same-site assumption, a CSRF-exempt or
GET-with-effects endpoint, a cookie-bomb DoS, or any future feature that trusts
"same-site" re-opens the surface. You are one mistake away, permanently, because
the boundary itself is weak by construction.

## The antidote: a separate registrable domain

Serve untrusted previews from a **different registrable domain** than the control
plane — the `githubusercontent.com` / `googleusercontent.com` / `csb.app`
pattern. Then previews are **cross-site** to the generator: no cookie is
delivered to the apex, `SameSite` actually protects, `document.domain` can't
reach across, there is no shared-parent anything. The entire class collapses —
you stop playing whack-a-mole and the hardening above becomes belt-and-suspenders.

This is the established practice for hosting user content, precisely because the
in-browser boundary follows the registrable domain. If you host your own version
of this service, **put previews on their own registrable domain from day one** —
e.g. `*.preview.<your-usercontent-domain>` — and keep your auth/control plane on
its own.

### Single vs. multiple domains (the "or domains?" question)

- **One** separate domain (e.g. `*.preview.hifumi-usercontent.dev`) fully isolates
  **generator ↔ preview**. This is the high-value move and almost certainly all
  you need.
- It does **not** isolate previews **from each other** — they still share the
  user-content apex, so preview A can toss a `Domain=<usercontent>` cookie onto
  preview B. For throwaway demo apps on public URLs this is low-stakes and is the
  residual GitHub/CodeSandbox accept. **Full** preview↔preview isolation needs
  per-preview *unique* registrable domains (impractical / cert-cost-prohibitive
  at scale) or treating each preview as fully disposable. Don't reach for it
  unless your previews hold something worth stealing from each other.

The migration itself is mostly DNS + a wildcard cert + one env var, because the
preview hostname is already parameterized on `PREVIEW_DOMAIN`
(`Preview::Config.domain` → `public_preview_host`, the CSP `frame-src`, and the
container's `PREVIEW_HOST` all follow it). The concrete steps and trade-offs are
tracked in `docs/09-ideas/05-followups.md`.
