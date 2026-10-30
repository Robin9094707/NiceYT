#if NOVA_SCREENSHOTS
import Foundation

/// Only in the simulator screenshot build (CI): puts the app into a defined state.
@MainActor
enum ScreenshotScenario {
    static func run() {
        let env = ProcessInfo.processInfo.environment
        guard let name = env["NOVA_SCENARIO"] else { return }
        UserDefaults.standard.set(Int.max, forKey: "updatePromptedBuild")
        if let bar = env["NOVA_BAR"].flatMap(BarPosition.init(rawValue:)) { BrowserLibrary.shared.barPosition = bar }
        let browser = BrowserModel.shared
        let page = URL(string: env["NOVA_URL"] ?? "https://de.wikipedia.org")!
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            switch name {
            case "start":
                browser.open(nil)
            case "page":
                browser.open(page)
            case "newtab":
                browser.open(page)
                try? await Task.sleep(for: .seconds(5))
                browser.newTab()
            case "tabs":
                browser.open(page)
                try? await Task.sleep(for: .seconds(5))
                browser.newTab(URL(string: "https://www.apple.com/de/")!)
                try? await Task.sleep(for: .seconds(4))
                browser.showTabOverview()
            case "assistant":
                DownloadAssistant.shared.start(page, autoStart: false)
            default:
                break
            }
        }
    }
}
#endif
