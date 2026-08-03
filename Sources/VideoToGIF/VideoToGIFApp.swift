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
    @State private var status = "영역을 녹화하거나 MOV 파일을 선택하세요."
    @State private var isWorking = false
    @State private var isImporterPresented = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: sourceURL == nil ? "rectangle.dashed.badge.record" : "checkmark.circle.fill")
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

            HStack(spacing: 12) {
                Button("화면 영역 녹화", systemImage: "record.circle") {
                    recordScreen()
                }
                .buttonStyle(.borderedProminent)

                Button("MOV 파일 선택", systemImage: "movieclapper") {
                    isImporterPresented = true
                }
                .buttonStyle(.bordered)
            }

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

    private func recordScreen() {
        isWorking = true
        status = "드래그하여 녹화 영역을 선택하세요."
        let appWindow = NSApp.keyWindow

        Task {
            defer {
                isWorking = false
                appWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }

            guard let region = await AreaSelector.select(on: appWindow?.screen) else {
                status = "녹화를 취소했습니다."
                return
            }
            appWindow?.orderOut(nil)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("video-to-gif-\(UUID().uuidString).mov")

            do {
                status = "녹화 중 · 메뉴 막대의 정지 버튼 또는 ⌘⌃Esc로 끝내세요."
                try await ScreenRecorder.record(to: url, region: region)
                sourceURL = url
                status = "녹화 완료 · GIF로 저장할 수 있습니다."
            } catch is CancellationError {
                status = "녹화를 취소했습니다."
            } catch {
                status = error.localizedDescription
            }
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

@MainActor
enum ScreenRecorder {
    private static var stopInput: FileHandle?
    private static var statusItem: NSStatusItem?
    private static var stopTarget: RecordingStopTarget?

    static func record(to outputURL: URL, region: CGRect) async throws {
        guard let mainScreen = NSScreen.screens.first else { throw CancellationError() }

        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = arguments(
            outputURL: outputURL,
            region: region,
            mainScreenMaxY: mainScreen.frame.maxY
        )
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        stopInput = input.fileHandleForWriting
        showStopButton()

        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        hideStopButton()
        try? stopInput?.close()
        stopInput = nil

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: outputURL.path) else {
            throw CancellationError()
        }
    }

    nonisolated static func arguments(outputURL: URL, region: CGRect, mainScreenMaxY: CGFloat) -> [String] {
        let x = Int(region.minX.rounded(.down))
        let y = Int((mainScreenMaxY - region.maxY).rounded(.down))
        let width = Int(region.width.rounded(.down))
        let height = Int(region.height.rounded(.down))
        return [
            "-q", "/dev/null", "/usr/sbin/screencapture",
            "-v", "-R\(x),\(y),\(width),\(height)", outputURL.path,
        ]
    }

    static func stop() {
        guard let input = stopInput else { return }
        stopInput = nil
        try? input.write(contentsOf: Data([0x78]))
        try? input.close()
        statusItem?.button?.isEnabled = false
    }

    private static func showStopButton() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let target = RecordingStopTarget()
        item.button?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "녹화 중지")
        item.button?.contentTintColor = .systemRed
        item.button?.toolTip = "녹화 중지"
        item.button?.target = target
        item.button?.action = #selector(RecordingStopTarget.stop)
        statusItem = item
        stopTarget = target
    }

    private static func hideStopButton() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        stopTarget = nil
    }
}

@MainActor
private final class RecordingStopTarget: NSObject {
    @objc func stop() {
        ScreenRecorder.stop()
    }
}

@MainActor
enum AreaSelector {
    private static var window: AreaSelectionPanel?

    static func select(on preferredScreen: NSScreen?) async -> CGRect? {
        // ponytail: one display per selection; use one panel per NSScreen if cross-display drags matter.
        guard let screen = preferredScreen ?? NSScreen.main else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let panel = AreaSelectionPanel(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            let view = AreaSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))

            panel.contentView = view
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            window = panel

            view.onFinish = { [weak panel] rect in
                let screenRect = rect.flatMap { panel?.convertToScreen($0) }
                panel?.close()
                window = nil
                continuation.resume(returning: screenRect)
            }

            NSApp.activate(ignoringOtherApps: true)
            panel.orderFrontRegardless()
            panel.makeKey()
            panel.makeFirstResponder(view)
        }
    }
}

private final class AreaSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AreaSelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var startPoint: CGPoint?
    private var endPoint: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    private var selection: CGRect {
        guard let startPoint, let endPoint else { return .zero }
        return CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        ).intersection(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()

        if !selection.isEmpty {
            NSGraphicsContext.current?.cgContext.clear(selection)
            NSColor.systemRed.setStroke()
            let border = NSBezierPath(rect: selection)
            border.lineWidth = 2
            border.stroke()
        }

        let instruction = NSString(string: "드래그하여 녹화 영역 선택 · Esc 취소")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = instruction.size(withAttributes: attributes)
        instruction.draw(
            at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 28),
            withAttributes: attributes
        )
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        endPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        endPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        endPoint = convert(event.locationInWindow, from: nil)
        guard selection.width >= 16, selection.height >= 16 else {
            startPoint = nil
            endPoint = nil
            needsDisplay = true
            return
        }
        finish(selection)
    }

    override func keyDown(with event: NSEvent) {
        event.keyCode == 53 ? finish(nil) : super.keyDown(with: event)
    }

    private func finish(_ rect: CGRect?) {
        let completion = onFinish
        onFinish = nil
        completion?(rect)
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
