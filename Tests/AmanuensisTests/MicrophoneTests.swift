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
private let brokenValues: [(String, any Sendable)] = [
  ("string", "x"),
  ("number", 1),
  ("empty-uid", ["uid": "", "name": "A"]),
  ("name-only", ["name": "A"]),
  ("number-uid", ["uid": 1, "name": "A"] as [String: any Sendable]),
]

@Test(arguments: brokenValues)
func brokenMicrophoneValueFallsBackToSystemDefault(name: String, value: any Sendable) {
  let sandbox = Sandbox()
  defer { sandbox.remove() }
  sandbox.defaults.set(value, forKey: "microphone")
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

/// 偽の Core Audio の一覧。通知の偽物と組で使う。
@MainActor private final class DeviceBox {
  var devices: [AudioDevice] = []
  var notify: (@MainActor @Sendable () -> Void)?

  func list() -> MicrophoneList {
    MicrophoneList(read: { self.devices }, subscribe: { self.notify = $0 })
  }
}

@Test @MainActor func listFollowsDeviceListNotifications() throws {
  let box = DeviceBox()
  box.devices = [builtIn, speaker]
  let list = box.list()
  #expect(list.devices.map(\.uid) == ["builtin"], "開いた時点の入力デバイスだけを出す")
  let notify = try #require(box.notify, "一覧の変更を購読する")

  box.devices = [builtIn, speaker, jump]
  notify()
  #expect(list.devices.map(\.uid) == ["builtin", "jump-uid"], "接続したデバイスが増える")

  box.devices = [builtIn, speaker]
  notify()
  #expect(list.devices.map(\.uid) == ["builtin"], "切断したデバイスが消える")
}

@Test func savedChoiceIsSelectedInMenu() {
  let sandbox = Sandbox()
  defer { sandbox.remove() }
  sandbox.setting().setChoice(.device(uid: "jump-uid", name: "Jump Desktop Microphone"))
  let rows = MicrophoneMenu.rows(for: sandbox.setting().choice, devices: [builtIn, jump])
  #expect(
    rows.map(\.label) == ["システムの既定", "Jump Desktop Microphone", "MacBook Pro のマイク"],
    "システムの既定、次に名前の順")
  #expect(rows.filter { $0.choice.uid == "jump-uid" }.count == 1, "保存したマイクの行がちょうど 1 つ")
  #expect(rows.first?.choice == .systemDefault)
}

@Test func missingSavedChoiceKeepsRow() {
  let rows = MicrophoneMenu.rows(
    for: .device(uid: "jump-uid", name: "Jump Desktop Microphone"), devices: [builtIn])
  #expect(
    rows.map(\.label) == [
      "システムの既定", "MacBook Pro のマイク", "Jump Desktop Microphone(接続されていません)",
    ])
  #expect(rows.last?.choice == .device(uid: "jump-uid", name: "Jump Desktop Microphone"))
}
