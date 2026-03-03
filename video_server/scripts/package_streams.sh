#!/usr/bin/env bash
set -euo pipefail

INPUT_FILE="${INPUT_FILE:-/data/input/source.mp4}"
HLS_NAME="${HLS_NAME:-stream}"
DASH_NAME="${DASH_NAME:-stream}"
SEGMENT_SECONDS="${SEGMENT_SECONDS:-4}"

HLS_DIR="/var/www/media/hls"
DASH_DIR="/var/www/media/dash"
mkdir -p "$HLS_DIR" "$DASH_DIR"

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "Input file not found at $INPUT_FILE, generating synthetic sample."
  INPUT_FILE="/tmp/sample.mp4"
  ffmpeg -y \
    -f lavfi -i "testsrc=size=1280x720:rate=30" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000" \
    -t 180 \
    -c:v libx264 -pix_fmt yuv420p -preset veryfast \
    -c:a aac -b:a 128k \
    "$INPUT_FILE"
fi

rm -rf "$HLS_DIR"/* "$DASH_DIR"/*

HAS_AUDIO="false"
if ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "$INPUT_FILE" | grep -q "audio"; then
  HAS_AUDIO="true"
fi

echo "Packaging HLS ABR ladder (2160p/1080p/720p/480p) from $INPUT_FILE"

if [[ "$HAS_AUDIO" == "true" ]]; then
  ffmpeg -y -i "$INPUT_FILE" \
    -filter_complex "[0:v]split=4[v0][v1][v2][v3];[v0]scale=w=3840:h=2160:force_original_aspect_ratio=decrease,pad=3840:2160:(ow-iw)/2:(oh-ih)/2,format=yuv420p[v2160];[v1]scale=w=1920:h=1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,format=yuv420p[v1080];[v2]scale=w=1280:h=720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,format=yuv420p[v720];[v3]scale=w=854:h=480:force_original_aspect_ratio=decrease,pad=854:480:(ow-iw)/2:(oh-ih)/2,format=yuv420p[v480]" \
    -map "[v2160]" -map a:0 \
    -map "[v1080]" -map a:0 \
    -map "[v720]" -map a:0 \
    -map "[v480]" -map a:0 \
    -c:v libx264 -preset veryfast -profile:v main \
    -g 48 -keyint_min 48 -sc_threshold 0 \
    -b:v:0 16000k -maxrate:v:0 20000k -bufsize:v:0 32000k \
    -b:v:1 6000k -maxrate:v:1 7500k -bufsize:v:1 12000k \
    -b:v:2 3000k -maxrate:v:2 3750k -bufsize:v:2 6000k \
    -b:v:3 1500k -maxrate:v:3 1875k -bufsize:v:3 3000k \
    -c:a aac -ar 48000 \
    -b:a:0 192k -b:a:1 128k -b:a:2 128k -b:a:3 96k \
    -f hls \
    -hls_time "$SEGMENT_SECONDS" \
    -hls_playlist_type vod \
    -hls_flags independent_segments \
    -hls_segment_type fmp4 \
    -master_pl_name "${HLS_NAME}.m3u8" \
    -var_stream_map "v:0,a:0,name:2160p v:1,a:1,name:1080p v:2,a:2,name:720p v:3,a:3,name:480p" \
    -hls_segment_filename "$HLS_DIR/v%v/${HLS_NAME}_%03d.m4s" \
    "$HLS_DIR/v%v/${HLS_NAME}.m3u8"
else
  ffmpeg -y -i "$INPUT_FILE" \
    -filter_complex "[0:v]split=4[v0][v1][v2][v3];[v0]scale=w=3840:h=2160:force_original_aspect_ratio=decrease,pad=3840:2160:(ow-iw)/2:(oh-ih)/2,format=yuv420p[v2160];[v1]scale=w=1920:h=1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,format=yuv420p[v1080];[v2]scale=w=1280:h=720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,format=yuv420p[v720];[v3]scale=w=854:h=480:force_original_aspect_ratio=decrease,pad=854:480:(ow-iw)/2:(oh-ih)/2,format=yuv420p[v480]" \
    -map "[v2160]" \
    -map "[v1080]" \
    -map "[v720]" \
    -map "[v480]" \
    -c:v libx264 -preset veryfast -profile:v main \
    -g 48 -keyint_min 48 -sc_threshold 0 \
    -b:v:0 16000k -maxrate:v:0 20000k -bufsize:v:0 32000k \
    -b:v:1 6000k -maxrate:v:1 7500k -bufsize:v:1 12000k \
    -b:v:2 3000k -maxrate:v:2 3750k -bufsize:v:2 6000k \
    -b:v:3 1500k -maxrate:v:3 1875k -bufsize:v:3 3000k \
    -f hls \
    -hls_time "$SEGMENT_SECONDS" \
    -hls_playlist_type vod \
    -hls_flags independent_segments \
    -hls_segment_type fmp4 \
    -master_pl_name "${HLS_NAME}.m3u8" \
    -var_stream_map "v:0,name:2160p v:1,name:1080p v:2,name:720p v:3,name:480p" \
    -hls_segment_filename "$HLS_DIR/v%v/${HLS_NAME}_%03d.m4s" \
    "$HLS_DIR/v%v/${HLS_NAME}.m3u8"
fi

echo "Packaging DASH from $INPUT_FILE"
ffmpeg -y -i "$INPUT_FILE" \
  -map 0:v:0 -map 0:a:0? \
  -c:v libx264 -preset veryfast -profile:v main -level 4.0 \
  -c:a aac -b:a 128k \
  -g 48 -keyint_min 48 -sc_threshold 0 \
  -seg_duration "$SEGMENT_SECONDS" \
  -use_template 1 -use_timeline 1 \
  -f dash \
  "$DASH_DIR/${DASH_NAME}.mpd"

echo "Packaging complete."
echo "HLS:  /media/hls/${HLS_NAME}.m3u8"
echo "DASH: /media/dash/${DASH_NAME}.mpd"
