import Foundation
import Testing

@testable import Amanuensis

private let t0 = ContinuousClock.now

private func at(_ seconds: Int) -> ContinuousClock.Instant { t0 + .seconds(seconds) }

private let zoomInUse = [AudioProcess(bundleID: "us.zoom.xos", isRunningInput: true)]

private let startedNotice = [
  "会議の録音を開始しました",
  "Zoom がマイクを使い始めたので、録音を開始しました。会議でなければ、メニューの「破棄…」で削除できます。",
]

/// 偽の観測と通知の記録で、実物の `Recorder`(偽の取り込み)と実物の判定を動かす。
@MainActor private final class Fixture {
  let harness: RecorderHarness
  let recorder: Recorder
  let setting: MeetingDetectionSetting
  var observed: Result<[AudioProcess], ObserveFailure> = .success([])
  var denied: [Permission] = []
  private(set) var notifications: [[String]] = []

  init() throws {
    harness = try RecorderHarness()
    recorder = try harness.recorder()
    setting = MeetingDetectionSetting(
      defaults: try #require(UserDefaults(suiteName: harness.suiteName)))
  }

  lazy var watcher = MeetingWatcher(
    observe: { [unowned self] () throws(ObserveFailure) -> [AudioProcess] in try observed.get() },
    deniedPermissions: { [unowned self] in denied }, recorder: recorder, setting: setting,
    notify: { [unowned self] in notifications.append([$0, $1]) })

  func tick(_ processes: [AudioProcess], at seconds: Int) async {
    observed = .success(processes)
    await watcher.tick(now: at(seconds))
  }
}

enum UserEnding: CaseIterable { case stop, discard }

// RecorderTests はスリープの抑止をプロセス全体で数えるため、録音するテストはその直列の下に置く。
extension RecorderTests {
  @Suite @MainActor struct MeetingWatcherTests {
    @Test func recordsMeetingAndStopsWhenItEnds() async throws {
      let fixture = try Fixture()
      defer { fixture.harness.remove() }

      await fixture.tick(zoomInUse, at: 0)

      guard case .recording(let recording) = fixture.recorder.state else {
        Issue.record("録音中になる: \(fixture.recorder.state)")
        return
      }
      #expect(fixture.recorder.state.activity == .recording(.meeting))
      #expect(fixture.notifications == [startedNotice])

      await fixture.tick([], at: 14)
      #expect(fixture.recorder.state.activity == .recording(.meeting), "途切れが 15 秒未満なら続ける")
      await fixture.tick([], at: 15)

      #expect(fixture.recorder.state == .idle)
      #expect(
        FileManager.default.fileExists(
          atPath: recording.folder.appending(path: "recording.caf").path), "録音のファイルを残す")
      #expect(fixture.notifications == [startedNotice], "停止の通知は出さない")
      #expect(fixture.harness.reports.isEmpty)
    }

    @Test func onlyNotifiesWhenAutoRecordIsOff() async throws {
      let fixture = try Fixture()
      defer { fixture.harness.remove() }
      fixture.setting.setAutoRecord(false)

      await fixture.tick(zoomInUse, at: 0)
      await fixture.tick(zoomInUse, at: 2)

      #expect(fixture.harness.captureCalls == 0)
      #expect(fixture.recorder.state == .idle)
      #expect(
        fixture.notifications == [
          [
            "会議を検知しました",
            "Zoom がマイクを使い始めました。録音するには、メニューの「録音を開始」を選んでください。",
          ]
        ])
    }

    @Test func brokenSettingFallsBackToAutoRecord() throws {
      let harness = try RecorderHarness()
      defer { harness.remove() }
      let defaults = try #require(UserDefaults(suiteName: harness.suiteName))
      defaults.set("no", forKey: "autoRecordMeetings")

      #expect(MeetingDetectionSetting(defaults: defaults).autoRecord, "Bool でない保存値は既定のオン")
    }

