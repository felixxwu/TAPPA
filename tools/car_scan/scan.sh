#!/bin/bash
# Turns a walk-around video of a car into a low-poly textured game body: frames → mask → Apple Object Capture → align → process → preview.
# Usage: [PAINT=<paint.mp4>] tools/car_scan/scan.sh <video.mp4> <workDir> <length_m> [process.py options...]
# With PAINT, <video.mp4> is the car in a patterned wrap (it gives the shape) and PAINT the same car in its real paint,
# filmed in the same spot (its frames give the colour).
# Each stage is skipped when its output already exists, so delete body/ (or model.usdz) to redo just that part.
# Env: FPS (frames sampled per second, default 9), FLIP=1 (car came out backwards), DETAIL (Object Capture level, default full).
set -euo pipefail
[ $# -ge 3 ] || { sed -n 2,5p "$0"; exit 1; }
VIDEO=$1; WORK=$2; LENGTH=$3; shift 3
HERE=$(cd "$(dirname "$0")" && pwd)
BLENDER=${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}
BLENDER_PY=$(ls "$(dirname "$BLENDER")"/../Resources/*/python/bin/python3.* | head -1)   # has numpy
mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd)

[ -x "$WORK/capture" ] || swiftc -O "$HERE/capture.swift" -o "$WORK/capture"
[ -x "$WORK/mask" ] || swiftc -O "$HERE/mask.swift" -o "$WORK/mask"

if [ ! -d "$WORK/frames" ]; then
  mkdir -p "$WORK/frames.tmp"
  ffmpeg -v error -i "$VIDEO" -vf "fps=${FPS:-9}" -q:v 1 "$WORK/frames.tmp/f_%04d.jpg"
  mv "$WORK/frames.tmp" "$WORK/frames"
fi
echo "frames: $(ls "$WORK/frames" | wc -l)"

if [ ! -d "$WORK/masks" ]; then
  "$WORK/mask" "$WORK/frames" "$WORK/masks.tmp" && mv "$WORK/masks.tmp" "$WORK/masks"
fi

if [ ! -f "$WORK/model.usdz" ]; then
  # Unmasked on purpose: the garage is what pins the cameras down (blacked-out frames let a symmetric car get rebuilt twice).
  # Object Capture wants frames in camera order; mixing several videos needs UNORDERED=1.
  "$WORK/capture" "$WORK/frames" "$WORK/model.usdz" "${DETAIL:-full}" | tee "$WORK/capture.log" | grep -v -e progress -e skipped || true
  [ -f "$WORK/model.usdz" ] || { echo "Object Capture failed, see $WORK/capture.log"; exit 1; }
  echo "skipped frames: $(grep -c skipped "$WORK/capture.log" || true)"
fi

"$BLENDER" -b --python "$HERE/align.py" -- "$WORK/model.usdz" "$WORK/car_aligned.blend" "$LENGTH" --masks "$WORK/masks" ${FLIP:+--flip} 2>&1 | grep -E 'CROPPED|ALIGNED|Error|Traceback' -A3

mkdir -p "$WORK/body"
PAINT_ARGS=()
if [ -n "${PAINT:-}" ]; then
  if [ ! -d "$WORK/paint_frames" ]; then
    mkdir -p "$WORK/paint_frames.tmp"
    ffmpeg -v error -i "$PAINT" -vf "fps=${PAINT_FPS:-3}" -q:v 1 "$WORK/paint_frames.tmp/f_%04d.jpg"
    mv "$WORK/paint_frames.tmp" "$WORK/paint_frames"
  fi
  if [ ! -f "$WORK/joint.usdz.poses.json" ]; then
    # One camera-finding run over both videos, unmasked: the shared garage ties the paint frames to the shape frames.
    rm -rf "$WORK/joint"; mkdir "$WORK/joint"
    i=0; for f in "$WORK"/frames/*.jpg; do [ $((i % 3)) = 0 ] && ln -s "$f" "$WORK/joint/w_$(basename "$f")"; i=$((i + 1)); done
    for f in "$WORK"/paint_frames/*.jpg; do ln -s "$f" "$WORK/joint/p_$(basename "$f")"; done
    UNORDERED=1 "$WORK/capture" "$WORK/joint" "$WORK/joint.usdz" poses | grep -v -e progress -e skipped || true
  fi
  "$BLENDER_PY" "$HERE/register.py" "$WORK/model.usdz.poses.json" "$WORK/joint.usdz.poses.json" "$WORK/paint.poses.json"
  PAINT_ARGS=(--paint-poses "$WORK/paint.poses.json" --paint-frames "$WORK/paint_frames")
fi

"$BLENDER" -b "$WORK/car_aligned.blend" --python "$HERE/process.py" -- "$WORK/body" ${PAINT_ARGS[@]+"${PAINT_ARGS[@]}"} "$@" 2>&1 | grep -E 'WHEELS|SHELL|PAINT|FILLED|PLATE|LOW|DONE|Error|Traceback|usage' -A3

"$BLENDER" -b --python "$HERE/preview.py" -- "$WORK/body/car_body.glb" "$WORK/preview" >/dev/null 2>&1
ffmpeg -v error -y -i "$WORK/preview_0.png" -i "$WORK/preview_1.png" -i "$WORK/preview_2.png" -i "$WORK/preview_3.png" \
  -filter_complex "[0][1][2][3]xstack=inputs=4:layout=0_0|w0_0|0_h0|w0_h0" "$WORK/preview.png"
echo "preview: $WORK/preview.png  (side view: $WORK/preview_2.png)"
