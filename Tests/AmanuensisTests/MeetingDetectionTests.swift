import Testing

@testable import Amanuensis

/// 実機で会議中にマイクを使うプロセスの bundle id。Chrome は観測したヘルパーの id。
private let meetingProcessIDs: [MeetingApp: String] = [
  .zoom: "us.zoom.xos",
  .teams: "com.microsoft.teams2",
  .chrome: "com.google.Chrome.helper",
  .slack: "com.tinyspeck.slackmacgap.helper",
]

private let t0 = ContinuousClock.now

private func at(_ seconds: Int) -> ContinuousClock.Instant { t0 + .seconds(seconds) }

private func usingMicrophone(_ bundleIDs: String...) -> [AudioProcess] {
  bundleIDs.map { AudioProcess(bundleID: $0, isRunningInput: true) }
}

private let silence: [AudioProcess] = []

@Suite struct MeetingDetectionTests {
  @Test(arguments: MeetingApp.allCases) func startsAndStopsRecordingForMeeting(app: MeetingApp)
    throws
  {
    let processes = usingMicrophone(try #require(meetingProcessIDs[app]))
    var detector = MeetingDetector()

    #expect(
      detector.update(processes: processes, recorder: .idle, autoRecord: true, now: at(0))
        == [.startRecording(app)])
    for second in stride(from: 2, through: 14, by: 2) {
      #expect(
        detector.update(
          processes: silence, recorder: .recording(.meeting), autoRecord: true, now: at(second))
          == [], "途切れが \(second) 秒では止めない")
    }
    #expect(
      detector.update(
        processes: silence, recorder: .recording(.meeting), autoRecord: true, now: at(15))
        == [.stopRecording(app)])
  }

  @Test func shortGapsDoNotEndMeeting() {
    let zoom = usingMicrophone("us.zoom.xos")
    var detector = MeetingDetector()

    #expect(
      detector.update(processes: zoom, recorder: .idle, autoRecord: true, now: at(0)) == [
        .startRecording(.zoom)
      ])
    #expect(
      detector.update(
        processes: silence, recorder: .recording(.meeting), autoRecord: true, now: at(14)) == [])
    #expect(
      detector.update(
        processes: zoom, recorder: .recording(.meeting), autoRecord: true, now: at(14)) == [])
    #expect(
      detector.update(
        processes: silence, recorder: .recording(.meeting), autoRecord: true, now: at(28)) == [],
      "使用が戻った時刻から 14 秒の途切れでは止めない")
    #expect(
      detector.update(
        processes: silence, recorder: .recording(.meeting), autoRecord: true, now: at(29))
        == [.stopRecording(.zoom)])
  }

  @Test(arguments: [
    [AudioProcess(bundleID: "us.zoom.xos", isRunningInput: false)],
    usingMicrophone("com.brave.Browser.helper"),
    usingMicrophone("com.google.ChromeBeta"),
    usingMicrophone(""),
  ])
  func ignoresProcessesThatAreNotMeetings(processes: [AudioProcess]) {
    var detector = MeetingDetector()

    #expect(
      detector.update(processes: processes, recorder: .idle, autoRecord: true, now: at(0)) == [])
    #expect(
      detector.update(processes: processes, recorder: .idle, autoRecord: false, now: at(2)) == [])
  }

  @Test func ownMicrophoneUseDoesNotKeepMeetingGoing() {
    let ownRecording = usingMicrophone("io.github.mosidas.amanuensis")
    var detector = MeetingDetector()

    #expect(
      detector.update(
        processes: usingMicrophone("us.zoom.xos", "io.github.mosidas.amanuensis"), recorder: .idle,
        autoRecord: true, now: at(0)) == [.startRecording(.zoom)])
    #expect(
      detector.update(
        processes: ownRecording, recorder: .recording(.meeting), autoRecord: true, now: at(14))
        == [])
    #expect(
      detector.update(
        processes: ownRecording, recorder: .recording(.meeting), autoRecord: true, now: at(15))
        == [.stopRecording(.zoom)])
  }

  @Test(arguments: [RecorderActivity.recording(.manual), .recording(.meeting), .busy])
  func doesNotStartWhileRecorderIsNotIdle(recorder: RecorderActivity) {
    var detector = MeetingDetector()

    #expect(
      detector.update(
        processes: usingMicrophone("us.zoom.xos"), recorder: recorder, autoRecord: true, now: at(0))
        == [])
    #expect(
      detector.update(
        processes: usingMicrophone("us.zoom.xos"), recorder: recorder, autoRecord: false, now: at(2)
      )
        == [])
  }

  @Test func secondMeetingAppDuringMeetingDoesNothing() {
    var detector = MeetingDetector()

    #expect(
      detector.update(
        processes: usingMicrophone("us.zoom.xos"), recorder: .idle, autoRecord: true, now: at(0))
        == [.startRecording(.zoom)])
    #expect(
      detector.update(
        processes: usingMicrophone("us.zoom.xos", "com.google.Chrome.helper"),
        recorder: .recording(.meeting),
        autoRecord: true, now: at(2)) == [])
  }

  @Test func earlierAppInTableWinsWhenDetectedTogether() {
    var detector = MeetingDetector()

    #expect(
      detector.update(
        processes: usingMicrophone("com.google.Chrome.helper", "us.zoom.xos"), recorder: .idle,
        autoRecord: true, now: at(0)) == [.startRecording(.zoom)])
  }

  @Test func otherMeetingAppKeepsMeetingGoing() {
    let chrome = usingMicrophone("com.google.Chrome.helper")
    var detector = MeetingDetector()

    #expect(
      detector.update(
        processes: usingMicrophone("us.zoom.xos"), recorder: .idle, autoRecord: true, now: at(0))
        == [.startRecording(.zoom)])
    #expect(
      detector.update(
        processes: chrome, recorder: .recording(.meeting), autoRecord: true, now: at(2)) == [])
    #expect(
      detector.update(
        processes: chrome, recorder: .recording(.meeting), autoRecord: true, now: at(10)) == [])
    #expect(
      detector.update(
        processes: silence, recorder: .recording(.meeting), autoRecord: true, now: at(24)) == [],
      "表のアプリのどれかが最後に使った時刻から 14 秒では止めない")
    #expect(
      detector.update(
        processes: silence, recorder: .recording(.meeting), autoRecord: true, now: at(25))
        == [.stopRecording(.zoom)])
  }

  @Test func notifiesInsteadOfStartingWhenAutoRecordIsOff() {
    var detector = MeetingDetector()

    #expect(
      detector.update(
        processes: usingMicrophone("us.zoom.xos"), recorder: .idle, autoRecord: false, now: at(0))
        == [.notifyDetected(.zoom)])
    #expect(
      detector.update(
        processes: usingMicrophone("us.zoom.xos"), recorder: .idle, autoRecord: false, now: at(2))
        == [], "同じ会議の間は知らせ直さない")
    #expect(
      detector.update(processes: silence, recorder: .idle, autoRecord: false, now: at(17)) == [])
  }

  @Test func manualRecordingIsNotStoppedWhenMeetingEnds() {
    var detector = MeetingDetector()

    #expect(
      detector.update(
        processes: usingMicrophone("us.zoom.xos"), recorder: .recording(.manual), autoRecord: true,
        now: at(0)) == [])
    #expect(
      detector.update(
        processes: silence, recorder: .recording(.manual), autoRecord: true, now: at(15)) == [])
  }

  @Test func doesNotRestartAfterUserStopsDuringMeeting() {
    let zoom = usingMicrophone("us.zoom.xos")
    var detector = MeetingDetector()

    #expect(
      detector.update(processes: zoom, recorder: .idle, autoRecord: true, now: at(0)) == [
        .startRecording(.zoom)
      ])
    #expect(
      detector.update(processes: zoom, recorder: .idle, autoRecord: true, now: at(2)) == [],
      "会議中に停止・破棄して待機に戻っても始め直さない")
    #expect(
      detector.update(processes: silence, recorder: .idle, autoRecord: true, now: at(17)) == [])
    #expect(
      detector.update(processes: zoom, recorder: .idle, autoRecord: true, now: at(30)) == [
        .startRecording(.zoom)
      ],
      "会議が終わった後の次の会議では始める")
  }
}
