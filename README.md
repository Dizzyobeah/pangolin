# Pangolin edge for a Dokploy host

Pangolin (Gerbil + Traefik) takes over host ports 80/443 as the public reverse proxy and SSO layer.
Dokploy's own Traefik moves to high ports and sits behind it. WoW (raw TCP) is exposed only as
Pangolin *private resources*, reachable through the Pangolin client after login.

```
Internet ─ 80/443 ─► Pangolin Traefik (in gerbil netns) ─ SSO ─► dokploy-traefik:8081 ─► apps
         └ 21820/51820 UDP ─► Gerbil ◄─ Newt (outbound) ─► <HOST_LAN_IP>:3724 / :8085
```

`DOMAIN`, `PANGOLIN_PREFIX` (dashboard subdomain, default `pangolin`), `LE_EMAIL` and `PANGOLIN_SECRET` come from `.env`. Remaining placeholder: `<HOST_LAN_IP>`. Full background: `docs/pangolin-edge-wow-access.md`.

## Files
| Path | Purpose |
|---|---|
| `docker-compose.yml` | render-config (init), pangolin, gerbil, traefik, newt |
| `config/*.tmpl` | Pangolin + Traefik config templates, rendered on deploy |
| `.env.example` | `DOMAIN`, `PANGOLIN_PREFIX`, `LE_EMAIL`, `PANGOLIN_SECRET`, `NEWT_ID`, `NEWT_SECRET` |

Runtime state is **not** in the repo. It lives in `../files/pangolin/` on the host (see "Persistent storage" below).

## 0. Prerequisites
- Dokploy running on the host, wildcard DNS `*.$DOMAIN` and `$PANGOLIN_PREFIX.$DOMAIN` pointing at your home IP.
- Router forwards TCP 80/443 and **UDP 21820 + 51820** to the host.
- **Snapshot/back up the host first** (including `files/pangolin` once it exists). Rollback = step 2 in reverse (unset the env vars, reload Traefik, restore `traefik.yml`).
- Set the env vars in Dokploy (see step 2.1). `PANGOLIN_SECRET`: generate with `openssl rand -hex 32`.

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
3. Recreate Traefik. Host port bindings are fixed when the container is created, so a restart or reload keeps the old 80/443 bindings. Either:
   - **Settings → Web Server → Traefik → Ports**, then **Save** (rebuilds the container), or
   - Remove it and recreate it by hand (this run did not recreate it on Dokploy restart): `docker rm -f dokploy-traefik`, then `docker run -d --name dokploy-traefik --restart always --network dokploy-network -p 8081:8081 -p 8444:8444 -p 8444:8444/udp -v /etc/dokploy/traefik/traefik.yml:/etc/traefik/traefik.yml -v /etc/dokploy/traefik/dynamic:/etc/dokploy/traefik/dynamic -v /var/run/docker.sock:/var/run/docker.sock:ro traefik:v3.6.25` (use the image tag Dokploy pins; `v3.6.25` was used here).
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

### 2.1 Create the compose app and environment
1. Dokploy → your project → **Create Service → Compose**. Source: this git repo, branch `main`
   (or the branch with the stack), compose path `docker-compose.yml`.
2. Open the service's **Environment** tab and set:
   ```env
   DOMAIN=example.com
   PANGOLIN_PREFIX=pangolin
   LE_EMAIL=you@example.com
   PANGOLIN_SECRET=<openssl rand -hex 32>
   NEWT_ID=<leave empty until step 3>
   NEWT_SECRET=<leave empty until step 3>
   ```
   These are written to a `.env` next to the compose file and read by the compose file. They are not
   injected into containers on their own, but the compose file passes them to each service that needs them.

### 2.2 Persistent storage (why there are no File Mounts)
The compose file mounts all runtime state from `../files/pangolin` instead of the repo folder:

