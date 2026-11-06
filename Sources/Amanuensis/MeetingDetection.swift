/// 検知する会議アプリ。表の並びが同時に検知したときの優先の順。
enum MeetingApp: CaseIterable, Equatable {
  case zoom, teams, chrome, slack

  var bundleID: String {
    switch self {
    case .zoom: "us.zoom.xos"
    case .teams: "com.microsoft.teams2"
    case .chrome: "com.google.Chrome"
    case .slack: "com.tinyspeck.slackmacgap"
    }
  }

  /// 利用者に見せるアプリ名。
  var name: String {
    switch self {
    case .zoom: "Zoom"
    case .teams: "Microsoft Teams"
    case .chrome: "Google Chrome"
    case .slack: "Slack"
    }
  }

  /// ログに出すアプリ名。
  var logName: String {
    switch self {
    case .zoom: "zoom"
    case .teams: "teams"
    case .chrome: "chrome"
    case .slack: "slack"
    }
  }

  /// `bundleID` と一致するか `bundleID + "."` で始まる id のアプリ。表に無ければ nil。
  init?(processBundleID: String) {
    guard
      let app = Self.allCases.first(where: {
        processBundleID == $0.bundleID || processBundleID.hasPrefix($0.bundleID + ".")
      })
    else { return nil }
    self = app
  }
}

/// Core Audio のプロセス 1 つの観測。bundle id はプラットフォームが返す形のまま(無ければ空文字)。
struct AudioProcess: Equatable {
  let bundleID: String
  let isRunningInput: Bool
}

enum RecordingTrigger: Equatable { case manual, meeting }

/// 判定が読む録音の状態。`RecorderState` から 1 か所で作る。
enum RecorderActivity: Equatable {
  case idle, busy
  case recording(RecordingTrigger)
}

enum MeetingCommand: Equatable {
  case startRecording(MeetingApp)
  case notifyDetected(MeetingApp)
  case stopRecording(MeetingApp)
}

/// 会議の開始と終了を判定する。状態は会議中か(どのアプリが、最後にいつ観測されたか)だけである。
struct MeetingDetector: Equatable {
  struct Meeting: Equatable {
    let app: MeetingApp
    var lastSeen: ContinuousClock.Instant
  }

  // shortcut: 15 秒は仮の値, 本人の確認(AC 8)でミュートや機器の切り替えの途切れで止まったら延ばす(観測の間隔 2 秒と保存の時間を足して 30 秒未満に収める)
  static let endGrace: Duration = .seconds(15)
  private(set) var meeting: Meeting?

  mutating func update(
    processes: [AudioProcess], recorder: RecorderActivity, autoRecord: Bool,
    now: ContinuousClock.Instant
  ) -> [MeetingCommand] {
    let inUse = processes.filter(\.isRunningInput).compactMap {
      MeetingApp(processBundleID: $0.bundleID)
    }
    if let meeting {
      if !inUse.isEmpty {
        self.meeting?.lastSeen = now
        return []
      }
      guard now - meeting.lastSeen >= Self.endGrace else { return [] }
      self.meeting = nil
      return recorder == .recording(.meeting) ? [.stopRecording(meeting.app)] : []
    }
    guard let app = MeetingApp.allCases.first(where: inUse.contains) else { return [] }
    meeting = Meeting(app: app, lastSeen: now)
    guard recorder == .idle else { return [] }
    return autoRecord ? [.startRecording(app)] : [.notifyDetected(app)]
  }
}
