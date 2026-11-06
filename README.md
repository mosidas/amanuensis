# amanuensis

Web 会議を検知して録音し、録音の後に日本語の文字起こしをする macOS のメニューバーのアプリ。

- 会議の検知と自動の録音
- 録音の後の日本語の文字起こし
- 話者のラベル付け(設定の「話者を分ける」)
- 録音の一覧(メニューの「録音の一覧…」)

## 動作環境

- macOS 15 以上(Apple Silicon)

## インストール

### Releases から

1. [Releases](https://github.com/mosidas/amanuensis/releases) から `Amanuensis-<バージョン>.zip` をダウンロードして展開する。
2. `Amanuensis.app` を `/Applications` へ移す。
3. 配布物はアドホック署名だけで公証していないため、初回の起動は Gatekeeper に止められる。ターミナルで `xattr -dr com.apple.quarantine /Applications/Amanuensis.app` を実行し、隔離属性を外す。
4. `Amanuensis.app` を開く。Dock には出ず、メニューバーにアイコンが出る。

### ソースからビルドする

1. Swift 6.0 以上を含む Xcode か Command Line Tools をインストールする。
2. `scripts/bundle.sh` を実行する。`dist/Amanuensis.app` ができる。
3. `Amanuensis.app` を `/Applications` へコピーして開く。

## 使い方

1. メニューバーのアイコンのメニューから「設定…」を選択する。
2. 「音声認識」の「ダウンロード」を押す。amanuensis は音声認識のランタイム・音声認識のモデル・話者分離のモデルをまとめて取得する。取得するファイルと容量は [ライセンス](#ライセンス) の表に示す。
3. マイク・システムオーディオ録音・書類フォルダー・通知の許可を求められたら許可する。録音と会議の検知にはマイクとシステムオーディオ録音の許可が必要になる。後からシステム設定 > プライバシーとセキュリティ > 画面収録とシステムオーディオ録音 > システムオーディオ録音のみで許可したときは amanuensis を開き直す。
4. 会議アプリがマイクを使い始めると録音が始まる。対象は Zoom・Microsoft Teams・Google Chrome(Google Meet)・Slack(ハドル)である。メニューの「録音を開始」で手動でも始められる。
5. 会議が終わってマイクが使われなくなると録音が止まる。続けて文字起こしが始まる。「録音を開始」で始めた録音はメニューの「停止」で止める。

配布物はアドホック署名だけなので、アプリを更新した後は権限を許可し直すことがある。

amanuensis は録音を `~/Documents/amanuensis/<yyyy-MM-dd_HHmmss>/recording.caf` に保存する。文字起こしは同じフォルダーの `transcript.md` に書き出す。保存先は設定の「変更…」で変えられる。音声の形式は CAF(LPCM 16 bit・48 kHz・2 チャンネル)である。左のチャンネルにマイク、右のチャンネルにシステム音声を録る。

会議の検知では対象のアプリのプロセスがマイク入力を使っているかを見る。ウィンドウのタイトル・URL・会議名は読まない。Google Chrome では Meet 以外のサイトでマイクを使っても録音が始まる。不要な録音はメニューの「破棄…」で消す。

## 開発

ビルドは [ソースからビルドする](#ソースからビルドする) の手順で行う。テストは次のコマンドで実行する。

```sh
scripts/test.sh
```

## ライセンス

amanuensis のライセンスは [MIT License](LICENSE) である。アプリが取得するファイルの取得元・容量・ライセンスは次のとおりである。

| ファイル | 取得元 | 容量 | ライセンス |
| :-- | :-- | :-- | :-- |
| speech.cpp v0.10.1 のランタイム(macOS arm64 Metal) | [nyosegawa/speech.cpp](https://github.com/nyosegawa/speech.cpp) | 6.1 MB(展開後 21 MB) | MIT |
| Haas-ja-v1.0(Third Intelligence)の GGUF 変換(Q8_0) | [sakasegawa/Haas-ja-v1.0-GGUF](https://huggingface.co/sakasegawa/Haas-ja-v1.0-GGUF)。元のモデルは [third-intelligence/Haas-ja-v1.0](https://huggingface.co/third-intelligence/Haas-ja-v1.0) | 656 MB | Apache 2.0 |
| Nemotron-3-Diarization(NVIDIA)の GGUF 変換(Q8_0) | [sakasegawa/Nemotron-3-Diarization-GGUF](https://huggingface.co/sakasegawa/Nemotron-3-Diarization-GGUF)。元のモデルは [nvidia/Nemotron-3-Diarization](https://huggingface.co/nvidia/Nemotron-3-Diarization) | 106 MB | OpenMDW 1.1 |
