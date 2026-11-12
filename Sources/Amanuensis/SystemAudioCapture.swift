@preconcurrency import AVFoundation
import CoreAudio
import os

private let logger = Logger(subsystem: "io.github.mosidas.amanuensis", category: "capture")

/// 拒否されている録音の権限を `Permission.allCases` の順で返す。確認を出さず、未確認の権限は含めない。
func deniedRecordingPermissions() -> [Permission] {
  var denied: [Permission] = []
  if AVCaptureDevice.authorizationStatus(for: .audio).refusesRecording {
    denied.append(.microphone)
  }
  if SystemAudioAccess.current() == .denied { denied.append(.systemAudio) }
  return denied
}

/// 録音に足りない権限を `Permission.allCases` の順で返す。値は保存せず、呼ぶたびに今の状態から判定する。
/// マイクとシステムオーディオ録音が未確認なら確認を出して答えを待つ。
func checkRecordingPermissions() async -> [Permission] {
  var missing: [Permission] = []
  let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
  if microphone == .notDetermined {
    if await !AVCaptureDevice.requestAccess(for: .audio) { missing.append(.microphone) }
  } else if microphone.refusesRecording {
    missing.append(.microphone)
  }
  switch SystemAudioAccess.current() {
  case .granted: break
  case .undetermined:
    if await !SystemAudioAccess.request() { missing.append(.systemAudio) }
  case .denied: missing.append(.systemAudio)
  case .unavailable:
    logger.error("permission check unavailable error.type=tcc_unavailable app.error.origin=system")
  }
  return missing
}

extension AVAuthorizationStatus {
  /// 録音を許していない。未確認は含めず、SDK で増えた値は許していないに数える。
  fileprivate var refusesRecording: Bool { self != .authorized && self != .notDetermined }
}

/// システムオーディオ録音の許可の状態。
// システムオーディオ録音の許可を確かめる公開 API が無い(macOS 26 の SDK と AudioCap の README)ため、TCC の非公開の関数で判定する。
enum SystemAudioAccess {
  case granted, denied, undetermined, unavailable

  private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
  private typealias Request =
    @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

  private static var service: CFString { "kTCCServiceAudioCapture" as CFString }

  static func current() -> SystemAudioAccess {
    guard let preflight = symbol("TCCAccessPreflight", as: Preflight.self) else {
      return .unavailable
    }
    switch preflight(service, nil) {
    case 0: return .granted
    case 1: return .denied
    default: return .undetermined
    }
  }

  /// macOS の確認を出し、答えを返す。確認を出せなければ録音を止めないために true を返す。
  static func request() async -> Bool {
    guard let request = symbol("TCCAccessRequest", as: Request.self) else {
      logger.error(
        "permission check unavailable error.type=tcc_unavailable app.error.origin=system")
      return true
    }
    return await withCheckedContinuation { continuation in
      request(service, nil) { continuation.resume(returning: $0) }
    }
  }

  private static func symbol<Function>(_ name: String, as type: Function.Type) -> Function? {
    guard
      let framework = dlopen(
        "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
      let pointer = dlsym(framework, name)
    else { return nil }
    return unsafeBitCast(pointer, to: type)
  }
}

/// システム音声を process tap、マイクを `microphone` のデバイスから取り込み、`file` へ書く。
@MainActor func startSystemAudioCapture(
  file: URL, microphone: MicrophoneChoice,
  onInterrupt: @escaping @Sendable (RecordingProblem) -> Void
) async throws -> CaptureSession {
  try await openCapture(file: file, microphone: microphone, onInterrupt: onInterrupt)
}

/// 取り込みを始められなかった理由。ログの step と error.type はここから決まる。
enum StartFailure: Error, Equatable {
  case noInputDevice
  /// `name` はデバイス名を読めなかったときに nil。
  case unsupportedInput(name: String?, channels: Int)
  /// 保存したマイクが入力デバイスの一覧に無い。`name` は保存した表示名。
  case selectedMicrophoneMissing(name: String)
  case failed(step: String, type: String)

