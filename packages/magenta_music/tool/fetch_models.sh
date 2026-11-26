#!/bin/sh
# Downloads Magenta pretrained checkpoints (Apache-2.0, Google) in the
# TensorFlow.js format used by magenta.js into ./models/<name>/.
set -e
cd "$(dirname "$0")/.."
BASE=https://storage.googleapis.com/magentadata/js/checkpoints
for m in music_rnn/drum_kit_rnn music_rnn/melody_rnn music_rnn/chord_pitches_improv \
         music_vae/drums_2bar_lokl_small music_vae/mel_2bar_small; do
  name=$(basename $m)
  dir=models/$name
  [ -f $dir/.done ] && continue
  mkdir -p $dir
  curl -fsSL -o $dir/config.json $BASE/$m/config.json
  curl -fsSL -o $dir/weights_manifest.json $BASE/$m/weights_manifest.json
  for f in $(python3 -c "import json,sys;print(' '.join(p for g in json.load(open('$dir/weights_manifest.json')) for p in g['paths']))"); do
    curl -fsSL -o $dir/$f $BASE/$m/$f
  done
  touch $dir/.done
  echo "$name ok"
done