| Host path (`../files/pangolin/...`) | Contents | Created by |
|---|---|---|
| `config.yml` | Pangolin config, rendered from `config/config.yml.tmpl` | render-config (first deploy) |
| `traefik/traefik_config.yml`, `traefik/dynamic_config.yml` | Pangolin's Traefik config | render-config (first deploy) |
| `db/` | Pangolin SQLite database. **Losing it means losing users and resources.** | pangolin |
| `key` | Gerbil WireGuard key. Losing it breaks every client's tunnel. | gerbil |
| `letsencrypt/` | TLS certificates | traefik |

Why not Dokploy **File Mounts**: File Mounts (Advanced → Mounts) are meant for individual files taken from the repo
through the UI. This stack needs whole directories (the database, certificates and key) to persist. Dokploy's
docs say that the repo folder is cleared on each AutoDeploy git clone, while bind mounts under `../files` persist
across deploys. So the compose file uses `../files`, and nothing needs to be created in the UI. Back up
`../files/pangolin` on the host.

**Render-once behaviour:** `render-config` writes each of the three config files only if it does not exist yet.
Changing `DOMAIN`, `PANGOLIN_PREFIX`, `LE_EMAIL` or `PANGOLIN_SECRET` later does **not** update existing files.
To pick up a change, edit the file on the host (`../files/pangolin/...`) or use Option B below, then restart the services.

### 2.2a Option B: edit the config files in Dokploy File Mounts
Use this if you want to edit the rendered config in the Dokploy UI instead of on the host.
Dokploy writes File Mounts to the same folder as the rendered files, so a non-empty File Mount overrides the rendered file.

**Do the first deploy (2.3) before you create any File Mount.** The rendered files only exist after `render-config` has run.

1. Copy the rendered content. The containers have fixed names, so this works from a shell on the host or from the Dokploy terminal:
   ```bash
   docker exec pangolin cat /app/config/config.yml
   docker exec traefik  cat /etc/traefik/traefik_config.yml
   docker exec traefik  cat /etc/traefik/dynamic_config.yml
   ```
   On the host the same files are in `/etc/dokploy/compose/<appName>/files/pangolin/`. `<appName>` is the compose
   service's app name in Dokploy (`ls /etc/dokploy/compose/` lists them).
2. Open the compose service → **Advanced → Mounts → Add Mount → File**.
3. File path `pangolin/config.yml`, content = the output of the first command. Repeat with
   `pangolin/traefik/traefik_config.yml` and `pangolin/traefik/dynamic_config.yml`.
   **Paste the content before saving.** An empty mount writes an empty file. `render-config` re-renders empty
   files on the next deploy, which replaces the mount content with the rendered version.
4. Redeploy, or restart `pangolin`, `gerbil` and `traefik`.

**If the files are missing or empty:**
- `ls -la /etc/dokploy/compose/<appName>/files/pangolin/`. If there is no `files/pangolin`, `render-config` never ran:
  check the deploy log for `set DOMAIN` (or another missing env var) and `docker logs pangolin-render-config`.
- If a file is empty, it was probably created by a File Mount saved without content. Redeploy: `render-config`
  fills empty files. Then copy the content (step 1) and paste it into the mount.

Trade-offs:
- The content is static text. The env vars no longer apply to that file.
- The `server.secret` (`PANGOLIN_SECRET`) ends up stored in Dokploy's database. Keep the Dokploy instance and its backups protected.
- I have not verified the Mounts screen in the Dokploy UI. The file location is taken from Dokploy's source (`packages/server/src/services/mount.ts`).

### 2.3 Deploy the first three services
1. Deploy the compose app with `NEWT_ID` and `NEWT_SECRET` empty. Dokploy starts `render-config`, then `pangolin`,
   `gerbil` and `traefik`. `newt` will fail to start without its ID and secret. That is expected for now.
2. Check the logs. `pangolin` should start without "No configuration file found". Then copy the setup token:
   ```bash
   docker logs pangolin 2>&1 | grep -i token
   ```
3. Open `https://$PANGOLIN_PREFIX.$DOMAIN/auth/initial-setup`, enter the token, create the admin and an org.

If `pangolin` still fails with "No configuration file found", check that `render-config` finished with exit code 0
and that `../files/pangolin/config.yml` exists on the host.

