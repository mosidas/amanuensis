import CoreAudio
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "io.github.mosidas.amanuensis", category: "detection")

/// Core Audio のプロセス一覧を読めなかった。
struct ObserveFailure: Error, Equatable {
  let status: OSStatus
}

/// マイクの使用をプロセスごとに読む(macOS 14.2 以上)。許可の確認は出ない。
/// 読む間に終了したプロセスは飛ばす。
func readAudioProcesses() throws(ObserveFailure) -> [AudioProcess] {
  let system = AudioObjectID(kAudioObjectSystemObject)
  var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  var size: UInt32 = 0
  var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
  guard status == noErr else { throw ObserveFailure(status: status) }
  var objects = [AudioObjectID](
    repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
  status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects)
  guard status == noErr else { throw ObserveFailure(status: status) }
  return objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap { object in
    var bundleID: Unmanaged<CFString>?
    guard readProcess(object, kAudioProcessPropertyBundleID, into: &bundleID) == noErr else {
      return nil
    }
    // Core Audio は保持した CFString を返す。
    let id = bundleID?.takeRetainedValue() as String? ?? ""
    var isRunningInput: UInt32 = 0
    guard readProcess(object, kAudioProcessPropertyIsRunningInput, into: &isRunningInput) == noErr
    else { return nil }
    return AudioProcess(bundleID: id, isRunningInput: isRunningInput != 0)
  }
}

