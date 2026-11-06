import Foundation
import os

private let logger = Logger(subsystem: "io.github.mosidas.amanuensis", category: "recording")

enum Permission: CaseIterable, Equatable {
  case microphone, systemAudio
}

enum RecordingProblem: Error, Equatable {
  case missingPermissions([Permission])
  case captureFailed(StartFailure)
  case folderMissing, folderNotWritable, interrupted, writeFailed, saveFailed, discardFailed
}

/// 録音の保存先。会議ごとのフォルダーをこの下に作る。
struct RecordingFolder {
  private static let key = "recordingFolder"
  /// 会議フォルダーの名前の形式。手元の時刻で `yyyy-MM-dd_HHmmss`。
  private static let meetingName = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "yyyy-MM-dd_HHmmss"
    return formatter
  }()
  private let defaults: UserDefaults
  private let standardRoot: URL

  init(
    defaults: UserDefaults = .standard,
    standardRoot: URL = URL.documentsDirectory.appending(path: "amanuensis")
  ) {
    self.defaults = defaults
    self.standardRoot = standardRoot
  }

  /// 保存先。保存値が絶対パスの文字列でなければ(`defaults write` で壊された値を含む)既定に戻る。
  var root: URL {
    guard let path = defaults.object(forKey: Self.key) as? String, path.hasPrefix("/") else {
      return standardRoot
    }
    return URL(filePath: path, directoryHint: .isDirectory)
  }

  func setRoot(_ url: URL) {
    defaults.set(url.path, forKey: Self.key)
  }

  /// `<root>/<yyyy-MM-dd_HHmmss>` を作って返す。既定の保存先は無ければ作る。
  /// 利用者が選んだ保存先が無いときは何も作らずに `.folderMissing` を投げる。
  /// 保存先に書けないとき・同じ名前のフォルダーが既にあるときは `.folderNotWritable` を投げる。
  func makeMeetingFolder(at date: Date) throws(RecordingProblem) -> URL {
    let fileManager = FileManager.default
    let root = self.root
    if root.path == standardRoot.path {
      do {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
      } catch {
        logFailure("create standard root", error)
        throw .folderNotWritable
      }
    }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw .folderMissing }
    let folder = root.appending(
      path: Self.meetingName.string(from: date), directoryHint: .isDirectory)
    do {
      try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
    } catch {
      logFailure("create meeting folder", error)
      throw .folderNotWritable
    }
    return folder
  }

  /// 会議フォルダーの名前が表す日時。名前が `yyyy-MM-dd_HHmmss` の形と完全に一致しなければ nil。
  static func meetingDate(named name: String) -> Date? {
    guard let date = meetingName.date(from: name), meetingName.string(from: date) == name else {
      return nil
    }
    return date
  }

  private func logFailure(_ step: StaticString, _ error: any Error) {
    let error = error as NSError
    logger.error(
      "\(step, privacy: .public) failed error.domain=\(error.domain, privacy: .public) error.code=\(error.code, privacy: .public)"
    )
  }
}
