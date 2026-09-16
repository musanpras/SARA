import SwiftUI
import SARAKit

/// Process entry point. Deliberately thin: the app target owns lifecycle only,
/// and every capability lives in the SARAKit / SARACore modules.
@main
struct SARAApp: App {
    var body: some Scene {
        WindowGroup {
            SARARootView()
        }
    }
}
