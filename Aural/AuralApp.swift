import SwiftUI

@main struct AuralApp: App {
    @StateObject private var store = MusicStore()
    var body: some Scene { WindowGroup { RootView().environmentObject(store).preferredColorScheme(.dark) } }
}
