import LifetitlesApple
import SwiftUI

@main
struct LifetitlesApp: App {
    // Listens for French and shows English. Pass other languages to change that:
    // LifetitlesEngine(sourceLanguage: Locale.Language(identifier: "es"))
    @State private var engine = LifetitlesEngine()

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
        }
    }
}
