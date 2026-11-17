#!/bin/sh
# whisper.cpp の whisper-cli を固定したコミットから静的にビルドし、.build/whisper-cpp に置く。
set -eu
cd "$(dirname "$0")/.."

# 版を上げるときは VERSION と COMMIT を更新する
VERSION=1.9.5
COMMIT=d1be6fde11ac6e0407606b4e42fe72d34add8037
# shortcut: 版の追跡は手作業, whisper.cpp の脆弱性の告知か不具合の報告があれば上げる

out=.build/whisper-cpp
sum=$(shasum -a 256 < scripts/build-whisper.sh)
stamp="$COMMIT ${sum%% *}"
if [ "$(cat "$out/STAMP" 2>/dev/null)" = "$stamp" ] && [ -x "$out/whisper-cli" ]; then
  echo "build-whisper.sh: version=$VERSION commit=$COMMIT はビルド済み"
  exit 0
fi

fail() {
  printf 'build-whisper.sh: %s\n' "$1" >&2
  exit 1
}

echo "build-whisper.sh: version=$VERSION commit=$COMMIT をビルドする"
tmp=$(mktemp -d)
mkdir -p .build
stage=$(mktemp -d "$out.tmp.XXXXXX")
trap 'rm -rf "$tmp" "$stage"' EXIT
src=$tmp/whisper.cpp
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "v$VERSION" \
  https://github.com/ggml-org/whisper.cpp.git "$src" ||
  fail "v$VERSION を取得できない"
# タグは注釈付きなので、タグのオブジェクトでなくタグが指すコミットを比べる。
actual=$(git -C "$src" rev-parse HEAD)
[ "$actual" = "$COMMIT" ] ||
  fail "タグ v$VERSION のコミット $actual が固定した $COMMIT と違う"

# GGML_NATIVE=OFF: M2 で native にすると i8mm(MATMUL_INT8)を使い、M1 で動かない。
# GGML_OPENMP=OFF: 既定の ON は OpenMP が見つかる環境でシステムの外の libomp にリンクする。
cmake -S "$src" -B "$tmp/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_NATIVE=OFF \
  -DGGML_OPENMP=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_BLAS=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 ||
  fail "cmake の構成に失敗した"
cmake --build "$tmp/build" --target whisper-cli -j "$(sysctl -n hw.ncpu)" ||
  fail "whisper-cli のビルドに失敗した"
built=$tmp/build/bin/whisper-cli
[ -x "$built" ] || fail "ビルドした whisper-cli が $built に無い"

cp "$built" "$stage/whisper-cli"
cp "$src/LICENSE" "$stage/LICENSE"
echo "$stamp" > "$stage/STAMP"
rm -rf "$out"
mv "$stage" "$out"
echo "build-whisper.sh: $out/whisper-cli を作った"
