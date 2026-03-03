FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx ffmpeg ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY nginx.conf /etc/nginx/nginx.conf
COPY scripts/package_streams.sh /usr/local/bin/package_streams.sh
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY player.html /var/www/html/player.html

RUN chmod +x /usr/local/bin/package_streams.sh /usr/local/bin/docker-entrypoint.sh \
    && mkdir -p /var/www/media/hls /var/www/media/dash /data/input /var/www/html/vendor \
    && curl -fsSL https://cdn.jsdelivr.net/npm/hls.js@1.5.17/dist/hls.min.js -o /var/www/html/vendor/hls.min.js \
    && curl -fsSL https://cdn.dashjs.org/v4.7.4/dash.all.min.js -o /var/www/html/vendor/dash.all.min.js

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
