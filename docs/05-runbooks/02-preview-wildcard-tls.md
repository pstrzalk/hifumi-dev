# Runbook 02 — Pre-issued wildcard TLS for previews

Switch preview hosts from **per-host on-demand Let's Encrypt** (a brand-new cert
issued the first time each `<id>.preview.hifumi.dev` is hit) to a **single
pre-issued wildcard `*.preview.hifumi.dev` cert** served statically by
kamal-proxy.

## Why

On-demand issuance mints a fresh cert per preview whose SCT timestamps are
seconds old. Any visitor whose clock is even slightly behind Chrome's 60-second
SCT future-grace hits `NET::ERR_CERTIFICATE_TRANSPARENCY_REQUIRED` for the first
minutes of the cert's life — the cert is valid, but a client clock running behind
the fresh SCT timestamps reads them as future-dated (post-incident diagnosis of
the 28.preview.hifumi.dev report). A
wildcard cert is issued once and is hours/days old by the time anyone visits a
preview, so its SCTs are long-settled and accepted regardless of small client
clock skew. It also removes per-host LE rate-limit exposure and first-visit
issuance latency, and makes `wait_for_public_tls!` unnecessary.

The code already supports this (no deploy of code needed to keep today's
behavior): when **both** `PREVIEW_TLS_CERTIFICATE_PATH` and
`PREVIEW_TLS_PRIVATE_KEY_PATH` are set, `PreviewManager#register_with_proxy!`
passes `--tls-certificate-path/--tls-private-key-path` to kamal-proxy and skips
the warm-up. Unset (the default) = per-host on-demand `--tls`, unchanged.

## Prerequisites

- DNS for `hifumi.dev` is hosted at **GoDaddy** (`domaincontrol.com` nameservers).
  Wildcard certs can only be validated with **DNS-01**, so you need GoDaddy API
  credentials (Key + Secret) with edit rights on the zone.
  - ⚠️ GoDaddy gates its production API: as of 2026 it has at times required the
    account to hold ≥10 domains (or a specific plan). If the API is unavailable, either move
    `hifumi.dev` DNS to a provider with an open API (Cloudflare, Route53,
    deSEC), or issue the cert manually with a one-off `--manual` DNS-01 TXT
    record. The rest of this runbook is provider-agnostic past the issuance step.
- Host access to `77.42.95.154` and the running `kamal-proxy` container.

## 1. Issue the wildcard via DNS-01

Using [`lego`](https://go-acme.github.io/lego/) on the host (or any machine with
the DNS creds):

```bash
GODADDY_API_KEY=...    \
GODADDY_API_SECRET=... \
lego --accept-tos \
     --email ops@hifumi.dev \
     --dns godaddy \
     --domains '*.preview.hifumi.dev' \
     run
# → ./.lego/certificates/_.preview.hifumi.dev.crt  (fullchain)
#   ./.lego/certificates/_.preview.hifumi.dev.key  (private key)
```

`acme.sh` equivalent: `acme.sh --issue --dns dns_gd -d '*.preview.hifumi.dev'`
(reads `GD_Key` / `GD_Secret`).

Keep the private key off the repo and off the generator image — it authenticates
**every** preview subdomain. Store it only on the host, mode `600`.

## 2. Make the cert visible inside the kamal-proxy container

kamal-proxy resolves `--tls-certificate-path` **inside its own container**, so the
files must exist there. Two options:

- **Option A — bind-mount (durable, preferred).** Put the cert on the host (e.g.
  `/var/lib/hifumi-dev/preview-tls/wildcard.{crt,key}`) and boot kamal-proxy with
  that directory mounted, then reference the in-container path. Customizing the
  Kamal-managed proxy's volumes is not a stock `deploy.yml` field, so this is a
  manual `kamal proxy` boot adjustment — verify the resulting in-container path.
- **Option B — copy into the container (simple, re-copy on proxy reboot).**

  ```bash
  docker exec kamal-proxy mkdir -p /home/kamal-proxy/.config/kamal-proxy/preview-tls
  docker cp wildcard.crt kamal-proxy:/home/kamal-proxy/.config/kamal-proxy/preview-tls/wildcard.crt
  docker cp wildcard.key kamal-proxy:/home/kamal-proxy/.config/kamal-proxy/preview-tls/wildcard.key
  ```

  The `.config/kamal-proxy` dir is kamal-proxy's persistent volume, so these
  survive proxy restarts; re-copy only after a full proxy re-create.

The path you choose is what goes in the env vars below.

## 3. Point the generator at the cert

In `config/deploy.yml`, uncomment and set to the **in-proxy-container** paths:

```yaml
env:
  clear:
    PREVIEW_TLS_CERTIFICATE_PATH: /home/kamal-proxy/.config/kamal-proxy/preview-tls/wildcard.crt
    PREVIEW_TLS_PRIVATE_KEY_PATH: /home/kamal-proxy/.config/kamal-proxy/preview-tls/wildcard.key
```

Deploy: `kamal deploy`.

## 4. Verify

- Start a brand-new preview. It must come up `running` with **no** `curl https://`
  warm-up probe in the logs (warm-up is skipped under a static cert).
- The deploy command kamal-proxy receives now carries the cert-path flags:
  `kamal app logs | grep "tls-certificate-path"` (or inspect proxy access logs).
- `echo | openssl s_client -connect <id>.preview.hifumi.dev:443 -servername <id>.preview.hifumi.dev | openssl x509 -noout -subject -dates`
  → `subject=CN = *.preview.hifumi.dev`, and the `notBefore` is the wildcard's
  issuance date (not "today").

Already-running previews keep their per-host autocert certs until restarted —
only newly-started previews pick up the wildcard. That is fine (the old certs are
still valid); previews are reaped after 30 min, so the fleet rolls over quickly.

## 5. Renewal

The cert is ~90 days; renew around day 60. Re-run the `lego ... renew` (or
`acme.sh` cron), re-place the files (step 2), then make kamal-proxy reload them:
it reads the cert at route-deploy time, so either re-register active routes or
restart the proxy (`kamal proxy reboot`) — a brief blip. Because previews are
short-lived, most routes re-register naturally within 30 min anyway.

## Rollback

Re-comment both `PREVIEW_TLS_*` env vars in `deploy.yml` and `kamal deploy`. New
previews fall straight back to per-host on-demand `--tls`; no other change.