  var step: String {
    switch self {
    case .noInputDevice, .unsupportedInput, .selectedMicrophoneMissing: "find_microphone"
    case .failed(let step, _): step
    }
  }

  var type: String {
    switch self {
    case .noInputDevice: "no_input_device"
    case .unsupportedInput: "unsupported_format"
    case .selectedMicrophoneMissing: "selected_device_missing"
    case .failed(_, let type): type
    }
  }
}

private func check(_ status: OSStatus, _ step: String) throws(StartFailure) {
  if status != noErr { throw .failed(step: step, type: String(status)) }
}

// IOProc とリスナーの block を MainActor の文脈で作ると、HAL のスレッドから呼ばれた時点で異常終了する(実測)。
// そのため準備は nonisolated の関数で行う。
nonisolated private func openCapture(
  file: URL, microphone: MicrophoneChoice,
  onInterrupt: @escaping @Sendable (RecordingProblem) -> Void
) async throws -> CaptureSession {
  let begin = ContinuousClock.now
  let pipe = CapturePipe(writer: try StereoRecordingWriter(url: file), onInterrupt: onInterrupt)
  let prepared:
    (microphone: AudioDevice, microphoneFormat: AVAudioFormat, systemAudio: AVAudioFormat)
  do throws(StartFailure) {
    prepared = try prepare(pipe, microphone: microphone)
  } catch {
    logger.error(
      "capture failed step=\(error.step, privacy: .public) error.type=\(error.type, privacy: .public) app.error.origin=system"
    )
    pipe.teardown.run()
    throw RecordingProblem.captureFailed(error)
  }
  let startMilliseconds = Int((ContinuousClock.now - begin) / .milliseconds(1))
  logger.notice(
    "capture started microphone=\(Int(prepared.microphoneFormat.sampleRate), privacy: .public)/\(prepared.microphoneFormat.channelCount, privacy: .public) system_audio=\(Int(prepared.systemAudio.sampleRate), privacy: .public)/\(prepared.systemAudio.channelCount, privacy: .public) start_ms=\(startMilliseconds, privacy: .public) microphone.choice=\(microphone == .systemDefault ? "default" : "device", privacy: .public) microphone.uid=\(String(reflecting: prepared.microphone.uid), privacy: .public) microphone.name=\(String(reflecting: prepared.microphone.name), privacy: .public)"
  )
  return CaptureSession {
    pipe.markStopping()
    pipe.teardown.run()
    // HAL は IO スレッドから ioQueue へ dispatch_sync するため、AudioDeviceStop の後は通常は空である。念のため流し切ってから閉じる。
    pipe.ioQueue.sync {}
    return try await pipe.finish()
  }
}

/// tap・集約デバイス・IOProc・リスナーを作って取り込みを始め、読んでいるマイクと 2 つの音源の形式を返す。
/// 作ったものを壊す手順は `pipe.teardown` に積む。
nonisolated private func prepare(_ pipe: CapturePipe, microphone choice: MicrophoneChoice)
  throws(StartFailure)
  -> (microphone: AudioDevice, microphoneFormat: AVAudioFormat, systemAudio: AVAudioFormat)
{
  let system = AudioObjectID(kAudioObjectSystemObject)
  let microphone: (device: AudioDevice, format: AVAudioFormat)
  let closeMicrophone: @Sendable () -> Void
  switch choice {
  case .systemDefault:
    let follower = DefaultInputFollower(
      open: { device, onLost throws(StartFailure) in
        try openMicrophone(device, pipe, onLost: onLost)
      },
      defaultInput: readDefaultInput)
    try watchDefaultInput(pipe) { follower.follow() }
    closeMicrophone = { follower.stop() }
    pipe.teardown.add(closeMicrophone)
    microphone = try follower.start()
  case .device(let uid, let name):
    let device = try selectedMicrophone(uid: uid, name: name, in: readInputDevices())
    let opened = try openMicrophone(device, pipe) { pipe.interrupt(source: .microphone) }
    closeMicrophone = opened.close
    pipe.teardown.add(closeMicrophone)
    microphone = (device, opened.format)
  }

  var ownProcess = AudioObjectID(kAudioObjectUnknown)
  let translated = read(
    system, kAudioHardwarePropertyTranslatePIDToProcessObject, into: &ownProcess,
    qualifier: getpid())
  let excluded = translated == noErr && ownProcess != kAudioObjectUnknown ? [ownProcess] : []

  let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
  description.isPrivate = true
  description.name = "amanuensis"
  var tap = AudioObjectID(kAudioObjectUnknown)
  try check(AudioHardwareCreateProcessTap(description, &tap), "create_tap")
  pipe.teardown.add { [tap] in stopCheck(AudioHardwareDestroyProcessTap(tap), "destroy") }
  var tapUID: Unmanaged<CFString>?
  try check(read(tap, kAudioTapPropertyUID, into: &tapUID), "create_tap")
  var tapDescription = AudioStreamBasicDescription()
  try check(read(tap, kAudioTapPropertyFormat, into: &tapDescription), "create_tap")
  guard let tapUID = tapUID?.takeRetainedValue(),
    let systemFormat = AVAudioFormat(streamDescription: &tapDescription)
  else { throw .failed(step: "create_tap", type: "unsupported_format") }

  let aggregateDescription: [String: Any] = [
    kAudioAggregateDeviceNameKey: "amanuensis",
    // 私有の集約デバイスも作ったプロセスの一覧には見える(AudioHardware.h の kAudioAggregateDeviceIsPrivateKey)ため、接頭辞で見分ける。
    kAudioAggregateDeviceUIDKey: privateAggregateUIDPrefix + UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
  ]
  var aggregate = AudioObjectID(kAudioObjectUnknown)
  try check(
    AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate),
    "create_aggregate")
  pipe.teardown.add { [aggregate] in
    stopCheck(AudioHardwareDestroyAggregateDevice(aggregate), "destroy")
  }

