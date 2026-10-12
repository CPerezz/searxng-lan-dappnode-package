ARG CADDY_VERSION
FROM caddy:${CADDY_VERSION}-alpine AS caddy

# The upstream binary carries the cap_net_bind_service file capability, which can't be exec'd with all capabilities
# dropped and no-new-privileges (the gateway binds only 8080). COPY keeps file capabilities, so strip it in a stage
# that runs on the build machine's own architecture: setcap only edits the file's xattr, so arm64 builds on an amd64
# host need no emulation.
FROM --platform=$BUILDPLATFORM alpine:3.22 AS strip
RUN apk add --no-cache libcap
COPY --from=caddy /usr/bin/caddy /caddy
RUN setcap -r /caddy

FROM caddy
COPY --from=strip /caddy /usr/bin/caddy
COPY --chmod=0644 Caddyfile /etc/caddy/Caddyfile
COPY --chmod=0755 entrypoint.sh /usr/local/bin/gateway-entrypoint
# Runs as an unprivileged user (compose `user:`); Caddy only needs writable scratch dirs.
ENV XDG_DATA_HOME=/tmp/caddy XDG_CONFIG_HOME=/tmp/caddy
ENTRYPOINT ["/usr/local/bin/gateway-entrypoint"]
