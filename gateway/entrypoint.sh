#!/bin/sh
# Builds the address lists the Caddyfile filters on, then runs Caddy.
#
# DOCKER_GATEWAYS: the bridge gateway of every network this container is attached to. Docker's userland proxy
# relays IPv6 and loopback connections to published ports from that address, which hides the real client (it may
# be on the internet), so those connections are always refused.
# ALLOWED_NETWORKS: from the install form; commas or spaces separate ranges.
# UPSTREAM: SearXNG's address on the DAppNode network.
set -eu

gateways=$(ip -4 route | awk '
  $1 == "default" { print $3; next }
  $2 == "dev" && $1 ~ /\// {
    split($1, a, "/"); split(a[1], o, ".")
    printf "%d.%d.%d.%d\n", o[1], o[2], o[3], o[4] + 1   # Docker IPAM: gateway = first address of the subnet
  }' | sort -u | tr '\n' ' ')
[ -n "$gateways" ] || { echo "gateway: could not determine Docker bridge gateways" >&2; exit 1; }

allowed=$(printf '%s' "${ALLOWED_NETWORKS:-}" | tr ',' ' ' | xargs)
[ -n "$allowed" ] || { echo "gateway: ALLOWED_NETWORKS is empty" >&2; exit 1; }

export DOCKER_GATEWAYS="$gateways" ALLOWED_NETWORKS="$allowed"
export UPSTREAM="${UPSTREAM:-searxng.searxng-lan.public.dappnode:8080}"
echo "gateway: allowing [$ALLOWED_NETWORKS], refusing proxied sources [$DOCKER_GATEWAYS], upstream $UPSTREAM"
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
