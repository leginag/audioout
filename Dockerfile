FROM alpine:3.22

# Everything the container needs is installed at build time; the running
# container makes no network requests at all (compose pins network_mode: none).
RUN apk add --no-cache ffmpeg

COPY watch.sh /usr/local/bin/watch.sh
RUN chmod +x /usr/local/bin/watch.sh

VOLUME /watch

HEALTHCHECK --interval=60s --timeout=10s --start-period=30s \
  CMD sh -c 'find /watch/.heartbeat -mmin -5 2>/dev/null | grep -q . || exit 1'

ENTRYPOINT ["/bin/sh", "/usr/local/bin/watch.sh"]
