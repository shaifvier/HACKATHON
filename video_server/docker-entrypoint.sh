#!/usr/bin/env bash
set -euo pipefail

/usr/local/bin/package_streams.sh
exec nginx -g 'daemon off;'
