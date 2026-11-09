#!/bin/sh
# Optional local render (compose does this itself via the render-config service).
set -eu
cd "$(dirname "$0")"
set -a; . ./.env; set +a
: "${DOMAIN:?set DOMAIN in .env}" "${LE_EMAIL:?set LE_EMAIL in .env}" "${PANGOLIN_PREFIX:?set PANGOLIN_PREFIX in .env}" "${PANGOLIN_SECRET:?set PANGOLIN_SECRET in .env}"
for t in config/config.yml.tmpl config/traefik/traefik_config.yml.tmpl config/traefik/dynamic_config.yml.tmpl; do
  envsubst '${DOMAIN} ${LE_EMAIL} ${PANGOLIN_PREFIX} ${PANGOLIN_SECRET}' < "$t" > "${t%.tmpl}"
done
echo "rendered for DOMAIN=$DOMAIN"
