#!/bin/bash
# Generate labeled test clips (channel label + running timecode) for the WIDS
# video player. Each is 720x480 (CRT native) with a visible clock so the
# resume-where-you-left-off behaviour is provable on screen and via mpv IPC.
set -e
DIR=/var/lib/wids/videos
FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
install -d -m 755 "$DIR"

gen() {  # $1=channel  $2=bgcolor
  local ch=$1 color=$2
  ffmpeg -y -loglevel error -f lavfi -i "color=c=${color}:s=720x480:d=60" \
    -vf "drawtext=fontfile=${FONT}:text='CH ${ch}':fontsize=96:fontcolor=white:x=(w-text_w)/2:y=80,drawtext=fontfile=${FONT}:text='%{pts\:hms}':fontsize=72:fontcolor=yellow:x=(w-text_w)/2:y=280" \
    -r 15 -pix_fmt yuv420p "${DIR}/${ch}.mp4"
  echo "  made ${ch}.mp4 ($(du -h "${DIR}/${ch}.mp4" | cut -f1))"
}

gen 1 navy
gen 6 darkgreen
gen 11 maroon

ffmpeg -y -loglevel error -f lavfi -i "color=c=black:s=720x480:d=30" \
  -vf "drawtext=fontfile=${FONT}:text='SCANNING':fontsize=72:fontcolor=gray:x=(w-text_w)/2:y=(h-text_h)/2" \
  -r 15 -pix_fmt yuv420p "${DIR}/idle.mp4"
echo "  made idle.mp4"
ls -la "$DIR"
