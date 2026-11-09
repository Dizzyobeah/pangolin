#!/bin/sh
# Render config templates from .env (Pangolin/Traefik configs can't read env vars themselves).
set -eu
cd "$(dirname "$0")"
set -a; . ./.env; set +a
: "${DOMAIN:?set DOMAIN in .env}"
for t in config/config.yml.tmpl config/traefik/dynamic_config.yml.tmpl; do
  envsubst '${DOMAIN}' < "$t" > "${t%.tmpl}"
done
echo "rendered for DOMAIN=$DOMAIN"
