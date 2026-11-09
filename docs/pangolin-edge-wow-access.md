# Pangolin at home as the edge and auth layer (Option C)

## Context
Friends need to reach the AzerothCore server (auth 3724/TCP, world 8085/TCP) running on Dokploy at home. They should log in first. Today the router forwards only 80/443.

The 3.3.5a client speaks raw TCP, so an HTTP login page can't sit in front of it. Pangolin's **private resources** solve this: a friend runs the Pangolin client, logs in, and gets WireGuard access only to the resources granted to them.

Decisions taken:
- Pangolin is hosted at home on the Dokploy host.
- Pangolin's Traefik becomes the edge on 80/443. Dokploy's Traefik moves behind it.
- The router additionally forwards **UDP 21820 and 51820**. These are WireGuard ports and carry no unauthenticated service.

## Target topology
```
Internet ── 80/443 TCP ──► Pangolin Traefik (gerbil netns) ── SSO ──► dokploy-traefik ──► web apps / Dokploy UI
         └─ 21820/51820 UDP ► Gerbil ◄── Newt site (outbound) ──► <HOST_LAN_IP>:3724 / :8085 (WoW)
Friend: Pangolin client ──login──► Pangolin ──WG──► Gerbil ──► Newt ──► WoW
```

## Steps

### 1. Move Dokploy's Traefik off 80/443
- Recreate `dokploy-traefik` without host bindings on 80/443. It only needs to listen inside `dokploy-network`, or on high ports such as 8080/8443. Dokploy supports `TRAEFIK_PORT` / `TRAEFIK_SSL_PORT`, but [issue #804](https://github.com/Dokploy/dokploy/issues/804) reports routing broke after using them, so **verify on a snapshot first** and check current Dokploy docs/source.
- Pangolin now terminates TLS, so Let's Encrypt HTTP-01 challenges no longer reach Dokploy's Traefik. Switch existing Dokploy domains to HTTP only (HTTPS off). Pangolin then forwards `http://dokploy-traefik:80` with the `Host` header preserved.
- Rollback: restore the original `dokploy-traefik` ports.

### 2. Deploy Pangolin as a Dokploy compose app
- Use the official compose from [docs.pangolin.net/self-host/manual/docker-compose](https://docs.pangolin.net/self-host/manual/docker-compose), with the `pangolin`, `gerbil` and `traefik` services (traefik in `network_mode: service:gerbil`).
- Gerbil publishes `80:80`, `443:443`, `51820:51820/udp` and `21820:21820/udp`.
- Attach Gerbil to `dokploy-network` so Pangolin's Traefik can reach `dokploy-traefik`.
- Keep `config/` (config.yml, Traefik static and dynamic config, letsencrypt) in a persistent volume or bind path. Back it up, because this is now critical infrastructure.
- In `config.yml`: set `dashboard_url: https://pangolin.<domain>`, `base_domain`, the Let's Encrypt email, and leave `allow_raw_resources` off (public raw TCP bypasses auth).
- DNS: wildcard `*.<domain>` pointing at the home IP (or use DDNS).
- Router: forward TCP 80/443 (already done) and **UDP 21820 and 51820** to the host.

### 3. Sites
- **Newt site ("home")**: run a `fosrl/newt` container on `dokploy-network` with the ID and secret from the Pangolin UI, endpoint `https://pangolin.<domain>`. Private resources require a Newt (Pangolin) site.
- Use the same site for public HTTP resources that target `dokploy-traefik:80`.

### 4. Web apps behind Pangolin SSO
- Create HTTP resources such as `dokploy.<domain>` and existing app domains, targeting `dokploy-traefik:80` (or `dokploy:3000` for the Dokploy UI directly). Enable Pangolin auth.
- Optional, later: [dokploy-to-pangolin](https://github.com/orochibraru/dokploy-to-pangolin) auto-creates HTTP resources on deploy. By default it targets the site on **443/HTTPS**, so either change it to HTTP :80 or enable TLS-skip-verify against Dokploy's self-signed cert. It does not handle the WoW ports.

### 5. WoW as private resources
- Create two private **Host** resources on the Newt site: `<HOST_LAN_IP>` TCP 3724 and TCP 8085. Target the host LAN IP, not Docker IPs, because those change.
- Grant access to a "wow-players" role, and invite friends into that role.
- **AzerothCore change (DB only, no code):** the authserver resolves `realmlist.address` server-side and sends the client an IP (`src/server/shared/Realms/RealmList.cpp:163`). That IP must be one the Pangolin client routes:
  ```sql
  UPDATE acore_auth.realmlist SET address='<HOST_LAN_IP>', localAddress='<HOST_LAN_IP>' WHERE id=1;
  ```
  Run it as an ops step against the live DB, not as a repo SQL file. Restart the authserver, or wait for `RealmsStateUpdateDelay`.
- Friends: install the Pangolin client, log in, then set `set realmlist <HOST_LAN_IP>` in `realmlist.wtf`.
- Known caveat: if a friend's home LAN uses the same subnet as your host IP, routes collide. Mitigation: give the host a less common LAN subnet, or a secondary IP used only for WoW.
- Optional hardening: in `docker-compose.dokploy.yml`, bind `7878` (SOAP) to `127.0.0.1` so it's never reachable through any route. No other repo changes are needed.

### 6. Save plan to vault
Copy this plan to `/Users/calund/projects/Claude/projects/azerothcore-wotlk/plans/2026-11-09-pangolin-edge-wow-access.md` and log the decision in the session note.

## Verification
1. From outside (mobile data): `https://pangolin.<domain>` loads with a valid cert, and `https://dokploy.<domain>` shows the Pangolin login before the Dokploy UI.
2. From outside without the Pangolin client: `nc -vz <public-ip> 3724` and `8085` fail. Only 80/443 TCP and 21820/51820 UDP are open (check with `nmap -sU -p 21820,51820` and `nmap -p 1-10000`).
3. With the Pangolin client connected as a test user: `nc -vz <HOST_LAN_IP> 3724` and `8085` succeed, the WoW client logs in, the realm list shows the realm, and entering the world works.
4. A user not in the wow-players role, connected with the client, can't reach 3724/8085.
5. Existing Dokploy apps still deploy and route, and redeploying an app doesn't reclaim 80/443.
