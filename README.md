# Pangolin edge for a Dokploy host

Pangolin (Gerbil + Traefik) takes over host ports 80/443 as the public reverse proxy and SSO layer.
Dokploy's own Traefik moves to high ports and sits behind it. WoW (raw TCP) is exposed only as
Pangolin *private resources*, reachable through the Pangolin client after login.

```
Internet ─ 80/443 ─► Pangolin Traefik (in gerbil netns) ─ SSO ─► dokploy-traefik:8081 ─► apps
         └ 21820/51820 UDP ─► Gerbil ◄─ Newt (outbound) ─► <HOST_LAN_IP>:3724 / :8085
```

`DOMAIN` comes from `.env`. Remaining placeholders: `<LE_EMAIL>`, `<HOST_LAN_IP>`. Full background: `docs/pangolin-edge-wow-access.md`.

## Files
| Path | Purpose |
|---|---|
| `docker-compose.yml` | pangolin, gerbil, traefik, newt |
| `config/config.yml.tmpl` | Pangolin config template (`allow_raw_resources` stays `false`) |
| `config/traefik/` | Traefik static config + `dynamic_config.yml.tmpl` |
| `render.sh` | renders `.tmpl` files from `.env` (outputs gitignored) |
| `.env.example` | `DOMAIN`, `NEWT_ID`, `NEWT_SECRET` (copy to `.env`, never commit) |

## 0. Prerequisites
- Dokploy running on the host, wildcard DNS `*.$DOMAIN` and `pangolin.$DOMAIN` pointing at your home IP.
- Router forwards TCP 80/443 and **UDP 21820 + 51820** to the host.
- **Snapshot/back up the host first.** Rollback = step 2 in reverse (unset the env vars, reload Traefik, restore `traefik.yml`).
- `cp .env.example .env`, set `DOMAIN`, run `./render.sh` (needs `envsubst`) to generate `config/config.yml` and `config/traefik/dynamic_config.yml` from the `.tmpl` files. Re-run when `DOMAIN` changes.
- Fill the rest: `grep -rn '<LE_EMAIL>\|<GENERATE' config` (`openssl rand -hex 32` goes in `server.secret` in `config/config.yml.tmpl`).

## 1. Move Dokploy's Traefik off 80/443

How Dokploy decides (from `packages/server/src/setup/traefik-setup.ts`, Dokploy v0.31):
- `dokploy-traefik` is created with host ports from the **Dokploy process env**: `TRAEFIK_PORT` (default 80),
  `TRAEFIK_SSL_PORT` (443) and `TRAEFIK_HTTP3_PORT` (443/udp). The same numbers become the container-side ports.
- **Web Server → Traefik → Ports** in the UI only *adds* extra ports. It can't remove the 80/443 bindings,
  so use the env vars.
