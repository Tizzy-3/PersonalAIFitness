import SwiftUI
import ImageIO

/// Only small, bundled GIFs converted from attributed demonstration clips are decoded.
/// No GIF cache: at most the explicitly animated visible preview owns its decoded frames.
@MainActor
struct ExerciseAnimatedThumbnail: View {
    let fileName: String
    let poster: UIImage?
    @State private var animation: UIImage?

    var body: some View {
        Group {
            if let animation { AnimatedImageSurface(image: animation) }
            else if let poster { Image(uiImage: poster).resizable().scaledToFit() }
        }
        .task(id: fileName) { animation = Self.decode(fileName) }
        .onDisappear { animation = nil }
    }

    static func decode(_ fileName: String) -> UIImage? {
        guard let url = ExerciseMediaAsset.url(for: fileName),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1, count <= 400 else { return nil }
        var frames: [UIImage] = []
        var duration: Double = 0
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil), image.width <= 256, image.height <= 256 else { return nil }
            frames.append(UIImage(cgImage: image))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? (1.0 / 6.0)
            duration += max(0.02, min(delay, 1))
        }
        return UIImage.animatedImage(with: frames, duration: duration)
    }
}

@MainActor
private struct AnimatedImageSurface: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.image = image
    }

    static func dismantleUIView(_ uiView: UIImageView, coordinator: ()) {
        uiView.stopAnimating()
        uiView.image = nil
    }
}
