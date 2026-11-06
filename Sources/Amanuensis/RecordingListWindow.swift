import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: "io.github.mosidas.amanuensis", category: "recording")

@MainActor var recordingsWindow: NSWindow?

/// 録音の一覧のウィンドウを開く。ウィンドウは 1 つだけ作って使い回し、開くたびに保存先を読み直す。
/// 読んだ一覧を返す。
@MainActor @discardableResult
func showRecordings(folder: RecordingFolder = RecordingFolder()) -> MeetingListing {
  let window =
    recordingsWindow
    ?? {
      let window = NSWindow(
        contentRect: .zero, styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered, defer: false)
      window.title = "録音の一覧"
      window.isReleasedWhenClosed = false
      window.setContentSize(NSSize(width: 560, height: 420))
      recordingsWindow = window
      return window
    }()
  let listing = folder.meetings()
  let hosting = NSHostingView(rootView: RecordingListContent(folder: folder, listing: listing))
  hosting.sizingOptions = [.minSize]
  window.contentView = hosting
  window.center()
  NSApp.activate()
  window.makeKeyAndOrderFront(nil)
  return listing
}

/// 「文字起こし」を押した時点の保存先 `listing` で、`meeting` がまだ文字起こし前なら true。
/// 古い行から押しても、済みの transcript.md を上書きしない。
func shouldTranscribe(
  _ meeting: URL, in listing: MeetingListing, recorder: RecorderState, queue: [URL]
) -> Bool {
  guard case .meetings(let meetings) = listing,
    let latest = meetings.first(where: { $0.folder == meeting })
  else { return false }
  return MeetingStatus(of: latest, recorder: recorder, queue: queue) == .untranscribed
}

/// 一覧の状態と操作をつなぐ外殻。待ち行列が変わるたびに保存先を読み直す。
private struct RecordingListContent: View {
  let folder: RecordingFolder
  @State private var listing: MeetingListing
  @State private var openFailed = false

  init(folder: RecordingFolder, listing: MeetingListing) {
    self.folder = folder
    _listing = State(initialValue: listing)
  }

  var body: some View {
    RecordingListView(
      listing: listing, recorder: recorder.state, queue: transcriber.queue,
      openFailed: openFailed, perform: perform, openSettings: showSettings
    )
    .onChange(of: transcriber.queue) { listing = folder.meetings() }
  }

  private func perform(_ action: MeetingAction, _ meeting: Meeting) {
    openFailed = false
    switch action {
    case .transcribe:
      let latest = folder.meetings()
      if shouldTranscribe(
        meeting.folder, in: latest, recorder: recorder.state, queue: transcriber.queue)
      {
        transcriber.request(meeting.folder)
      } else {
        logger.info(
          "transcription request ignored reason=not_untranscribed folder.name=\(meeting.folder.lastPathComponent, privacy: .public)"
        )
      }
      listing = latest
    case .open:
      open(meeting)
    case .reveal:
      NSWorkspace.shared.activateFileViewerSelecting([meeting.folder])
    }
  }

  /// transcript.md を、ファイルの実体でなく `.md` の種類から決めたアプリへ文書として渡す。
  /// 判定の後にリンクへ差し替えられても、LaunchServices はリンク先のアプリを起動しない(点検の実測)。
  private func open(_ meeting: Meeting) {
    guard RecordingFolder.isPlainFile(meeting.transcript) else {
      failOpen(meeting, reason: "not_plain_file")
      return
    }
    guard
      let app = NSWorkspace.shared.urlForApplication(
        toOpen: UTType(filenameExtension: "md") ?? .plainText)
    else {
      failOpen(meeting, reason: "no_application")
      return
    }
    NSWorkspace.shared.open(
      [meeting.transcript], withApplicationAt: app, configuration: .init()
    ) { _, error in
      guard error != nil else { return }
      Task { @MainActor in failOpen(meeting, reason: "open_error") }
    }
  }

  private func failOpen(_ meeting: Meeting, reason: StaticString) {
    logger.warning(
      "transcript open failed error.type=open_failed app.error.origin=system reason=\(reason, privacy: .public) folder.name=\(meeting.folder.lastPathComponent, privacy: .public)"
    )
    openFailed = true
    listing = folder.meetings()
  }
}

/// 録音の一覧。入力の値だけから描く。
struct RecordingListView: View {
  let listing: MeetingListing
  let recorder: RecorderState
  let queue: [URL]
  let openFailed: Bool
  let perform: (MeetingAction, Meeting) -> Void
  let openSettings: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      if openFailed {
        let failure = RecordingListText.openFailed
        Message(title: failure.title, detail: failure.body, isFailure: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
        Divider()
      }
      if let empty = RecordingListText.empty(for: listing) {
        EmptyListView(empty: empty, openSettings: openSettings)
      } else if case .meetings(let meetings) = listing {
        List(meetings, id: \.folder) { meeting in
          row(for: meeting)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func row(for meeting: Meeting) -> some View {
    let status = MeetingStatus(of: meeting, recorder: recorder, queue: queue)
    let display = RecordingListText.row(for: status)
    return HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(RecordingListText.title(for: meeting.date)).fontWeight(.semibold)
        HStack(spacing: 4) {
          if status == .transcribing {
            ProgressView().controlSize(.small)
          }
          Text(display.detail).foregroundStyle(.secondary)
        }
      }
      Spacer()
      ForEach(display.buttons, id: \.label) { button in
        Button(button.label) { perform(button.action, meeting) }
          .buttonStyle(.bordered)
          .help(button.help)
      }
    }
    .padding(.vertical, 4)
    .help(meeting.folder.lastPathComponent)
  }
}

private struct EmptyListView: View {
  let empty: MeetingListEmpty
  let openSettings: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      Text(empty.title).font(.title3).fontWeight(.semibold)
      // 日本語の折り返しは語の途中でも折れるため、文の切れ目で改行する。
      Text(empty.body.split(separator: "。").map { $0 + "。" }.joined(separator: "\n"))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      if empty.opensSettings {
        Button("設定を開く", action: openSettings)
          .buttonStyle(.bordered)
          .padding(.top, 8)
      }
    }
    .frame(maxWidth: 400)
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
