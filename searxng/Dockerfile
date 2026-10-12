ARG SEARXNG_VERSION
FROM docker.io/searxng/searxng:${SEARXNG_VERSION}
# COPY only (no RUN), so arm64 images build on an amd64 host without emulation.
COPY --chmod=0644 settings.yml /usr/local/searxng/searxng-lan-settings.yml
COPY --chmod=0755 entrypoint.sh /usr/local/bin/searxng-lan-entrypoint
ENTRYPOINT ["/usr/local/bin/searxng-lan-entrypoint"]
