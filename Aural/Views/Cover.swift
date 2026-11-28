import SwiftUI
import UIKit

struct Cover: View {
    let url: URL?
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    @State private var imageKey: String?

    var body: some View {
        GeometryReader { geo in
            let pixels = max(geo.size.width, geo.size.height) * scale
            let size = pixels <= 160 ? 160 : (pixels <= 512 ? 512 : 1024)
            let key = url.map { "\($0.path)#\(size)" }
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.16))
                if let image, let key, imageKey == key {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note").font(.system(size: max(15, geo.size.width * 0.27))).foregroundStyle(.secondary)
                }
            }.frame(width: geo.size.width, height: geo.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .task(id: key) {
                    guard let url, let key else { image = nil; imageKey = nil; return }
                    let result = await ArtworkCache.shared.image(at: url, maxPixelSize: size)
                    guard !Task.isCancelled else { return }
                    image = result
                    imageKey = key
                }
        }
        .accessibilityHidden(true)
    }
}