  try startReading(aggregate, as: .systemAudio, format: systemFormat, pipe, into: pipe.teardown) {
    pipe.interrupt(source: .systemAudio)
  }
  // 片付けは逆順に動くため、もう一度積んでマイクをシステム音声より先に止め、末尾にマイクだけの区間を書かない。2 回目の呼び出しは何もしない。
  pipe.teardown.add(closeMicrophone)
  return (microphone.device, microphone.format, systemFormat)
}

/// `device` の入力を読み始める。読めなくなったら `onLost` を呼ぶ。開くたびに作ったものを壊す手順は `close` にまとめる。
nonisolated private func openMicrophone(
  _ device: AudioDevice, _ pipe: CapturePipe, onLost: @escaping @Sendable () -> Void
) throws(StartFailure) -> OpenedMicrophone {
  let format = try inputFormat(of: device.id)
  let teardown = Teardown()
  do throws(StartFailure) {
    try startReading(
      device.id, as: .microphone, format: format, pipe, into: teardown, onLost: onLost)
  } catch {
    teardown.run()
    throw error
  }
  return OpenedMicrophone(format: format) { teardown.run() }
}

/// `device` に IOProc を張って始め、デバイスが無くなったら `onLost` を呼ぶリスナーを付ける。壊す手順は `teardown` に積む。
nonisolated private func startReading(
  _ device: AudioObjectID, as source: RecordingSource, format: AVAudioFormat, _ pipe: CapturePipe,
  into teardown: Teardown, onLost: @escaping @Sendable () -> Void
) throws(StartFailure) {
  var proc: AudioDeviceIOProcID?
  try check(
    AudioDeviceCreateIOProcIDWithBlock(
      &proc, device, pipe.ioQueue, pipe.ioBlock(for: source, format: format)),
    "create_ioproc")
  guard let proc else { throw .failed(step: "create_ioproc", type: "no_ioproc") }
  teardown.add { stopCheck(AudioDeviceDestroyIOProcID(device, proc), "destroy") }
  try check(AudioDeviceStart(device, proc), "start_device")
  teardown.add { stopCheck(AudioDeviceStop(device, proc), "stop_device") }
  var address = propertyAddress(kAudioDevicePropertyDeviceIsAlive)
  // AudioObjectRemovePropertyListenerBlock は付けたときと同じ block を求める(AudioHardware.h)。
  let listener = pipe.aliveListener(for: device, onLost: onLost)
  try check(
    AudioObjectAddPropertyListenerBlock(device, &address, pipe.writerQueue, listener),
    "add_listener")
  teardown.add {
    var address = propertyAddress(kAudioDevicePropertyDeviceIsAlive)
    stopCheck(
      AudioObjectRemovePropertyListenerBlock(device, &address, pipe.writerQueue, listener),
      "destroy")
  }
}

