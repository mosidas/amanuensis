import Foundation

/// 取得するファイルの取得先と、照合に使う大きさと sha256。
struct RemoteFile: Sendable {
  let url: URL
  let byteCount: Int64
  let sha256: String
  let fileName: String
}

extension RemoteFile {
  /// speech.cpp v0.10.1 の macOS arm64 Metal 版。
  /// sha256 はリリースに添付の SHA256SUMS の `speech-0.10.1-macos-arm64-metal.zip` の行。
  static let speechRuntime = RemoteFile(
    url: URL(
      string:
        "https://github.com/nyosegawa/speech.cpp/releases/download/v0.10.1/speech-0.10.1-macos-arm64-metal.zip"
    )!,
    byteCount: 6_087_757,
    sha256: "ff24f6f58c9d2dedb01caa88ba043ae845c76eff228e4cbfae5de749174404c1",
    fileName: "speech-0.10.1-macos-arm64-metal.zip")

  /// Haas-ja v1.0 の Q8_0。
  /// Hugging Face の main は書き換えられるため、URL はコミット 6b965d5 に固定する。
  /// 大きさと sha256 は、この URL に Hugging Face が返す X-Linked-Size と X-Linked-ETag(LFS の sha256)。
  static let haasModel = RemoteFile(
    url: URL(
      string:
        "https://huggingface.co/sakasegawa/Haas-ja-v1.0-GGUF/resolve/6b965d5007ba780585de51549d57a8c1c0d67c7e/Haas-616M-ja-v1.0-Q8_0.gguf"
    )!,
    byteCount: 656_381_472,
    sha256: "cd5f60b2f1c411404b83fca4a65e3ce30a26d9e951b6a346529e65f22758afeb",
    fileName: "Haas-616M-ja-v1.0-Q8_0.gguf")
}
