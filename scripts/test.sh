#!/bin/sh
set -eu
# ponytail: Xcode 入り(CI の macos-latest など)は素の swift test で足りる。CLT のパスを混ぜると Xcode 側の swift-testing と衝突しうるため、CLT だけの環境(Platforms が無い)に限って付ける。
if [ -d "$(xcode-select -p)/Platforms" ]; then
  exec swift test "$@"
fi
D=/Library/Developer/CommandLineTools/Library/Developer
exec swift test \
  -Xswiftc -F -Xswiftc "$D/Frameworks" \
  -Xlinker -rpath -Xlinker "$D/Frameworks" \
  -Xlinker -rpath -Xlinker "$D/usr/lib" "$@"
