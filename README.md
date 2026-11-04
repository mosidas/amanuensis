# amanuensis
A macOS menu bar app that detects web meetings, records them, and transcribes Japanese speech afterwards

## 開発

### 動作確認用の同梱音声

設定画面の「動作確認」は、`Resources/SelfCheck/sample.wav` を文字起こしして原稿 `sample.txt` と比べる。音声は macOS の合成音声(`say`、Kyoko)で原稿から生成したもので、誰の声でもない。原稿を変えたら次のコマンドで作り直す。

```sh
scripts/make-selfcheck-sample.sh
```
