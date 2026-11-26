import SwiftUI
import AVFoundation
import MediaPlayer
import UniformTypeIdentifiers
import Combine
import UIKit
import ImageIO

@MainActor final class PlaybackClock: ObservableObject {
    @Published var elapsed = 0.0
    @Published var duration = 0.0
}
