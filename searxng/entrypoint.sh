#!/bin/sh
# Settings come from the image on every start, so package updates apply them; only the secret key persists.
# Then hands over to the upstream entrypoint, which finds settings.yml in place and starts Granian.
set -eu

# Per-install secret: it signs image-proxy links (so the proxy only fetches images this instance linked) and the
# preference cookies. Generated once into the data volume; never logged.
key=/var/cache/searxng/secret_key
if [ ! -s "$key" ]; then
  umask 077
  head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 48 > "$key.tmp"
  mv "$key.tmp" "$key"
fi
SEARXNG_SECRET=$(cat "$key")
export SEARXNG_SECRET

settings=/etc/searxng/settings.yml
cp /usr/local/searxng/searxng-lan-settings.yml "$settings"
proxy="${OUTGOING_PROXY:-}"
if [ -n "$proxy" ]; then
  # Install-form input goes into YAML: accept only a plain proxy URL.
  if ! printf '%s' "$proxy" | grep -Eq '^(https?|socks5h?)://[A-Za-z0-9._~%:@/+-]+$'; then
    echo "searxng-lan: OUTGOING_PROXY must look like http://host:port or socks5h://host:port" >&2
    exit 1
  fi
  printf '\noutgoing:\n  proxies:\n    "all://":\n      - "%s"\n' "$proxy" >> "$settings"
  echo "searxng-lan: search engine requests go through the configured proxy"
fi

exec /usr/local/searxng/entrypoint.sh
