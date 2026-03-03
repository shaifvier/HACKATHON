#!/usr/bin/env bash
set -euo pipefail

REPACKAGE_ON_START="${REPACKAGE_ON_START:-false}"
HLS_MANIFEST="/var/www/media/hls/${HLS_NAME:-stream}.m3u8"
DASH_MANIFEST="/var/www/media/dash/${DASH_NAME:-stream}.mpd"

if [[ "$REPACKAGE_ON_START" == "true" ]]; then
	echo "REPACKAGE_ON_START=true, packaging streams..."
	/usr/local/bin/package_streams.sh
elif [[ -f "$HLS_MANIFEST" && -f "$DASH_MANIFEST" ]]; then
	echo "Found existing manifests, skipping packaging."
else
	echo "Stream manifests missing, packaging streams..."
	/usr/local/bin/package_streams.sh
fi

exec nginx -g 'daemon off;'
