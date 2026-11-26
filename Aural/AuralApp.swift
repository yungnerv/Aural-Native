import SwiftUI
import AVFoundation
import MediaPlayer
import UniformTypeIdentifiers
import Combine
import UIKit
import ImageIO

@main struct AuralApp: App {
    @StateObject private var store = MusicStore()
    var body: some Scene { WindowGroup { RootView().environmentObject(store).preferredColorScheme(.dark) } }
}