private func readProcess<Value>(
  _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout Value
) -> OSStatus {
  var address = AudioObjectPropertyAddress(
    mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  var size = UInt32(MemoryLayout<Value>.size)
  return withUnsafeMutablePointer(to: &value) {
    AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
  }
}

/// 会議を検知したら自動で録音するか。
struct MeetingDetectionSetting {
  private static let key = "autoRecordMeetings"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// 保存値が Bool でなければ(`defaults write` で壊された値を含む)既定のオン。
  var autoRecord: Bool {
    defaults.object(forKey: Self.key) as? Bool ?? true
  }

  func setAutoRecord(_ autoRecord: Bool) {
    defaults.set(autoRecord, forKey: Self.key)
  }
}

extension RecorderState {
  var activity: RecorderActivity {
    switch self {
    case .idle: .idle
    case .starting, .finishing: .busy
    case .recording(let recording): .recording(recording.trigger)
    }
  }
}

enum MeetingText {
  static func started(_ app: MeetingApp) -> (title: String, body: String) {
    (
      "会議の録音を開始しました",
      "\(app.name) がマイクを使い始めたので、録音を開始しました。会議でなければ、メニューの「破棄…」で削除できます。"
    )
  }

  static func detected(_ app: MeetingApp) -> (title: String, body: String) {
    (
      "会議を検知しました",
      "\(app.name) がマイクを使い始めました。録音するには、メニューの「録音を開始」を選んでください。"
    )
  }
}

/// マイクの使用を観測して `MeetingDetector` に渡し、その指示で録音を始めて止め、通知を出す。
/// 録音の権限が拒否されている間は検知を止める(拒否のまま会議のたびに開始の失敗の警告を出さないため)。
@MainActor @Observable final class MeetingWatcher {
  // shortcut: 2 秒ごとの読み取り, 開始の遅延を縮める要求が出たらプロセス一覧と IsRunningInput のリスナーに変える
  private static let interval: Duration = .seconds(2)
  private let observe: @MainActor () throws(ObserveFailure) -> [AudioProcess]
  private let deniedPermissions: @MainActor () -> [Permission]
  private let recorder: Recorder
  private let setting: MeetingDetectionSetting
  private let notify: @MainActor (_ title: String, _ body: String) -> Void
  /// 検知を止めている(拒否されている)権限。空なら検知している。
  private(set) var blockedBy: [Permission] = []
  private var detector = MeetingDetector()
  private var observationFailing = false
  private var loop: Task<Void, Never>?

  init(
    observe: @escaping @MainActor () throws(ObserveFailure) -> [AudioProcess],
    deniedPermissions: @escaping @MainActor () -> [Permission],
    recorder: Recorder, setting: MeetingDetectionSetting,
    notify: @escaping @MainActor (_ title: String, _ body: String) -> Void
  ) {
    self.observe = observe
    self.deniedPermissions = deniedPermissions
    self.recorder = recorder
    self.setting = setting
    self.notify = notify
  }

  /// 観測を繰り返す。前の回が終わるまで次の回を始めない。2 回目以降の呼び出しは何もしない。
  func start() {
    guard loop == nil else { return }
    loop = Task { [weak self] in
      while let self {
        await self.tick(now: .now)
        try? await Task.sleep(for: Self.interval)
      }
    }
  }

  /// 1 回観測して判定し、指示を実行する。観測に失敗した回と、録音の権限が拒否されている回は判定しない。
  /// 拒否から戻った回は、続いている会議を新しい会議として扱う。
  func tick(now: ContinuousClock.Instant) async {
    let denied = deniedPermissions()
    if denied != blockedBy {
      if blockedBy.isEmpty {
        logger.error(
          "meeting detection paused error.type=permission_denied app.error.origin=client missing=\(denied.map(\.logName).joined(separator: ","), privacy: .public)"
        )
      } else if denied.isEmpty {
        logger.info("meeting detection resumed")
      }
      blockedBy = denied
    }
    guard denied.isEmpty else {
      detector = MeetingDetector()
      return
    }
    let processes: [AudioProcess]
    do {
      processes = try observe()
    } catch {
      if !observationFailing {
        observationFailing = true
        logger.error(
          "meeting observation failed error.type=\(error.status, privacy: .public) app.error.origin=system app.error.transient=true"
        )
      }
      return
    }
    if observationFailing {
      observationFailing = false
      logger.info("meeting observation recovered")
    }
    let autoRecord = setting.autoRecord
    let before = detector.meeting
    let commands = detector.update(
      processes: processes, recorder: recorder.state.activity, autoRecord: autoRecord, now: now)
    switch (before, detector.meeting) {
    case (nil, let meeting?):
      logger.info(
        "meeting detected app=\(meeting.app.logName, privacy: .public) auto_record=\(autoRecord, privacy: .public)"
      )
    case (let meeting?, nil):
      logger.info("meeting ended app=\(meeting.app.logName, privacy: .public)")
    default: break
    }
    for command in commands {
      switch command {
      case .startRecording(let app):
        logger.info("meeting recording requested app=\(app.logName, privacy: .public)")
        await recorder.start(trigger: .meeting)
        if case .recording = recorder.state {
          let text = MeetingText.started(app)
          notify(text.title, text.body)
        }
      case .notifyDetected(let app):
        let text = MeetingText.detected(app)
        notify(text.title, text.body)
      case .stopRecording:
        await recorder.stop()
      }
    }
  }
}

extension NotificationFailure {
  fileprivate var logName: String {
    switch self {
    case .denied: "notification_denied"
    case .failed: "notification_failed"
    }
  }
}

// main.swift のトップレベルはテストバンドルで実行されないため、遅延初期化されるここに置く。
@MainActor let meetingWatcher = MeetingWatcher(
  observe: readAudioProcesses, deniedPermissions: deniedRecordingPermissions, recorder: recorder,
  setting: MeetingDetectionSetting(),
  notify: { title, body in
    // 通知の許可の確認は本人が答えるまで戻らない。待つと会議の終了の検知が止まるため、待たずに出す。
    // 会議中にモーダルを出さないよう、出せなくても警告に逃がさない。
    Task {
      do throws(NotificationFailure) {
        try await MenuBar.notify(title: title, body: body)
      } catch {
        logger.warning(
          "meeting notification failed error.type=\(error.logName, privacy: .public) app.error.origin=system"
        )
      }
    }
  })
