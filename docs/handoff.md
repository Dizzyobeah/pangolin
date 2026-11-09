# Handoff — Pangolin at home as edge/auth layer + WoW private access

## Context
The user runs an AzerothCore (WoW 3.3.5a) server on Dokploy at home. The router currently forwards only TCP 80/443.

Goal: friends log in through an auth layer before they can reach the game. The game uses raw TCP on auth 3724 and world 8085.

The WoW client can't do HTTP or TLS, so an HTTP SSO page can't sit in front of it. The chosen solution is **self-hosted Pangolin at home**:
- Pangolin's Traefik becomes the edge on 80/443, with SSO in front of web apps.
- Dokploy's Traefik moves behind it.
- WoW is exposed only as Pangolin **private resources**, which require the Pangolin client and a login.
- The router additionally forwards **UDP 21820 and 51820**, the WireGuard ports used by Gerbil.

The work is being moved out of the azerothcore-wotlk repo into a separate infra repo that the user will choose.

## Current State
- Research and plan are complete. Nothing has been implemented.
- The plan was rejected at the approval step only because the user wants to execute it in another repo, not because of its content.
- No changes were made to azerothcore-wotlk.

## Open Tasks
- [ ] Move Dokploy's Traefik off host 80/443 (verify `TRAEFIK_PORT`/`TRAEFIK_SSL_PORT` behaviour first; see Dokploy issue #804) — high
- [ ] Deploy the Pangolin stack (pangolin, gerbil, traefik) as a Dokploy compose app. Gerbil publishes 80, 443, 51820/udp and 21820/udp, and joins `dokploy-network` — high
- [ ] DNS: wildcard `*.<domain>` pointing at the home IP. Router: forward UDP 21820 and 51820 — high
- [ ] Newt site container on `dokploy-network` — high
- [ ] HTTP resources behind Pangolin SSO targeting `dokploy-traefik:80`. Switch Dokploy domains to HTTP only — medium
- [ ] Private Host resources `<HOST_LAN_IP>`:3724 and :8085, plus a wow-players role — high
- [ ] Ops SQL on the live auth DB: `UPDATE acore_auth.realmlist SET address='<HOST_LAN_IP>', localAddress='<HOST_LAN_IP>' WHERE id=1;` — high
- [ ] Optional: dokploy-to-pangolin webhook (it defaults to HTTPS :443 targets, so adjust it) — low
- [ ] Optional: bind SOAP 7878 to 127.0.0.1 in azerothcore-wotlk `docker-compose.dokploy.yml`. This change belongs in the azerothcore repo — low

## Key Decisions Made
- **Option C** (Pangolin at home with UDP 21820/51820 forwarded) was chosen over Headscale (443 only) and Pangolin on a VPS.
- **Pangolin's Traefik owns 80/443**, not Dokploy's.
- Never enable `allow_raw_resources`. Public raw TCP bypasses Pangolin auth.
- `realmlist.address` must be an IP. The authserver resolves hostnames server-side and sends the client an IP (`src/server/shared/Realms/RealmList.cpp:163` in azerothcore-wotlk). That means Pangolin aliases can't be used; target the host LAN IP.
- Known caveat: a friend whose LAN uses the same subnet will have colliding routes. Consider an uncommon LAN subnet, or a dedicated secondary IP.

## Artifacts
- Full plan, including steps and verification: `/Users/calund/.claude/plans/so-we-have-a-foamy-petal.md`
- AzerothCore Dokploy compose (reference for ports and network): `/Users/calund/projects/_git/azerothcore-wotlk/docker-compose.dokploy.yml`. Services `ac-authserver` and `ac-worldserver` are on the external `dokploy-network`.
- Docs: https://docs.pangolin.net/self-host/manual/docker-compose, https://docs.pangolin.net/manage/resources/understanding-resources, https://docs.pangolin.net/manage/clients/add-client, https://github.com/fosrl/pangolin, https://github.com/orochibraru/dokploy-to-pangolin, https://github.com/Dokploy/dokploy/issues/804

## Environment / Setup Notes
- Dokploy host at home, with the Dokploy-managed MySQL holding `acore_auth`.
- Placeholders to fill in: `<domain>`, `<HOST_LAN_IP>`, the Let's Encrypt email, and the Newt ID/secret from the Pangolin UI. Secrets go in Dokploy env and must not be committed.
- Take a host snapshot or backup before touching `dokploy-traefik`. Rollback means restoring its original port bindings.

## Suggested Skills
- `context7-mcp` — check current Pangolin, Newt and Dokploy docs before writing compose and config; both projects change quickly.
- `grill-me` — stress-test the edge-swap step, which carries the most risk to existing apps.

## Next Steps
1. In the new repo, save the plan to `.agents/plans/` or `docs/`, and to the vault at `/Users/calund/projects/Claude/projects/<repo>/plans/2026-11-09-pangolin-edge-wow-access.md`.
2. Confirm how to move Dokploy's Traefik off 80/443 safely (Dokploy source and docs), then write the Pangolin compose and `config.yml`.
3. Follow the plan's Verification section end to end, including an external nmap of open ports.