- `traefik.yml` entrypoints must listen on the same ports (`web: ":<TRAEFIK_PORT>"`). The old issue
  [#804](https://github.com/Dokploy/dokploy/issues/804) (routing broke after changing ports) is consistent with
  these getting out of sync. This is inferred from source, **not tested**: do it on a snapshot.

Steps (chosen ports: HTTP 8081, HTTPS 8444, HTTP/3 8444):

1. Set the env vars on the Dokploy service (standard install runs it as swarm service `dokploy`):
   ```bash
   docker service update \
     --env-add TRAEFIK_PORT=8081 \
     --env-add TRAEFIK_SSL_PORT=8444 \
     --env-add TRAEFIK_HTTP3_PORT=8444 \
     dokploy
   ```
   (If you installed with an `ADVERTISE_ADDR`/custom script, make the same change there so an upgrade doesn't revert it.)
2. Back up, then edit `/etc/dokploy/traefik/traefik.yml` (UI: **Traefik File System**, or on the host):
   ```yaml
   entryPoints:
     web:
       address: ":8081"
     websecure:
       address: ":8444"
       http3:
         advertisedPort: 8444
   ```
   Leave the rest (providers, `letsencrypt` resolver) alone.
3. Recreate Traefik: **Settings → Web Server → Traefik → Reload** (or `docker rm -f dokploy-traefik` then restart the Dokploy service).
4. Check:
   ```bash
   docker ps --format '{{.Names}}\t{{.Ports}}' | grep dokploy-traefik   # 8081/8444 only
   sudo lsof -nP -iTCP:80 -iTCP:443 -sTCP:LISTEN                         # nothing
   sudo lsof -nP -iUDP:443                                                # nothing
   ```
5. In Dokploy, switch each app's domain to **HTTP only (HTTPS off)**. Pangolin terminates TLS now, and
   Let's Encrypt HTTP-01 no longer reaches Dokploy's Traefik. The Dokploy UI itself is then only reachable via Pangolin
   (or `http://<HOST_LAN_IP>:3000` on the LAN, keep this as your escape hatch).

Apps are unreachable from the internet from step 3 here until the HTTP resources exist (section 3, step 2). Use a maintenance window.

## 2. Deploy the Pangolin stack in Dokploy
1. Dokploy → Project → **Create Service → Compose**, source = this repo (or paste `docker-compose.yml`).
2. The compose file joins the external `dokploy-network` (already exists). Config lives in `./config`; use
   Dokploy **File Mounts** or a fixed host path for `config/` so redeploys don't wipe the DB and certs
   (Dokploy cleans absolute bind paths and re-clones repos, see its compose docs). Back this directory up:
   it is now critical infrastructure.
   Rendered configs are gitignored, so Dokploy's clone won't contain them: run `./render.sh` once in the deployed `config` location on the host (or create them as File Mounts).
3. Don't set `NEWT_ID/NEWT_SECRET` yet. Deploy only the first three services:
   ```bash
   docker compose up -d pangolin gerbil traefik
   docker compose logs pangolin     # copy the setup token
   ```
   (In the Dokploy UI, deploy then stop/disable `newt`, or temporarily comment it out.)
4. Open `https://pangolin.$DOMAIN/auth/initial-setup`, enter the token, create the admin and an org.

## 3. Site, web apps, WoW
1. **Sites → Add** a Newt site, copy ID/secret into Dokploy env (`NEWT_ID`, `NEWT_SECRET`), start `newt`.
   The site should show *online*.
2. **HTTP resources** (SSO on): one per app, e.g. `dokploy.$DOMAIN` → `http://dokploy-traefik:8081`
   (Host header is preserved, so Dokploy's routing still works). *Not* port 80 anymore.
3. **Private resources**, type Host: `<HOST_LAN_IP>` TCP `3724` and `8085`, access = role `wow-players`. Invite friends into that role.
4. On the live DB (ops step, not repo SQL):
   ```sql
   UPDATE acore_auth.realmlist SET address='<HOST_LAN_IP>', localAddress='<HOST_LAN_IP>' WHERE id=1;
   ```
   Friends: install the Pangolin client, log in, `set realmlist <HOST_LAN_IP>` in `realmlist.wtf`.
   If their LAN uses the same subnet as yours, routes collide: use an uncommon subnet or a secondary IP for WoW.

## 4. Verify
- `https://pangolin.$DOMAIN` has a valid cert; `https://dokploy.$DOMAIN` shows the Pangolin login first.
- From mobile data, no client: `nc -vz <public-ip> 3724` / `8085` fail. `nmap -p 1-10000 <ip>` shows only 80/443;
  `nmap -sU -p 21820,51820 <ip>` shows those open|filtered.
- With the client as a `wow-players` user: `nc -vz <HOST_LAN_IP> 3724` and `8085` succeed, WoW logs in and enters the world.
  A user outside the role can't connect.
- Redeploy an app: it still routes, and `dokploy-traefik` did not reclaim 80/443.

## Gotchas
- Never set `allow_raw_resources: true`: public raw TCP bypasses Pangolin auth.
- Dokploy updates recreate Traefik from the env vars above; keep them on the service.
- Optional: bind SOAP `7878` to `127.0.0.1` in the azerothcore repo's `docker-compose.dokploy.yml`.
- Optional: [dokploy-to-pangolin](https://github.com/orochibraru/dokploy-to-pangolin) auto-creates HTTP resources; it defaults to HTTPS :443 targets, so point it at `:8081` HTTP.
