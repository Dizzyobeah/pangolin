# Cutover runbook (placeholders: <LE_EMAIL>, <HOST_LAN_IP>)

Set DOMAIN in .env, run ./render.sh; fill the rest: `grep -rn '<LE_EMAIL>\|<GENERATE' config`.
Secret: `openssl rand -hex 32` into `config/config.yml` `server.secret`.

## 0. Snapshot host / back up dokploy-traefik config. Rollback = restore its 80/443 bindings.

## 1. Free 80/443 (UNVERIFIED — test first)
Issue #804 is closed "not planned"; the env-var route (`TRAEFIK_PORT`/`TRAEFIK_SSL_PORT`) was reported broken on old versions,
and a maintainer says current versions manage ports in the UI: **Dokploy → Web Server → Traefik → Ports**.
Superseded: see README.md section 1 (TRAEFIK_PORT / TRAEFIK_SSL_PORT / TRAEFIK_HTTP3_PORT env vars on the dokploy service; the UI cannot remove 80/443).
Check after: `docker ps --format '{{.Names}} {{.Ports}}' | grep traefik`; `sudo lsof -i :80 -i :443` empty.
Then set existing Dokploy domains to HTTP only (HTTPS off) — Pangolin terminates TLS.

## 2. Deploy
Router: forward TCP 80/443 + UDP 21820, 51820. DNS: `pangolin.$DOMAIN` and `*.$DOMAIN` -> home IP.
`docker compose up -d pangolin gerbil traefik`; `docker compose logs pangolin` for setup token;
open `https://pangolin.$DOMAIN/auth/initial-setup`.

## 3. Site + resources (Pangolin UI)
Create a Newt site -> put NEWT_ID/NEWT_SECRET in Dokploy env -> `docker compose up -d newt`.
HTTP resources: `dokploy.$DOMAIN` etc -> `dokploy-traefik:8081`, auth on.
Private Host resources: `<HOST_LAN_IP>` TCP 3724 and 8085; role `wow-players`.

## 4. Realmlist (live DB, ops step)
`UPDATE acore_auth.realmlist SET address='<HOST_LAN_IP>', localAddress='<HOST_LAN_IP>' WHERE id=1;`

## 5. Verify
See docs/pangolin-edge-wow-access.md "Verification" (incl. external nmap: only 80/443 TCP, 21820/51820 UDP).
