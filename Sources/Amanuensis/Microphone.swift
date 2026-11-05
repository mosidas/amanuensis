import CoreAudio
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "io.github.mosidas.amanuensis", category: "capture")

/// Core Audio のデバイス 1 つ。`hasInput` は入力ストリームを 1 つ以上持つとき true。
struct AudioDevice: Equatable {
  let id: AudioObjectID
  let uid: String
  let name: String
  let hasInput: Bool
}

/// 録音に使うマイク。`name` は保存した時点の表示名で、デバイスが見つからないときの文言に使う。
enum MicrophoneChoice: Equatable {
  case systemDefault
  case device(uid: String, name: String)

  /// `.systemDefault` は nil。
  var uid: String? {
    if case .device(let uid, _) = self { uid } else { nil }
  }
}

/// 録音に使うマイクの選択の保存先。
struct MicrophoneSetting {
  private static let key = "microphone"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// 選択。保存値が空でない文字列の "uid" と "name" を持つ辞書でなければ(`defaults write` で壊された値を含む)システムの既定に戻る。
  var choice: MicrophoneChoice {
    guard let saved = defaults.dictionary(forKey: Self.key),
      let uid = saved["uid"] as? String, !uid.isEmpty,
      let name = saved["name"] as? String, !name.isEmpty
    else { return .systemDefault }
    return .device(uid: uid, name: name)
  }

  /// `.systemDefault` は保存値を消す。
  func setChoice(_ choice: MicrophoneChoice) {
    switch choice {
    case .systemDefault: defaults.removeObject(forKey: Self.key)
    case .device(let uid, let name): defaults.set(["uid": uid, "name": name], forKey: Self.key)
    }
  }
}

/// 録音中に自分で作る集約デバイスの UID の接頭辞。
let privateAggregateUIDPrefix = "io.github.mosidas.amanuensis.aggregate."

/// 録音に使える入力デバイス。出力専用のデバイスと自分の集約デバイスを除く。
func inputDevices(from all: [AudioDevice]) -> [AudioDevice] {
  all.filter { $0.hasInput && !$0.uid.hasPrefix(privateAggregateUIDPrefix) }
}

/// 保存した UID のデバイス。`inputs` に無ければ `.selectedMicrophoneMissing` を投げる。
func selectedMicrophone(uid: String, name: String, in inputs: [AudioDevice]) throws(StartFailure)
  -> AudioObjectID
{
  guard let device = inputs.first(where: { $0.uid == uid }) else {
    throw .selectedMicrophoneMissing(name: name)
  }
  return device.id
}

/// Core Audio のデバイスの一覧。UID を読めないデバイスは除く。一覧を読めなければログに残して空を返す。
nonisolated func readAudioDevices() -> [AudioDevice] {
  var ids: [AudioObjectID] = []
  let status = readList(
    AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, into: &ids)
  guard status == noErr else {
    logger.error(
      "microphones read failed error.type=\(status, privacy: .public) app.error.origin=system")
    return []
  }
  return ids.compactMap { id in
    var uid: Unmanaged<CFString>?
    guard read(id, kAudioDevicePropertyDeviceUID, into: &uid) == noErr,
      let uid = uid?.takeRetainedValue() as String?
    else { return nil }
    var streams: [AudioStreamID] = []
    let hasInput =
      readList(
        id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, into: &streams)
      == noErr && !streams.isEmpty
    return AudioDevice(id: id, uid: uid, name: deviceName(id) ?? uid, hasInput: hasInput)
  }
}

nonisolated func readInputDevices() -> [AudioDevice] { inputDevices(from: readAudioDevices()) }

/// 設定画面に出す入力デバイスの一覧。Core Audio の一覧の変更を購読して読み直す。
@MainActor @Observable final class MicrophoneList {
  private(set) var devices: [AudioDevice] = []
  @ObservationIgnored private let read: () -> [AudioDevice]

  /// `read` は Core Audio のデバイスの一覧を返す。`subscribe` は一覧が変わるたびに渡した処理を呼ぶ。
  init(
    read: @escaping () -> [AudioDevice],
    subscribe: (@escaping @MainActor @Sendable () -> Void) -> Void
  ) {
    self.read = read
    subscribe { [weak self] in self?.refresh() }
    refresh()
  }

  // shortcut: 一覧はメインスレッドで読む, coreaudiod の応答待ちで設定画面が固まる報告があれば listener の queue で読んでから MainActor へ渡す
  func refresh() {
    devices = inputDevices(from: read())
  }
}

/// 設定の「マイク」のポップアップの行。
enum MicrophoneMenu {
  struct Row: Equatable {
    let choice: MicrophoneChoice
    let label: String
  }

  /// システムの既定、名前の順の入力デバイス、一覧に無い保存したマイクの順。
  static func rows(for current: MicrophoneChoice, devices: [AudioDevice]) -> [Row] {
    let connected =
      devices
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      .map { Row(choice: .device(uid: $0.uid, name: $0.name), label: $0.name) }
    var rows = [Row(choice: .systemDefault, label: "システムの既定")] + connected
    if case .device(let uid, let name) = current, !devices.contains(where: { $0.uid == uid }) {
      rows.append(Row(choice: current, label: "\(name)(接続されていません)"))
    }
    return rows
  }
}

/// Core Audio のデバイスの一覧が変わるたびに、メインキューで `onChange` を呼ぶ。listener はアプリの終了まで外さない。
// listener の block を MainActor の文脈で作ると、HAL から呼ばれた時点で異常終了する(SystemAudioCapture.swift の openCapture と同じ)。
nonisolated func subscribeToDeviceListChanges(_ onChange: @escaping @MainActor @Sendable () -> Void)
{
  var address = propertyAddress(kAudioHardwarePropertyDevices)
  let status = AudioObjectAddPropertyListenerBlock(
    AudioObjectID(kAudioObjectSystemObject), &address, .main
  ) { _, _ in
    MainActor.assumeIsolated { onChange() }
  }
  if status != noErr {
    logger.error(
      "microphones subscribe failed error.type=\(status, privacy: .public) app.error.origin=system")
  }
}

@MainActor let microphones = MicrophoneList(
  read: readAudioDevices, subscribe: subscribeToDeviceListChanges)
