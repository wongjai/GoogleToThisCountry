# AGENTS.md

Fork of [edmond1294/GoogleToThisCountry](https://github.com/edmond1294/GoogleToThisCountry) published as `wongjai/GoogleToThisCountry`. The only functional difference from upstream is the **experimental UK option 6** in `gttc.sh`, plus the install/self-download URLs pointing at this fork.

## Layout
- `gttc.sh` — the whole tool; kept at repo root like upstream. Runs `check_warp`, `install_core`, `show_menu` at top level.
- `README.md` — upstream docs plus the experimental-UK notice.
- `tests/test_country_selection.sh` — side-effect-free tests of `enable_target_country`.
- `logs/`, `state/` — gitignored; test logs, sandboxes, verification evidence. Keep all artifacts here, never in `/tmp` or `$HOME`.

## Hard rules
- **Never run or install `gttc.sh` on any real machine** (it writes `/etc`, `/usr/local/bin`, installs packages and Xray, restarts services). It is only exercised through the test sandbox.
- Tests extract the function definitions (trailing top-level calls removed, fail-closed if that layout changes), redirect all write paths into `state/`, stub `rc-service`/`rc-update` and put tripwires on `curl`, `systemctl`, package managers, etc. Keep it that way; do not source `gttc.sh` directly.
- No secrets, tokens or runtime artifacts in git. No cron/services.
- Git identity is repo-local: `wongjai` / `40750736+wongjai@users.noreply.github.com`. Do not use a real name or email.
- No upstream PRs without explicit instruction. Remote `upstream` is read-only reference; the fork is `origin`.

## Workflow
1. Strict TDD: add/adjust a test in `tests/test_country_selection.sh`, run it and see it fail (RED), then change `gttc.sh`/`README.md`, then GREEN.
2. `bash -n gttc.sh && bash tests/test_country_selection.sh && git diff --check`
3. Adding a region: follow the existing `case` in `enable_target_country`; update the menu lines, the `[1-N]` prompt, the header comment, README region list, and the table in `test_option` calls. Verify any ECS prefix against a public registry (e.g. RIPE for GB) and record the evidence under `logs/`.

## Facts worth remembering
- UK option 6: name `🇬🇧 United Kingdom`, DoH `https://dns.google/dns-query`, ECS `81.2.69.0/24`, `Accept-Language: en-GB,en;q=0.9`. Verified against the RIPE DB (inetnum `81.2.64.0 - 81.2.127.255`, GB, AS20712); all inetnums inside the /24 are GB. ECS only steers DNS/CDN answers; it does not guarantee Google's source-IP geolocation changes.
- `read` trims surrounding whitespace, so `"1 "` is a valid `1`; only exact `1`–`6` select a region.
- Script configures Xray (and v2ray-style config paths), not sing-box.