## 3. Site, web apps, WoW
1. **Sites → Add → Pangolin Site** (Newt), e.g. `dokploy-host`. Ignore the `pangolin up site` command; copy only the ID/secret
   into the Dokploy Environment tab (`NEWT_ID`, `NEWT_SECRET`), then **redeploy** (a restart keeps the old, empty env).
   The site should show *online*. This site is for client/private resources (WoW).
2. **Sites → Add → Local**, e.g. `lan`. Use it for every HTTP resource: Pangolin's Traefik runs on this host and reaches
   LAN/Docker targets directly. Through the Newt site we got 502s: Newt on the same host as gerbil sends its tunnel
   traffic to the public endpoint, which (presumably) needs hairpin NAT for UDP.
3. **HTTP resources** on the `lan` site, **Authentication → Use Platform SSO** on, limited in Users & Roles:
   one per app, e.g. `dokploy.$DOMAIN` → `http://dokploy-traefik:8081`
   (Host header is preserved, so Dokploy's routing still works). *Not* port 80 anymore.
   LAN devices work too, e.g. Home Assistant `http://<HA_IP>:8123`. HA answers 400 until you add
   `http: {use_x_forwarded_for: true, trusted_proxies: [<LAN_CIDR>]}` to its `configuration.yaml`. With SSO on, the HA
   companion app can't log in. Use the browser, or the Pangolin client.
4. **Private resources**, type Host: `<HOST_LAN_IP>` TCP `3724` and `8085`, access = role `wow-players`. Invite friends into that role.
5. On the live DB (ops step, not repo SQL):
   ```sql
   UPDATE acore_auth.realmlist SET address='<HOST_LAN_IP>', localAddress='<HOST_LAN_IP>' WHERE id=1;
   ```
   Friends: install the Pangolin client, log in, `set realmlist <HOST_LAN_IP>` in `realmlist.wtf`.
   If their LAN uses the same subnet as yours, routes collide: use an uncommon subnet or a secondary IP for WoW.

## 4. Verify
- `https://$PANGOLIN_PREFIX.$DOMAIN` has a valid cert; `https://dokploy.$DOMAIN` shows the Pangolin login first.
- From mobile data, no client: `nc -vz <public-ip> 3724` / `8085` fail. `nmap -p 1-10000 <ip>` shows only 80/443;
  `nmap -sU -p 21820,51820 <ip>` shows those open|filtered.
- With the client as a `wow-players` user: `nc -vz <HOST_LAN_IP> 3724` and `8085` succeed, WoW logs in and enters the world.
  A user outside the role can't connect.
- Redeploy an app: it still routes, and `dokploy-traefik` did not reclaim 80/443.

## Gotchas
- Never set `allow_raw_resources: true`: public raw TCP bypasses Pangolin auth.
- Keep the `TRAEFIK_*` env vars on the Dokploy service: whenever Dokploy creates `dokploy-traefik`, it takes the ports from them. Restarting the Dokploy service did **not** recreate a missing `dokploy-traefik` here (see step 1.3).
- Pangolin's `traefik` shares gerbil's network (`network_mode: service:gerbil`). If gerbil is recreated or fails to start (for example because 80/443 were still taken), `traefik` keeps a dead network: every lookup fails with `network is unreachable`, the badger plugin doesn't load, and `acme.json` stays empty. Fix: recreate both together (redeploy in Dokploy).
- `newt` starts even with an empty `NEWT_ID` and loops on `No newt found with that newtId`. Check `docker inspect newt --format '{{range .Config.Env}}{{println .}}{{end}}' | grep NEWT_ID`. If it's empty, set the env and redeploy.
- Running `docker compose` by hand: Dokploy uses its own project name, so pass `-p "$(docker inspect pangolin --format '{{index .Config.Labels "com.docker.compose.project"}}')"` and `--no-deps`. Otherwise you get container-name conflicts.
- Optional: bind SOAP `7878` to `127.0.0.1` in the azerothcore repo's `docker-compose.dokploy.yml`.
- Optional: [dokploy-to-pangolin](https://github.com/orochibraru/dokploy-to-pangolin) auto-creates HTTP resources; it defaults to HTTPS :443 targets, so point it at `:8081` HTTP.
