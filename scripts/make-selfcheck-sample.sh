#!/bin/sh
# 動作確認用の同梱音声 Resources/SelfCheck/sample.wav を、原稿 sample.txt から macOS の合成音声(say、Kyoko)で生成する。
# 誰の声でもない音声を使い、個人情報をリポジトリと配布物に含めない。原稿を変えたら本スクリプトで作り直す。
set -eu
cd "$(dirname "$0")/.."
dir=Resources/SelfCheck
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
say -v Kyoko -r 150 -f "$dir/sample.txt" -o "$tmp/sample.aiff"
afconvert -f WAVE -d LEI16@16000 -c 1 "$tmp/sample.aiff" "$dir/sample.wav"
afinfo "$dir/sample.wav" | grep -E "data format|duration"
