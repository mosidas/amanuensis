import Foundation

/// 一時ディレクトリに `body` を本文とする実行できる `speech` を作る。
func fakeSpeech(_ body: String) throws -> (executable: URL, directory: URL) {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "SelfCheck-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let executable = directory.appending(path: "speech")
  try Data("#!/bin/sh\n\(body)\n".utf8).write(to: executable)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o755], ofItemAtPath: executable.path)
  return (executable, directory)
}
