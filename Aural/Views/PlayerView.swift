import SwiftUI
import AVFoundation
import MediaPlayer
import UniformTypeIdentifiers
import Combine
import UIKit
import ImageIO

struct PlayerView: View {
    @ObservedObject var progress: PlaybackClock
    @EnvironmentObject var store: MusicStore
    @Environment(\.dismiss) var dismiss
    @State private var dragging = false
    @State private var seekValue = 0.0
    var body: some View {
        GeometryReader { geo in
            if let track = store.current {
                ScrollView {
                    VStack(spacing: 20) {
                        HStack { Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width:44,height:44) }.accessibilityLabel("Close player"); Spacer(); Text("NOW PLAYING").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary); Spacer(); Color.clear.frame(width:44,height:44) }
                        Cover(url: store.artworkURL(track)).frame(width: min(geo.size.width - 48, geo.size.height * 0.47), height: min(geo.size.width - 48, geo.size.height * 0.47))
                        HStack { VStack(alignment: .leading,spacing: 5) { Text(track.title).font(.title2.bold()).lineLimit(2); Text(track.artist).font(.title3).foregroundStyle(.secondary); Text(track.format).font(.footnote.weight(.medium)).foregroundStyle(.mint) }; Spacer(); Button { store.favorite(track) } label: { Image(systemName: track.favorite ? "heart.fill" : "heart").font(.title2).frame(width:44,height:44) }.accessibilityLabel("Favorite") }
                        Slider(value: Binding(get: { dragging ? seekValue : min(progress.elapsed,max(progress.duration,1)) }, set: { seekValue = $0 }), in: 0...max(progress.duration,1), onEditingChanged: { active in if active { seekValue = progress.elapsed; dragging = true } else { store.seek(seekValue); dragging = false } }).accessibilityLabel("Playback position")
                        HStack { Text(clock(dragging ? seekValue : progress.elapsed)); Spacer(); Text(clock(progress.duration)) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        HStack { Button { store.toggleShuffle() } label: { Image(systemName: "shuffle").frame(width:44,height:44).foregroundStyle(store.shuffle ? Color.mint : Color.primary) }.accessibilityLabel("Shuffle"); Spacer(); Button { store.advance(-1) } label: { Image(systemName: "backward.end.fill").font(.title2).frame(width:44,height:44) }.accessibilityLabel("Previous"); Spacer(); Button { store.toggle() } label: { Image(systemName: store.playing ? "pause.fill" : "play.fill").font(.system(size:28,weight:.semibold)).frame(width:72,height:72).background(.white,in: Circle()).foregroundStyle(.black) }.accessibilityLabel(store.playing ? "Pause" : "Play"); Spacer(); Button { store.advance(1) } label: { Image(systemName: "forward.end.fill").font(.title2).frame(width:44,height:44) }.accessibilityLabel("Next"); Spacer(); Button { store.repeatOne.toggle() } label: { Image(systemName: store.repeatOne ? "repeat.1" : "repeat").frame(width:44,height:44).foregroundStyle(store.repeatOne ? Color.mint : Color.primary) }.accessibilityLabel("Repeat one") }
                    }.frame(maxWidth: 520).padding(20).frame(maxWidth: .infinity)
                }.scrollBounceBehavior(.basedOnSize)
            } else { ContentUnavailableView("Nothing playing", systemImage: "music.note") }
        }.background(Color(red: 0.07,green: 0.08,blue: 0.09).ignoresSafeArea()).tint(.mint)
    }
    func clock(_ value: Double) -> String { let s = Int(max(0,min(value.isFinite ? value : 0, 999999))); return String(format: "%d:%02d",s/60,s%60) }
}
