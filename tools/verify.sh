#!/usr/bin/env bash
# Automated fact checks for the searxng-lan package. Run it on the Docker host of the stack under test.
#
#   TARGET=dev      compose project sx-dev (dev/compose.override.yml), host port 18080
#   TARGET=ci       compose project sx-ci  (dev/compose.ci.yml), host port 8080
#   TARGET=package  the installed DAppNode package; PORT = its host port from the install form
#
# usage: tools/verify.sh [all|quick]    quick = the CI subset (no live searches: engines rate-limit CI runners)
#
# Test clients reach the gateway container directly on two throwaway networks (192.168.250.0/24 allowed,
# 198.18.0.0/24 outside), so the gateway sees their real address. Traffic from other containers to the published
# port is masqueraded to a Docker bridge gateway and refused for that reason alone. The secret key is only ever
# compared by fingerprint, never printed.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${TARGET:-dev}"
MODE="${1:-all}"
case "$TARGET" in
  dev) GW=sx-dev-gateway-1 SX=sx-dev-searxng-1 PORT="${PORT:-18080}"
       COMPOSE=(docker compose -p sx-dev -f docker-compose.yml -f dev/compose.override.yml) ;;
  ci) GW=sx-ci-gateway-1 SX=sx-ci-searxng-1 PORT="${PORT:-8080}"
      COMPOSE=(docker compose -p sx-ci -f docker-compose.yml -f dev/compose.ci.yml) ;;
  package) GW=DAppNodePackage-gateway.searxng-lan.public.dappnode.eth SX=DAppNodePackage-searxng.searxng-lan.public.dappnode.eth
           : "${PORT:?set PORT to the package host port}" ;;
  *) echo "TARGET must be dev, ci or package" >&2; exit 2 ;;
esac
PY=python:3.13-alpine3.22
PROXY_IMAGE=gogost/gost:3.3.0
ALLOWED_NET=sx-test-allowed ALLOWED_IP=192.168.250.10
OUTSIDE_NET=sx-test-outside OUTSIDE_IP=198.18.0.10
fails=0
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }

cleanup() {
  local n
  for n in $ALLOWED_NET $OUTSIDE_NET; do
    docker network disconnect -f "$n" "$GW" >/dev/null 2>&1 || true
    docker network rm "$n" >/dev/null 2>&1 || true
  done
  docker rm -fv sx-test-proxy sx-test-fresh >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_healthy() {
  local i
  for i in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$SX" 2>/dev/null)" = healthy ] && return 0
    sleep 2
  done
  return 1
}

probe() { # $1 allowed|outside, $2 comma list of probe.py checks
  local net=$ALLOWED_NET ip=$ALLOWED_IP out
  [ "$1" = outside ] && net=$OUTSIDE_NET ip=$OUTSIDE_IP
  out=$(docker run --rm --network "$net" -v "$PWD/tools/probe.py:/probe.py:ro" "$PY" \
        python -u /probe.py "http://$ip:8080" "$2" 2>&1) || true
  printf '%s\n' "$out"
  fails=$((fails + $(printf '%s\n' "$out" | grep -c '^FAIL' || true)))
}

check_static() { # fact pinned-image
  local sx caddy
  sx=$(sed -n 's/^ *SEARXNG_VERSION: *//p' docker-compose.yml)
  caddy=$(sed -n 's/^ *CADDY_VERSION: *//p' docker-compose.yml)
  if [[ $sx =~ ^[0-9]{4}\.[0-9]+\.[0-9]+-[0-9a-f]+$ && $caddy =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
     && ! grep -n -i ':latest\|-latest' docker-compose.yml gateway/Dockerfile searxng/Dockerfile >/dev/null; then
    pass "images pinned: searxng $sx, caddy $caddy (no 'latest')"
  else
    fail "images not pinned (searxng '$sx', caddy '$caddy')"
  fi
}

check_hidden_source() { # fact hidden-source-403: Docker's userland proxy hides IPv6/loopback clients
  local c4 c6
  c4=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://127.0.0.1:$PORT/" || true)
  c6=$(curl -g -s -o /dev/null -m 8 -w '%{http_code}' "http://[::1]:$PORT/" || true)
  [ "$c4" = 403 ] && pass "loopback IPv4 client relayed by Docker refused (403)" || fail "loopback IPv4 client got $c4"
  case "$c6" in 403|000) pass "loopback IPv6 client refused or not served ($c6)" ;; *) fail "loopback IPv6 client got $c6" ;; esac
}

check_private() { # fact private-instance
  local s valkey
  s=$(docker exec "$SX" cat /etc/searxng/settings.yml)
  valkey=$(docker ps -a --format '{{.Names}}' | grep -i -E '(sx-dev|sx-ci|searxng-lan).*(valkey|redis)' || true)
  if grep -q '^ *limiter: false' <<<"$s" && grep -q '^ *public_instance: false' <<<"$s" && [ -z "$valkey" ]; then
    pass "private instance: limiter off, not public, no Valkey/Redis container"
  else
    fail "private-instance settings or a Valkey container (${valkey:-none})"
  fi
}

secret_fp() { # fingerprint of the key file and of the key the running process got
  docker exec "$SX" sh -c "tr -d '\n' < /var/cache/searxng/secret_key | sha256sum | cut -c1-12; \
    tr '\0' '\n' < /proc/1/environ | sed -n 's/^SEARXNG_SECRET=//p' | tr -d '\n' | sha256sum | cut -c1-12" | tr '\n' ' '
}

