import Foundation

@testable import Amanuensis

/// 一時ディレクトリに `body` を本文とする実行できる `speech` を作る。
func fakeSpeech(_ body: String) throws -> (executable: URL, directory: URL) {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "FakeSpeech-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let executable = directory.appending(path: "speech")
  try Data("#!/bin/sh\n\(body)\n".utf8).write(to: executable)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o755], ofItemAtPath: executable.path)
  return (executable, directory)
}

/// 偽の `speech` を `runtime/speech` に置いた `SpeechInstallation`。偽の speech は引数を `runtime/args` に書く。
func fakeInstallation(_ body: String) throws -> SpeechInstallation {
  let (executable, directory) = try fakeSpeech(
    #"printf '%s\n' "$@" > "$(dirname "$0")/args""# + "\n" + body)
  let installation = SpeechInstallation(directory: directory)
  try FileManager.default.createDirectory(
    at: installation.runtimeDirectory, withIntermediateDirectories: true)
  try FileManager.default.moveItem(at: executable, to: installation.executable)
  return installation
}