    @Test func startFailureReportsOnceAndDoesNotRetryDuringMeeting() async throws {
      let fixture = try Fixture()
      defer { fixture.harness.remove() }
      fixture.harness.behavior = .fail

      await fixture.tick(zoomInUse, at: 0)
      await fixture.tick(zoomInUse, at: 2)

      #expect(fixture.harness.reports == [.captureFailed(.noInputDevice)])
      #expect(fixture.harness.captureCalls == 1, "同じ会議の間は始め直さない")
      #expect(fixture.notifications.isEmpty, "開始の通知を出さない")
      #expect(fixture.recorder.state == .idle)
    }

    @Test func observationFailureKeepsRecording() async throws {
      let fixture = try Fixture()
      defer { fixture.harness.remove() }
      await fixture.tick(zoomInUse, at: 0)

      fixture.observed = .failure(ObserveFailure(status: -1))
      for second in stride(from: 2, through: 20, by: 2) {
        await fixture.watcher.tick(now: at(second))
      }
      #expect(fixture.recorder.state.activity == .recording(.meeting), "観測の失敗中は止めない")

      await fixture.tick(zoomInUse, at: 22)
      await fixture.tick([], at: 36)
      #expect(fixture.recorder.state.activity == .recording(.meeting))
      await fixture.tick([], at: 37)

      #expect(fixture.recorder.state == .idle, "回復後に使用なしが 15 秒続けば止まる")
      #expect(fixture.harness.reports.isEmpty)
    }

    @Test(arguments: UserEnding.allCases)
    func userEndingAutoRecordingIsNotRestartedDuringMeeting(ending: UserEnding) async throws {
      let fixture = try Fixture()
      defer { fixture.harness.remove() }
      await fixture.tick(zoomInUse, at: 0)
      guard case .recording(let recording) = fixture.recorder.state else {
        Issue.record("録音中になる: \(fixture.recorder.state)")
        return
      }

      switch ending {
      case .stop: await fixture.recorder.stop()
      case .discard: await fixture.recorder.discard()
      }
      await fixture.tick(zoomInUse, at: 2)

      #expect(fixture.recorder.state == .idle)
      #expect(fixture.harness.captureCalls == 1, "会議が続いても始め直さない")
      let kept = FileManager.default.fileExists(atPath: recording.folder.path)
      #expect(kept == (ending == .stop), "破棄なら会議フォルダーを残さない")
      #expect(fixture.harness.reports.isEmpty)
    }

    @Test func pausesDetectionWhileRecordingPermissionIsDenied() async throws {
      let fixture = try Fixture()
      defer { fixture.harness.remove() }
      fixture.denied = [.microphone]

      await fixture.tick(zoomInUse, at: 0)
      await fixture.tick(zoomInUse, at: 2)

      #expect(fixture.watcher.blockedBy == [.microphone])
      #expect(fixture.harness.captureCalls == 0, "権限が足りない間は録音しない")
      #expect(fixture.notifications.isEmpty, "権限が足りない間は通知しない")
      #expect(fixture.harness.reports.isEmpty, "会議のたびに警告を出さない")

      await fixture.recorder.start()
      #expect(fixture.recorder.state.activity == .recording(.manual), "手動の録音は従来どおり始まる")
    }

    @Test func resumedDetectionTreatsOngoingMeetingAsNew() async throws {
      let fixture = try Fixture()
      defer { fixture.harness.remove() }
      await fixture.tick(zoomInUse, at: 0)
      // 会議フォルダーの名前は秒の単位なので、同じ秒の 2 回目の録音と衝突しないよう破棄で消す。
      await fixture.recorder.discard()

      fixture.denied = [.systemAudio]
      await fixture.tick(zoomInUse, at: 2)
      #expect(fixture.watcher.blockedBy == [.systemAudio])

      fixture.denied = []
      await fixture.tick(zoomInUse, at: 4)

      #expect(fixture.watcher.blockedBy.isEmpty)
      #expect(fixture.recorder.state.activity == .recording(.meeting), "続いている会議を新しい会議として録音する")
      #expect(fixture.harness.captureCalls == 2)
      #expect(fixture.notifications == [startedNotice, startedNotice])
      #expect(fixture.harness.reports.isEmpty)
    }

    @Test func readsAudioProcessesWithoutThrowing() {
      #expect(throws: Never.self) { _ = try readAudioProcesses() }
    }
  }
}