check_secret() { # facts secret, persistence (restart/recreate)
  local len fp file env placeholder img fresh
  len=$(docker exec "$SX" sh -c 'wc -c < /var/cache/searxng/secret_key' | tr -d ' ')
  read -r file env <<<"$(secret_fp)"
  placeholder=$(printf %s ultrasecretkey | sha256sum | cut -c1-12)
  if [ "${len:-0}" -ge 32 ] && [ "$file" = "$env" ] && [ "$file" != "$placeholder" ]; then
    pass "per-install secret: $len chars, in use by SearXNG, not the placeholder (fingerprint $file)"
  else
    fail "secret: length ${len:-?}, file $file, process $env"
  fi
  img=$(docker inspect -f '{{.Config.Image}}' "$SX")
  docker run -d --name sx-test-fresh --user 977:977 --cap-drop ALL --security-opt no-new-privileges "$img" >/dev/null
  sleep 8
  fresh=$(docker exec sx-test-fresh sh -c "tr -d '\n' < /var/cache/searxng/secret_key | sha256sum | cut -c1-12" 2>/dev/null || echo none)
  docker rm -fv sx-test-fresh >/dev/null
  [ "$fresh" != none ] && [ "$fresh" != "$file" ] && pass "a fresh install generates a different secret ($fresh)" \
    || fail "fresh install secret: $fresh (this one: $file)"
  docker restart "$SX" >/dev/null && wait_healthy || { fail "searxng not healthy after restart"; return; }
  fp=$(secret_fp)
  [ "$fp" = "$file $env " ] && pass "secret unchanged after restart" || fail "secret changed after restart ($fp)"
  if [ -n "${COMPOSE+x}" ]; then
    "${COMPOSE[@]}" up -d --force-recreate searxng >/dev/null 2>&1 && wait_healthy || { fail "not healthy after recreate"; return; }
    fp=$(secret_fp)
    [ "$fp" = "$file $env " ] && pass "secret unchanged after recreating the container" || fail "secret changed after recreate ($fp)"
  fi
}

check_hardening() { # fact hardening
  local c sec add drop priv net devs sock uids
  for c in "$GW" "$SX"; do
    sec=$(docker inspect -f '{{json .HostConfig.SecurityOpt}}' "$c")
    add=$(docker inspect -f '{{json .HostConfig.CapAdd}}' "$c")
    drop=$(docker inspect -f '{{json .HostConfig.CapDrop}}' "$c")
    priv=$(docker inspect -f '{{.HostConfig.Privileged}}' "$c")
    net=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$c")
    devs=$(docker inspect -f '{{range .HostConfig.Devices}}{{.PathOnHost}} {{end}}' "$c")
    sock=$(docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' "$c" | grep -c docker.sock || true)
    uids=$(docker top "$c" -o uid | tail -n +2 | sort -u | tr '\n' ' ')
    if [[ $sec == *no-new-privileges* && ( $add == null || $add == '[]' ) && $drop == *ALL* && $priv == false \
          && $net != host && -z $devs && $sock == 0 && " $uids" != *" 0 "* && -n $uids ]]; then
      pass "$c hardened: no-new-privileges, all capabilities dropped, process uids $uids"
    else
      fail "$c: secopt $sec, capadd $add, capdrop $drop, privileged $priv, net $net, devices '$devs', socket $sock, uids '$uids'"
    fi
  done
}

check_proxy() { # fact proxy (dev only: recreates searxng with OUTGOING_PROXY)
  local url before new
  docker run -d --name sx-test-proxy --network dncore_network "$PROXY_IMAGE" -L http://:3128 -L socks5://:1080 >/dev/null
  for url in http://sx-test-proxy:3128 socks5h://sx-test-proxy:1080 ""; do
    OUTGOING_PROXY="$url" "${COMPOSE[@]}" up -d searxng >/dev/null 2>&1 && wait_healthy || { fail "searxng not healthy with proxy '$url'"; continue; }
    before=$(docker logs sx-test-proxy 2>&1 | wc -l)
    docker run --rm --network $ALLOWED_NET -v "$PWD/tools/probe.py:/probe.py:ro" "$PY" \
      python -u /probe.py "http://$ALLOWED_IP:8080" search-once >/dev/null 2>&1 || true
    new=$(docker logs sx-test-proxy 2>&1 | tail -n +$((before + 1)) | grep -c -i -E 'google|bing|duckduckgo|wikipedia|brave|startpage|qwant|mojeek|wikidata' || true)
    if [ -n "$url" ]; then
      [ "$new" -gt 0 ] && pass "engine requests go through the ${url%%:*} proxy ($new logged)" || fail "nothing went through the ${url%%:*} proxy"
    else
      [ "$new" -eq 0 ] && pass "no proxy configured: engine requests go direct" || fail "requests still hit the proxy with OUTGOING_PROXY empty ($new)"
    fi
  done
}

echo "== verify $TARGET (mode $MODE, port $PORT)"
check_static
docker inspect "$GW" "$SX" >/dev/null 2>&1 || { fail "containers $GW / $SX not found"; echo "fails: $fails"; exit 1; }
wait_healthy && pass "searxng healthy" || fail "searxng not healthy"
cleanup
docker network create --subnet 192.168.250.0/24 $ALLOWED_NET >/dev/null
docker network create --subnet 198.18.0.0/24 $OUTSIDE_NET >/dev/null
docker network connect --ip $ALLOWED_IP $ALLOWED_NET "$GW"
docker network connect --ip $OUTSIDE_IP $OUTSIDE_NET "$GW"
check_hidden_source
probe outside forbidden
if [ "$MODE" = quick ]; then
  probe allowed page
else
  probe allowed page,results,opensearch,image-proxy,autocomplete,defaults
  check_private
fi
check_secret
check_hardening
[ "$TARGET" = dev ] && [ "$MODE" = all ] && check_proxy
echo "fails: $fails"
exit $((fails > 0))
