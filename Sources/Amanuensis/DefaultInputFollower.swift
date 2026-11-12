@preconcurrency import AVFoundation
import os

private let logger = Logger(subsystem: "io.github.mosidas.amanuensis", category: "capture")

/// 読み始めたマイク。`close` は読むのをやめ、開いたときに作ったものを壊す。
struct OpenedMicrophone {
  let format: AVAudioFormat
  let close: @Sendable () -> Void
}

/// 録音中にシステムの既定の入力を追い、読むマイクを替える。
/// 照合は自分の queue の上だけで行い、writerQueue と ioQueue の上では Core Audio の作成・停止・取り外しをしない。
/// 読んでいるマイクが無くなったら閉じる。既定の入力がまだそのマイクを指す間は開かず、次の `follow` の照合で開く。
final class DefaultInputFollower: @unchecked Sendable {
  private let queue = DispatchQueue(label: "io.github.mosidas.amanuensis.capture.microphone")
  private let open:
    (AudioDevice, _ onLost: @escaping @Sendable () -> Void) throws(StartFailure) ->
      OpenedMicrophone
  private let defaultInput: () -> AudioDevice?
  // current と stopped は queue の上でだけ触る。current が nil のときはマイクを読んでいない。
  private var current: (device: AudioDevice, close: @Sendable () -> Void)?
  private var stopped = false

  /// `open` はデバイスを読み始め、デバイスが無くなったら渡した処理を呼ぶ。`defaultInput` は今の既定の入力を読む。
  init(
    open:
      @escaping (AudioDevice, _ onLost: @escaping @Sendable () -> Void) throws(StartFailure)
      -> OpenedMicrophone,
    defaultInput: @escaping () -> AudioDevice?
  ) {
    self.open = open
    self.defaultInput = defaultInput
  }

  /// 今の既定の入力を読み始める。既定が無ければ `.noInputDevice` を投げる。
  /// `start` より前に `follow` が届いていてもよい。その照合が開いたマイクは `start` が閉じる。
  /// `start` が投げたときも、開いていたマイクは `stop` で閉じる。
  /// `stop` の後の `start` は何も開かずに `.failed(step: "find_microphone", type: "stopped")` を投げる。
  func start() throws(StartFailure) -> (device: AudioDevice, format: AVAudioFormat) {
    try queue.sync {
      Result { () throws(StartFailure) in
        guard !stopped else { throw .failed(step: "find_microphone", type: "stopped") }
        guard let device = defaultInput() else { throw .noInputDevice }
        let opened = try open(device) { [self] in lost(device) }
        let previous = current
        current = (device, opened.close)
        previous?.close()
        return (device, opened.format)
      }
    }.get()
  }

  /// 既定の入力が変わったときに呼ぶ。照合は queue へ投げて待たない。
  func follow() {
    queue.async { [self] in reconcile() }
  }

  /// 読んでいるマイクを閉じる。この後の通知では何もしない。
  func stop() {
    queue.sync {
      stopped = true
      current?.close()
      current = nil
    }
  }

  private func lost(_ device: AudioDevice) {
    queue.async { [self] in
      guard let lostMicrophone = current, lostMicrophone.device.id == device.id else { return }
      current = nil
      lostMicrophone.close()
      logger.warning(
        "capture microphone lost error.type=device_not_alive app.error.origin=system microphone.uid=\(String(reflecting: device.uid), privacy: .public)"
      )
      guard let next = defaultInput(), next.id != device.id else { return }
      switchMicrophone(to: next, from: device)
    }
  }

  // shortcut: HAL の呼び出しに上限を渡す API が無いため切り替えに時間の上限なし, 停止が遅れる報告があれば計測して決める
  private func reconcile() {
    guard !stopped else { return }
    let next = defaultInput()
    guard next?.id != current?.device.id else { return }
    let previous = current
    guard let next else {
      current = nil
      previous?.close()
      logger.warning(
        "capture microphone lost error.type=no_input_device app.error.origin=system microphone.uid=\(String(reflecting: previous?.device.uid ?? ""), privacy: .public)"
      )
      return
    }
    switchMicrophone(to: next, from: previous?.device)
  }

  private func switchMicrophone(to next: AudioDevice, from previousDevice: AudioDevice?) {
    let opened: OpenedMicrophone
    do throws(StartFailure) {
      opened = try open(next) { [self] in lost(next) }
    } catch {
      logger.error(
        "capture microphone switch failed step=\(error.step, privacy: .public) error.type=\(error.type, privacy: .public) app.error.origin=system microphone.uid=\(String(reflecting: next.uid), privacy: .public) microphone.name=\(String(reflecting: next.name), privacy: .public)"
      )
      return
    }
    let previous = current
    current = (next, opened.close)
    // shortcut: 開いてから閉じるので切り替えの直後に 1〜2 バッファーが重なりうる, 重なりで声が乱れる報告があれば閉じてから開く
    previous?.close()
    logger.notice(
      "capture microphone switched microphone.uid=\(String(reflecting: next.uid), privacy: .public) microphone.name=\(String(reflecting: next.name), privacy: .public) microphone=\(Int(opened.format.sampleRate), privacy: .public)/\(opened.format.channelCount, privacy: .public) previous.uid=\(previousDevice.map { String(reflecting: $0.uid) } ?? "none", privacy: .public)"
    )
  }
}
