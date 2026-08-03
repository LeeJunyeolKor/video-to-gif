import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct VideoToGIFApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(width: 520, height: 360)
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @State private var sourceURL: URL?
    @State private var status = "MOV 파일을 선택하세요."
    @State private var isWorking = false
    @State private var isImporterPresented = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: sourceURL == nil ? "movieclapper" : "checkmark.circle.fill")
                .font(.system(size: 58))
                .foregroundStyle(sourceURL == nil ? Color.secondary : Color.green)

            VStack(spacing: 8) {
                Text("Video to GIF")
                    .font(.largeTitle.bold())
                Text(status)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }

            Button("MOV 파일 선택", systemImage: "movieclapper") {
                isImporterPresented = true
            }
            .buttonStyle(.borderedProminent)

            Button("GIF로 저장", systemImage: "square.and.arrow.down") {
                saveGIF()
            }
            .disabled(sourceURL == nil || isWorking)

            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(32)
        .disabled(isWorking)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.movie],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            sourceURL = url
            status = url.lastPathComponent
        }
    }

    private func saveGIF() {
        guard let sourceURL else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + ".gif"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        isWorking = true
        status = "GIF로 변환하는 중…"

        Task {
            do {
                let frameCount = try await GIFConverter.convert(sourceURL, to: outputURL)
                status = "저장 완료 · \(frameCount)프레임 · \(outputURL.lastPathComponent)"
            } catch {
                status = error.localizedDescription
            }
            isWorking = false
        }
    }
}

enum GIFConverter {
    static let framesPerSecond = 12.0
    static let maximumSize = CGSize(width: 960, height: 960)

    static func frameTimes(duration: Double, fps: Double = framesPerSecond) -> [CMTime] {
        guard duration.isFinite, duration > 0, fps.isFinite, fps > 0 else { return [] }
        return (0..<max(1, Int(duration * fps))).map {
            CMTime(seconds: Double($0) / fps, preferredTimescale: 600)
        }
    }

    static func convert(_ sourceURL: URL, to outputURL: URL) async throws -> Int {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        let times = frameTimes(duration: duration)
        guard !times.isEmpty else { throw ConversionError.invalidVideo }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            times.count,
            nil
        ) else {
            throw ConversionError.cannotCreateOutput
        }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 1 / framesPerSecond,
                kCGImagePropertyGIFUnclampedDelayTime: 1 / framesPerSecond,
            ]
        ] as CFDictionary

        var writtenFrames = 0
        for time in times {
            let image = try await generator.image(at: time).image
            CGImageDestinationAddImage(destination, image, frameProperties)
            writtenFrames += 1
        }

        guard writtenFrames > 0, CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ConversionError.cannotFinalize
        }

        return writtenFrames
    }
}

enum ConversionError: LocalizedError {
    case invalidVideo
    case cannotCreateOutput
    case cannotFinalize

    var errorDescription: String? {
        switch self {
        case .invalidVideo: "재생 가능한 영상이 아닙니다."
        case .cannotCreateOutput: "GIF 출력 파일을 만들 수 없습니다."
        case .cannotFinalize: "GIF 저장에 실패했습니다."
        }
    }
}
