import Foundation
import Testing

@testable import Amanuensis

/// 専用の UserDefaults の suite。`remove()` で消す。
private struct Sandbox {
  let suiteName = "MicrophoneTests-\(UUID().uuidString)"
  var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

  func setting() -> MicrophoneSetting { MicrophoneSetting(defaults: defaults) }

  func remove() { UserDefaults().removePersistentDomain(forName: suiteName) }
}

private let builtIn = AudioDevice(id: 10, uid: "builtin", name: "MacBook Pro のマイク", hasInput: true)
private let speaker = AudioDevice(
  id: 11, uid: "speaker", name: "MacBook Pro のスピーカー", hasInput: false)
private let jump = AudioDevice(
  id: 12, uid: "jump-uid", name: "Jump Desktop Microphone", hasInput: true)
private let ownAggregate = AudioDevice(
  id: 13, uid: "io.github.mosidas.amanuensis.aggregate.\(UUID().uuidString)", name: "amanuensis",
  hasInput: true)

@Test func inputDevicesExcludeOutputOnly() {
  let inputs = inputDevices(from: [builtIn, speaker, jump, ownAggregate])
  #expect(inputs.map(\.uid) == ["builtin", "jump-uid"], "出力専用と録音中の集約デバイスを除く")
}

@Test func microphoneChoiceIsReadBackByAnotherInstance() {
  let sandbox = Sandbox()
  defer { sandbox.remove() }
  let chosen = MicrophoneChoice.device(uid: "jump-uid", name: "Jump Desktop Microphone")
  sandbox.setting().setChoice(chosen)
  #expect(sandbox.setting().choice == chosen, "別のインスタンスでも選んだマイクを読み戻す")

  sandbox.setting().setChoice(.systemDefault)
  #expect(sandbox.defaults.object(forKey: "microphone") == nil, "システムの既定ではキーを消す")
  #expect(sandbox.setting().choice == .systemDefault)
}

@Test func unsetMicrophoneIsSystemDefault() {
  let sandbox = Sandbox()
  defer { sandbox.remove() }
  #expect(sandbox.setting().choice == .systemDefault)
}

/// `defaults write` で壊された値。どれもシステムの既定に戻る。
private func brokenValue(_ name: String) -> Any {
  switch name {
  case "string": "x"
  case "number": 1
  case "empty-uid": ["uid": "", "name": "A"]
  case "name-only": ["name": "A"]
  default: ["uid": 1, "name": "A"] as [String: Any]
  }
}

@Test(arguments: ["string", "number", "empty-uid", "name-only", "number-uid"])
func brokenMicrophoneValueFallsBackToSystemDefault(name: String) {
  let sandbox = Sandbox()
  defer { sandbox.remove() }
  sandbox.defaults.set(brokenValue(name), forKey: "microphone")
  #expect(sandbox.setting().choice == .systemDefault, "\(name)")
}

@Test func missingSelectedMicrophoneIsRefused() throws {
  #expect(throws: StartFailure.selectedMicrophoneMissing(name: "Jump Desktop Microphone")) {
    try selectedMicrophone(uid: "jump-uid", name: "Jump Desktop Microphone", in: [builtIn])
  }
  #expect(
    try selectedMicrophone(uid: "jump-uid", name: "Jump Desktop Microphone", in: [builtIn, jump])
      == 12, "一覧にある UID ならそのデバイスを使う")
}
