import SwiftUI

@main
@MainActor
struct AuralApp: App {
    @StateObject private var store: MusicStore

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--aural-ui-fixture") {
            do {
                let root = try UITestLibrary.prepare()
                _store = StateObject(wrappedValue: MusicStore(root: root))
            } catch {
                preconditionFailure("UI test fixture could not be created: \(error)")
            }
            return
        }
        #endif
        _store = StateObject(wrappedValue: MusicStore())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
