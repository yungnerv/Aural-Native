import SwiftUI
import AVFoundation
import MediaPlayer
import UniformTypeIdentifiers
import Combine
import UIKit
import ImageIO

struct Cover: View {
    let url: URL?
    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.15, green: 0.22, blue: 0.24))
                if let url, let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(systemName: "music.note").font(.system(size: max(15, geo.size.width * 0.27))).foregroundStyle(.mint.opacity(0.7)) }
            }.frame(width: geo.size.width, height: geo.size.height).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