/// システムの既定の入力が変わるたびに、writerQueue の上で `onChange` を呼ぶ。外す手順は `pipe.teardown` に積む。
nonisolated private func watchDefaultInput(
  _ pipe: CapturePipe, _ onChange: @escaping @Sendable () -> Void
) throws(StartFailure) {
  let system = AudioObjectID(kAudioObjectSystemObject)
  var address = propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
  let listener:
    @Sendable @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = {
      _, _ in onChange()
    }
  try check(
    AudioObjectAddPropertyListenerBlock(system, &address, pipe.writerQueue, listener),
    "add_listener")
  pipe.teardown.add {
    var address = propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
    stopCheck(
      AudioObjectRemovePropertyListenerBlock(system, &address, pipe.writerQueue, listener),
      "destroy")
  }
}

/// 入力デバイスの先頭の入力ストリームの形式。IOProc はこの形式でバッファーを渡す。
nonisolated private func inputFormat(of device: AudioObjectID) throws(StartFailure) -> AVAudioFormat
{
  var streams: [AudioStreamID] = []
  try check(
    readList(
      device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, into: &streams),
    "find_microphone")
  guard let stream = streams.first else { throw .noInputDevice }
  var description = AudioStreamBasicDescription()
  try check(read(stream, kAudioStreamPropertyVirtualFormat, into: &description), "find_microphone")
  guard let format = inputFormat(from: description) else {
    throw .unsupportedInput(name: deviceName(device), channels: Int(description.mChannelsPerFrame))
  }
  return format
}

/// デバイスの表示名。読めなければ nil。
func deviceName(_ device: AudioObjectID) -> String? {
  var name: Unmanaged<CFString>?
  guard read(device, kAudioObjectPropertyName, into: &name) == noErr, let name else { return nil }
  return name.takeRetainedValue() as String
}

/// 入力ストリームの ASBD から形式を作る。作れなければ nil を返す。
func inputFormat(from description: AudioStreamBasicDescription) -> AVAudioFormat? {
  var description = description
  if let format = AVAudioFormat(streamDescription: &description) { return format }
  // AVAudioFormat は 3 ch 以上の形式をチャンネルレイアウトなしでは作れない(AVAudioFormat.h)。
  guard
    let layout = AVAudioChannelLayout(
      layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | description.mChannelsPerFrame)
  else { return nil }
  guard let format = AVAudioFormat(streamDescription: &description, channelLayout: layout),
    format.commonFormat != .otherFormat
  else { return nil }
  return format
}

