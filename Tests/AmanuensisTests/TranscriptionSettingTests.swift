import Foundation
import Testing

@testable import Amanuensis

@Test func engineDefaultsToHaasAndKeepsChoice() throws {
  let suiteName = "TranscriptionSettingTests-\(UUID().uuidString)"
  defer { UserDefaults().removePersistentDomain(forName: suiteName) }
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  let setting = TranscriptionSetting(defaults: defaults)

  #expect(setting.engine == .haas, "保存値が無ければ Haas")
  setting.setEngine(.whisper)
  #expect(setting.engine == .whisper)
  #expect(TranscriptionSetting(defaults: defaults).engine == .whisper, "作り直しても選んだ値を読む")
  setting.setEngine(.haas)
  #expect(setting.engine == .haas)
}

@Test func brokenEngineFallsBackToHaas() throws {
  let suiteName = "TranscriptionSettingTests-\(UUID().uuidString)"
  defer { UserDefaults().removePersistentDomain(forName: suiteName) }
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  let setting = TranscriptionSetting(defaults: defaults)

  for stored in ["gpt", "Whisper", ""] {
    defaults.set(stored, forKey: "transcriptionEngine")
    #expect(setting.engine == .haas, "どのエンジンの名前でもない文字列 \(stored) は Haas")
  }
  defaults.set(1, forKey: "transcriptionEngine")
  #expect(setting.engine == .haas, "文字列でない保存値は Haas")
  defaults.set(Data("whisper".utf8), forKey: "transcriptionEngine")
  #expect(setting.engine == .haas, "文字列でない保存値は Haas")
}
