FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY nginx.conf /etc/nginx/nginx.conf
COPY scripts/package_streams.sh /usr/local/bin/package_streams.sh
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY player.html /var/www/html/player.html

RUN chmod +x /usr/local/bin/package_streams.sh /usr/local/bin/docker-entrypoint.sh \
    && mkdir -p /var/www/media/hls /var/www/media/dash /data/input

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