func propertyAddress(
  _ selector: AudioObjectPropertySelector,
  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(
    mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func read<Value>(
  _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout Value,
  qualifier: pid_t? = nil
) -> OSStatus {
  var address = propertyAddress(selector)
  var size = UInt32(MemoryLayout<Value>.size)
  return withUnsafeMutablePointer(to: &value) { value in
    guard var qualifier else {
      return AudioObjectGetPropertyData(object, &address, 0, nil, &size, value)
    }
    return AudioObjectGetPropertyData(
      object, &address, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, value)
  }
}

/// 可変長の ID の配列を読む。
func readList(
  _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
  into list: inout [AudioObjectID]
) -> OSStatus {
  var address = propertyAddress(selector, scope: scope)
  var size: UInt32 = 0
  let sized = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
  guard sized == noErr else { return sized }
  var items = [AudioObjectID](
    repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
  let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &items)
  guard status == noErr else { return status }
  list = Array(items.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
  return noErr
}

/// 片付けの失敗はログに残し、残りの片付けを続ける。
private func stopCheck(_ status: OSStatus, _ step: StaticString) {
  guard status != noErr else { return }
  logger.error(
    "capture stop failed step=\(step, privacy: .public) error.type=\(status, privacy: .public) app.error.origin=system"
  )
}

/// 作った Core Audio のオブジェクトを壊す手順。作った順に積み、逆順に 1 回だけ実行する。
private final class Teardown: Sendable {
  private let steps = OSAllocatedUnfairLock<[@Sendable () -> Void]>(initialState: [])

  func add(_ step: @escaping @Sendable () -> Void) {
    steps.withLock { $0.append(step) }
  }

  func run() {
    let taken = steps.withLock { steps in
      defer { steps = [] }
      return steps
    }
    for step in taken.reversed() { step() }
  }
}

/// 2 つの IOProc から届いた音声を writer へ渡し、取り込みが止まったら 1 回だけ `onInterrupt` を呼ぶ。
private final class CapturePipe: @unchecked Sendable {
  let ioQueue = DispatchQueue(label: "io.github.mosidas.amanuensis.capture.io")
  let writerQueue = DispatchQueue(label: "io.github.mosidas.amanuensis.capture")
  let teardown = Teardown()
  private let onInterrupt: @Sendable (RecordingProblem) -> Void
  // writer・invalidBuffers・ended・heardSystemAudio は writerQueue の上でだけ触る。
  private let writer: StereoRecordingWriter
  private var invalidBuffers = 0
  private var ended = false
  private var heardSystemAudio = false

  init(writer: StereoRecordingWriter, onInterrupt: @escaping @Sendable (RecordingProblem) -> Void) {
    self.writer = writer
    self.onInterrupt = onInterrupt
  }

  /// HAL の IO スレッドから ioQueue の上で呼ばれる block。AudioBufferList は block の中でしか有効でないため、ここで写す。
  nonisolated func ioBlock(for source: RecordingSource, format: AVAudioFormat) -> AudioDeviceIOBlock
  {
    { [self] _, inputData, inputTime, _, _ in
      let time = inputTime.pointee
      let buffer =
        time.mFlags.contains(.hostTimeValid) ? pcmBuffer(inputData, format: format) : nil
      let seconds = Double(AudioConvertHostTimeToNanos(time.mHostTime)) / 1e9
      writerQueue.async { [self] in
        guard let buffer else {
          invalidBuffers += 1
          return
        }
        receive(buffer, from: source, at: seconds)
      }
    }
  }

  /// writerQueue の上で呼ばれる block。取り込みを終える前にデバイスが無くなったら `onLost` を呼ぶ。
  nonisolated func aliveListener(
    for device: AudioObjectID, onLost: @escaping @Sendable () -> Void
  ) -> @Sendable @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void {
    { [self] _, _ in
      var alive: UInt32 = 1
      guard read(device, kAudioDevicePropertyDeviceIsAlive, into: &alive) != noErr || alive == 0,
        !ended
      else { return }
      onLost()
    }
  }

  /// `source` のデバイスを失ったとして取り込みを終える。writerQueue の上で呼ぶ。
  func interrupt(source: RecordingSource) {
    let name = source == .microphone ? "microphone" : "system_audio"
    logger.error(
      "capture interrupted error.type=device_not_alive source=\(name, privacy: .public) app.error.origin=system"
    )
    end(.interrupted)
  }

  /// 停止を始めた印を立てる。壊す処理より前に呼ぶ。届いた音声はこの後も書く。
  // リスナーを外した後も、集約デバイスを壊してから 1〜5 ms 後に DeviceIsAlive の通知が writerQueue へ積まれる(実測)。
  // 壊す前に writerQueue の上で印を立て、停止で起きた通知を中断として扱わない。
  func markStopping() {
    writerQueue.sync { ended = true }
  }

  /// writer を閉じて秒数を返す。
  func finish() async throws -> TimeInterval {
    try await withCheckedThrowingContinuation { continuation in
      writerQueue.async { [self] in
        let result = Result { try writer.finish() }
        logger.notice(
          "capture stopped duration_s=\((try? result.get()) ?? 0, format: .fixed(precision: 1), privacy: .public) dropped_frames=\(self.writer.droppedFrames, privacy: .public) invalid_buffers=\(self.invalidBuffers, privacy: .public) system_audio_heard=\(self.heardSystemAudio, privacy: .public)"
        )
        continuation.resume(with: result)
      }
    }
  }

  private func receive(_ buffer: AVAudioPCMBuffer, from source: RecordingSource, at time: Double) {
    if source == .systemAudio, !heardSystemAudio {
      heardSystemAudio = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).contains
      {
        UnsafeRawBufferPointer(start: $0.mData, count: Int($0.mDataByteSize)).contains { $0 != 0 }
      }
    }
    do {
      try writer.append(buffer, from: source, at: time)
    } catch {
      guard !ended else { return }
      logger.error("capture failed step=write error.type=file_system app.error.origin=system")
      end(.writeFailed)
    }
  }

  /// 書いた分を閉じて `onInterrupt` を呼び、デバイスを止める。
  private func end(_ problem: RecordingProblem) {
    ended = true
    _ = try? writer.finish()
    onInterrupt(problem)
    // リスナーの queue の上でリスナーを外さないため、片付けは別の queue で行う。
    DispatchQueue.global().async { [teardown] in teardown.run() }
  }
}

/// IOProc が渡したバッファーを `AVAudioPCMBuffer` へ写す。3 ch 以上は先頭チャンネルだけのモノラルにする。
/// バッファーの数・大きさが形式と合わなければ nil を返す。形式が必要とする数より多いバッファーは捨てる。
func pcmBuffer(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
  let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
  let needed = format.isInterleaved ? 1 : Int(format.channelCount)
  let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
  guard bytesPerFrame > 0, buffers.count >= needed else { return nil }
  let sources = buffers.prefix(needed)
  let frames = Int(sources[0].mDataByteSize) / bytesPerFrame
  guard
    frames > 0,
    sources.allSatisfy({ Int($0.mDataByteSize) == frames * bytesPerFrame && $0.mData != nil })
  else { return nil }
  if format.channelCount > 2 {
    guard
      let mono = AVAudioFormat(
        commonFormat: format.commonFormat, sampleRate: format.sampleRate, channels: 1,
        interleaved: false),
      let copy = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(frames)),
      let destination = copy.mutableAudioBufferList.pointee.mBuffers.mData
    else { return nil }
    copy.frameLength = AVAudioFrameCount(frames)
    let sampleBytes = Int(mono.streamDescription.pointee.mBytesPerFrame)
    for frame in 0..<frames {
      (destination + frame * sampleBytes).copyMemory(
        from: sources[0].mData! + frame * bytesPerFrame, byteCount: sampleBytes)
    }
    return copy
  }
  guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
  else { return nil }
  copy.frameLength = AVAudioFrameCount(frames)
  let destinations = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
  for (destination, source) in zip(destinations, sources) {
    destination.mData!.copyMemory(from: source.mData!, byteCount: Int(source.mDataByteSize))
  }
  return copy
}
