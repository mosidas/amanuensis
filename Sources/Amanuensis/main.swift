import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// トップレベルで保持する。解放されるとメニューバーのアイコンが消える。
let menuBar = MenuBar()
let speechSetup = SpeechSetup()

app.run()
