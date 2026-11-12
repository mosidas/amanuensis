import AVFoundation
import Testing
import os

@testable import Amanuensis

private let desk = AudioDevice(id: 21, uid: "desk-uid", name: "Desk Microphone", hasInput: true)
private let headset = AudioDevice(id: 22, uid: "headset-uid", name: "Headset", hasInput: true)
private let usb = AudioDevice(id: 23, uid: "usb-uid", name: "USB Microphone", hasInput: true)

/// 開いた・閉じたマイクを呼ばれた順に記録する Core Audio の代わり。
/// 既定の入力は `defaults` を読むたびに 1 つずつ返し、使い切ったら最後の値を返し続ける。
private final class FakeMicrophones: Sendable {
  enum Event: Equatable {
    case open(AudioObjectID)
    case close(AudioObjectID)
  }

  private struct State {
    var defaults: [AudioDevice?]
    var events: [Event] = []
    var onLost: [AudioObjectID: @Sendable () -> Void] = [:]
  }

  private let state: OSAllocatedUnfairLock<State>
  private let failing: Set<AudioObjectID>

  init(defaults: [AudioDevice?], failing: Set<AudioObjectID> = []) {
    state = OSAllocatedUnfairLock(initialState: State(defaults: defaults))
    self.failing = failing
  }

  var events: [Event] { state.withLock { $0.events } }

  func follower() -> DefaultInputFollower {
    DefaultInputFollower(open: open, defaultInput: defaultInput)
  }

  /// `device` を開いたときに渡された喪失の通知を送る。
  func lose(_ device: AudioDevice) {
    state.withLock { $0.onLost[device.id] }?()
  }

  private func defaultInput() -> AudioDevice? {
    state.withLock { state in
      state.defaults.count > 1 ? state.defaults.removeFirst() : state.defaults.first ?? nil
    }
  }

  private func open(_ device: AudioDevice, onLost: @escaping @Sendable () -> Void)
    throws(StartFailure) -> OpenedMicrophone
  {
    state.withLock { $0.events.append(.open(device.id)) }
    if failing.contains(device.id) {
      throw .failed(step: "start_device", type: "-50")
    }
    state.withLock { $0.onLost[device.id] = onLost }
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    return OpenedMicrophone(format: format) { [self] in
      state.withLock { $0.events.append(.close(device.id)) }
    }
  }
}

@Test func followsDefaultInputChange() throws {
  let microphones = FakeMicrophones(defaults: [desk, headset])
  let follower = microphones.follower()

  let started = try follower.start()
  follower.follow()
  follower.stop()

  #expect(started.device == desk, "開始時は既定の入力を読む")
  #expect(
    microphones.events == [.open(desk.id), .open(headset.id), .close(desk.id), .close(headset.id)],
    "新しい既定を開いてから前のマイクを閉じ、停止で今のマイクを閉じる")
}

@Test func lostDeviceIsReplacedByNewDefault() throws {
  let microphones = FakeMicrophones(defaults: [desk, headset])
  let follower = microphones.follower()

  _ = try follower.start()
  microphones.lose(desk)
  follower.stop()

  #expect(
    microphones.events == [.open(desk.id), .open(headset.id), .close(desk.id), .close(headset.id)],
    "読んでいたマイクを失ったら今の既定へ替える")
}

@Test func failedSwitchKeepsCurrentDevice() throws {
  let microphones = FakeMicrophones(defaults: [desk, headset, desk], failing: [headset.id])
  let follower = microphones.follower()

  _ = try follower.start()
  follower.follow()
  follower.follow()
  follower.stop()

  #expect(
    microphones.events == [.open(desk.id), .open(headset.id), .close(desk.id)],
    "開けなかったときは前のマイクを停止まで読み続け、既定が戻っても開き直さない")
}

@Test func noDefaultInputReleasesDeviceAndResumesLater() throws {
  let microphones = FakeMicrophones(defaults: [desk, nil, usb])
  let follower = microphones.follower()

  _ = try follower.start()
  follower.follow()
  follower.follow()
  follower.stop()

  #expect(
    microphones.events == [.open(desk.id), .close(desk.id), .open(usb.id), .close(usb.id)],
    "既定が無くなったら閉じ、現れたら開く")
}

@Test func unchangedDefaultAndFollowAfterStopDoNothing() throws {
  let microphones = FakeMicrophones(defaults: [desk, desk, headset])
  let follower = microphones.follower()

  _ = try follower.start()
  follower.follow()
  follower.stop()
  follower.follow()
  microphones.lose(desk)
  follower.stop()

  #expect(
    microphones.events == [.open(desk.id), .close(desk.id)],
    "同じ既定の再通知では開き直さず、停止の後の通知では何もしない")
}

@Test func startWithoutDefaultInputThrows() {
  let microphones = FakeMicrophones(defaults: [nil])
  let follower = microphones.follower()

  #expect(throws: StartFailure.noInputDevice) { try follower.start() }
  #expect(microphones.events.isEmpty)
}

@Test func followBeforeStartLeavesNoMicrophoneOpenAfterStop() throws {
  let microphones = FakeMicrophones(defaults: [desk, headset])
  let follower = microphones.follower()

  follower.follow()
  let started = try follower.start()
  follower.stop()

  #expect(started.device == headset, "開始時は既定の入力を読む")
  #expect(
    microphones.events == [.open(desk.id), .open(headset.id), .close(desk.id), .close(headset.id)],
    "開始より先に届いた照合が開いたマイクも、開始で閉じる")
}

@Test func failedStartAfterFollowStillClosesOnStop() {
  let microphones = FakeMicrophones(defaults: [desk, headset], failing: [headset.id])
  let follower = microphones.follower()

  follower.follow()
  #expect(throws: StartFailure.failed(step: "start_device", type: "-50")) {
    try follower.start()
  }
  follower.stop()

  #expect(
    microphones.events == [.open(desk.id), .open(headset.id), .close(desk.id)],
    "開始に失敗しても、先に届いた照合が開いたマイクは停止で閉じる")
}

@Test func startAfterStopThrowsWithoutOpening() {
  let microphones = FakeMicrophones(defaults: [desk])
  let follower = microphones.follower()

  follower.stop()
  #expect(throws: StartFailure.failed(step: "find_microphone", type: "stopped")) {
    try follower.start()
  }

  #expect(microphones.events.isEmpty, "停止の後の開始ではマイクを開かない")
}
