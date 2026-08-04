import AVFoundation
import AVKit
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

enum ActivityStatus {
    case idle(String)
    case ready(String)
    case selecting
    case recording
    case processing(String)
    case success(String)
    case failure(String)

    var presentation: (message: String, symbolName: String, color: Color) {
        switch self {
        case let .idle(message): (message, "circle.dashed", .secondary)
        case let .ready(message): (message, "movieclapper", .accentColor)
        case .selecting: ("드래그하여 녹화 영역을 선택하세요.", "viewfinder", .accentColor)
        case .recording:
            ("녹화 중 · 최대 30초 · 메뉴 막대의 정지 버튼 또는 ⌘⌃Esc로 끝내세요.", "record.circle.fill", .red)
        case let .processing(message): (message, "arrow.triangle.2.circlepath", .accentColor)
        case let .success(message): (message, "checkmark.circle.fill", .green)
        case let .failure(message): (message, "exclamationmark.triangle.fill", .red)
        }
    }
}

struct ContentView: View {
    @State private var sourceURL: URL?
    @State private var status = ActivityStatus.idle("영역을 녹화하거나 MOV 파일을 선택하세요.")
    @State private var isWorking = false
    @State private var isSelecting = false
    @State private var isRecording = false
    @State private var isImporterPresented = false
    @State private var player: AVPlayer?
    @State private var duration = 0.0
    @State private var trimStart = 0.0
    @State private var trimEnd = 0.0
    @State private var outputURL: URL?
    @State private var sourceSize = CGSize.zero
    @State private var framesPerSecond = Int(GIFConverter.framesPerSecond)
    @State private var maximumDimension = Int(GIFConverter.defaultMaximumDimension)

    var body: some View {
        VStack(spacing: sourceURL == nil ? 24 : 10) {
            if let player {
                VideoPreview(player: player)
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 58))
                    .foregroundStyle(.secondary)

                Text("Video to GIF")
                    .font(.largeTitle.bold())
            }

            HStack(spacing: 6) {
                Image(systemName: status.presentation.symbolName)
                    .foregroundStyle(status.presentation.color)
                Text(status.presentation.message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            if duration > 0 {
                VStack(spacing: 4) {
                    trimSlider(
                        "시작",
                        value: Binding(
                            get: { trimStart },
                            set: { trimStart = min($0, trimEnd) }
                        )
                    )
                    trimSlider(
                        "끝",
                        value: Binding(
                            get: { trimEnd },
                            set: { trimEnd = max($0, trimStart) }
                        )
                    )
                    HStack(spacing: 8) {
                        Picker("FPS", selection: $framesPerSecond) {
                            ForEach([8, 12, 15, 24], id: \.self) { fps in
                                Text("\(fps) FPS").tag(fps)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)

                        Picker("출력 크기", selection: $maximumDimension) {
                            ForEach([480, 720, 960], id: \.self) { dimension in
                                Text("\(dimension) px").tag(dimension)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)

                        Spacer()
                        Text("예상 \(formatBytes(estimatedOutputBytes))")
                            .foregroundStyle(.secondary)
                            .help("장면 변화와 색상에 따라 실제 크기는 달라집니다.")
                    }
                    .controlSize(.small)
                }
                .disabled(isWorking || isSelecting || isRecording)
            }

            HStack(spacing: 12) {
                Button(
                    isRecording ? "녹화 중지" : "화면 영역 녹화",
                    systemImage: isRecording ? "stop.circle.fill" : "record.circle"
                ) {
                    if isRecording {
                        status = .processing("녹화를 마치는 중…")
                        ScreenRecorder.stop()
                    } else {
                        recordScreen()
                    }
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? .red : .accentColor)
                .disabled(isWorking || isSelecting)

                Button("MOV 파일 선택", systemImage: "movieclapper") {
                    isImporterPresented = true
                }
                .buttonStyle(.bordered)
                .disabled(isWorking || isSelecting || isRecording)

                Button("GIF로 저장", systemImage: "square.and.arrow.down") {
                    saveGIF()
                }
                .disabled(
                    sourceURL == nil || trimEnd <= trimStart || isWorking || isSelecting || isRecording
                )

                if let outputURL {
                    Button("Finder에서 보기", systemImage: "folder") {
                        SavedGIFActions.reveal(outputURL)
                    }
                    .labelStyle(.iconOnly)
                    .help("Finder에서 보기")
                }
            }

            if isWorking || isSelecting {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(sourceURL == nil ? 32 : 16)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            ScreenRecorder.install { recordScreen() }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.movie],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            loadSource(url)
        }
    }

    private func trimSlider(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 28, alignment: .leading)
            Slider(
                value: value,
                in: 0...duration,
                onEditingChanged: { editing in
                    guard !editing else { return }
                    player?.seek(
                        to: CMTime(seconds: value.wrappedValue, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                }
            )
            .accessibilityLabel(label)
            Text(formatTime(value.wrappedValue))
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    private var estimatedOutputBytes: Int64 {
        GIFConverter.estimatedFileSize(
            duration: trimEnd - trimStart,
            sourceSize: sourceSize,
            fps: Double(framesPerSecond),
            maximumDimension: CGFloat(maximumDimension)
        )
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func loadSource(_ url: URL) {
        player?.pause()
        sourceURL = url
        player = AVPlayer(url: url)
        duration = 0
        trimStart = 0
        trimEnd = 0
        outputURL = nil
        sourceSize = .zero
        status = .processing("영상 정보를 불러오는 중…")

        Task {
            do {
                let asset = AVURLAsset(url: url)
                let seconds = try await asset.load(.duration).seconds
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw ConversionError.invalidVideo
                }
                let naturalSize = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                guard sourceURL == url else { return }
                guard seconds.isFinite, seconds > 0 else { throw ConversionError.invalidVideo }
                duration = seconds
                trimEnd = seconds
                sourceSize = CGRect(origin: .zero, size: naturalSize)
                    .applying(transform)
                    .standardized
                    .size
                status = .ready(url.lastPathComponent)
            } catch {
                guard sourceURL == url else { return }
                sourceURL = nil
                player = nil
                status = .failure(error.localizedDescription)
            }
        }
    }

    private func recordScreen() {
        guard !isWorking, !isSelecting, !isRecording else { return }
        guard ScreenRecorder.requestPermission() else {
            status = .failure("화면 기록 권한이 필요합니다.")
            ScreenRecorder.showPermissionAlert()
            return
        }
        player?.pause()
        isSelecting = true
        status = .selecting
        let appWindow = NSApp.keyWindow ?? NSApp.windows.first {
            $0.canBecomeMain && !($0 is NSPanel)
        }

        Task {
            guard let region = await AreaSelector.select(on: appWindow?.screen) else {
                isSelecting = false
                status = .idle("녹화를 취소했습니다.")
                return
            }
            isSelecting = false
            isRecording = true
            status = .recording
            appWindow?.orderOut(nil)
            NSApp.hide(nil)
            defer {
                isRecording = false
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
                appWindow?.makeKeyAndOrderFront(nil)
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("video-to-gif-\(UUID().uuidString).mov")

            do {
                try await ScreenRecorder.record(to: url, region: region)
                loadSource(url)
            } catch is CancellationError {
                status = .idle("녹화를 취소했습니다.")
            } catch {
                status = .failure(error.localizedDescription)
            }
        }
    }

    private func saveGIF() {
        guard let sourceURL else { return }
        player?.pause()

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + ".gif"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        let range = CMTimeRange(
            start: CMTime(seconds: trimStart, preferredTimescale: 600),
            end: CMTime(seconds: trimEnd, preferredTimescale: 600)
        )
        let fps = Double(framesPerSecond)
        let maximumDimension = CGFloat(maximumDimension)
        isWorking = true
        status = .processing("GIF로 변환하는 중…")

        Task {
            do {
                let frameCount = try await GIFConverter.convert(
                    sourceURL,
                    to: outputURL,
                    timeRange: range,
                    fps: fps,
                    maximumDimension: maximumDimension
                )
                self.outputURL = outputURL
                let copied = SavedGIFActions.copy(outputURL)
                status = .success(
                    "저장 완료 · \(frameCount)프레임" + (copied ? " · 클립보드 복사됨" : "")
                )
            } catch {
                status = .failure(error.localizedDescription)
            }
            isWorking = false
        }
    }
}

@MainActor
enum SavedGIFActions {
    static func copy(_ url: URL, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }

        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
        item.setString(url.absoluteString, forType: .fileURL)
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct VideoPreview: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

@MainActor
enum ScreenRecorder {
    nonisolated static let maximumDurationSeconds = 30
    private static var stopInput: FileHandle?
    private static var statusItem: NSStatusItem?
    private static var menuTarget: RecordingMenuTarget?
    private static var startAction: (() -> Void)?

    static func install(startAction: @escaping () -> Void) {
        self.startAction = startAction
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let target = RecordingMenuTarget()
        item.button?.target = target
        item.button?.action = #selector(RecordingMenuTarget.toggle)
        statusItem = item
        menuTarget = target
        showStartButton()
    }

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
        // ponytail: screencapture's -V can miss its deadline on secondary displays.
        let timeout = Task {
            try? await Task.sleep(for: .seconds(maximumDurationSeconds))
            guard !Task.isCancelled else { return }
            stop()
        }

        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        timeout.cancel()
        showStartButton()
        try? stopInput?.close()
        stopInput = nil

        guard process.terminationStatus == 0 else {
            throw RecordingError.captureFailed(process.terminationStatus)
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw RecordingError.outputMissing
        }
    }

    nonisolated static func arguments(outputURL: URL, region: CGRect, mainScreenMaxY: CGFloat) -> [String] {
        let captureRect = CGRect(
            x: region.minX,
            y: mainScreenMaxY - region.maxY,
            width: region.width,
            height: region.height
        ).integral
        return [
            "-q", "/dev/null", "/usr/sbin/screencapture",
            "-v", "-V\(maximumDurationSeconds)",
            "-R\(Int(captureRect.minX)),\(Int(captureRect.minY)),\(Int(captureRect.width)),\(Int(captureRect.height))",
            outputURL.path,
        ]
    }

    nonisolated static func requestPermission(
        preflight: () -> Bool = { CGPreflightScreenCaptureAccess() },
        request: () -> Bool = { CGRequestScreenCaptureAccess() }
    ) -> Bool {
        preflight() || request()
    }

    static func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "화면 기록 권한이 필요합니다."
        alert.informativeText = "시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록에서 Video to GIF를 허용한 뒤 앱을 다시 여세요."
        alert.addButton(withTitle: "시스템 설정 열기")
        alert.addButton(withTitle: "확인")
        guard alert.runModal() == .alertFirstButtonReturn,
              let settingsURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.systempreferences"
              ) else { return }
        NSWorkspace.shared.open(settingsURL)
    }

    static func stop() {
        guard let input = stopInput else { return }
        stopInput = nil
        try? input.write(contentsOf: Data([0x78]))
        try? input.close()
        statusItem?.button?.isEnabled = false
    }

    static func toggle() {
        stopInput == nil ? startAction?() : stop()
    }

    private static func showStopButton() {
        statusItem?.button?.image = NSImage(
            systemSymbolName: "stop.circle.fill",
            accessibilityDescription: "녹화 중지"
        )
        statusItem?.button?.contentTintColor = .systemRed
        statusItem?.button?.toolTip = "녹화 중지 · 최대 \(maximumDurationSeconds)초"
        statusItem?.button?.isEnabled = true
    }

    private static func showStartButton() {
        statusItem?.button?.image = NSImage(
            systemSymbolName: "record.circle",
            accessibilityDescription: "화면 영역 녹화"
        )
        statusItem?.button?.contentTintColor = nil
        statusItem?.button?.toolTip = "화면 영역 녹화"
        statusItem?.button?.isEnabled = true
    }
}

enum RecordingError: LocalizedError {
    case captureFailed(Int32)
    case outputMissing

    var errorDescription: String? {
        switch self {
        case let .captureFailed(status): "화면 녹화에 실패했습니다. (종료 코드 \(status))"
        case .outputMissing: "녹화 파일이 생성되지 않았습니다."
        }
    }
}

@MainActor
private final class RecordingMenuTarget: NSObject {
    @objc func toggle() {
        ScreenRecorder.toggle()
    }
}

@MainActor
enum AreaSelector {
    private static var windows: [AreaSelectionPanel] = []

    static func select(on preferredScreen: NSScreen?) async -> CGRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)

        return await withCheckedContinuation { continuation in
            var didFinish = false
            let finish: (CGRect?) -> Void = { result in
                guard !didFinish else { return }
                didFinish = true
                windows.forEach { $0.close() }
                windows.removeAll()
                NSApp.setActivationPolicy(activationPolicy)
                continuation.resume(returning: result)
            }

            windows = screens.map { screen in
                let panel = AreaSelectionPanel(
                    contentRect: screen.frame,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                let view = AreaSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))

                panel.contentView = view
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.isFloatingPanel = true
                panel.level = .screenSaver
                panel.collectionBehavior = [
                    .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary,
                ]
                panel.hidesOnDeactivate = false
                panel.isReleasedWhenClosed = false
                view.onFinish = { [weak panel] rect in
                    finish(rect.flatMap { panel?.convertToScreen($0) })
                }
                return panel
            }

            let preferredPanel = preferredScreen.flatMap { preferred in
                windows.first { $0.frame == preferred.frame }
            } ?? windows.first
            windows.forEach { $0.orderFrontRegardless() }
            preferredPanel?.makeKey()
            preferredPanel?.makeFirstResponder(preferredPanel?.contentView)
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

        let instruction = NSString(
            string: "드래그: 영역 선택 · 더블 클릭 또는 Enter: 이 화면 전체 · Esc: 취소"
        )
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
        if event.clickCount == 2 {
            finish(bounds)
            return
        }
        guard selection.width >= 16, selection.height >= 16 else {
            startPoint = nil
            endPoint = nil
            needsDisplay = true
            return
        }
        finish(selection)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: finish(bounds)
        case 53: finish(nil)
        default: super.keyDown(with: event)
        }
    }

    private func finish(_ rect: CGRect?) {
        let completion = onFinish
        onFinish = nil
        completion?(rect)
    }
}

enum GIFConverter {
    static let framesPerSecond = 12.0
    static let defaultMaximumDimension: CGFloat = 960

    static func frameTimes(in range: CMTimeRange, fps: Double = framesPerSecond) -> [CMTime] {
        let start = range.start.seconds
        let duration = range.duration.seconds
        guard range.isValid, !range.isEmpty,
              start.isFinite, duration.isFinite, duration > 0,
              fps.isFinite, fps > 0 else { return [] }

        let rawCount = (duration * fps).rounded(.up)
        guard rawCount.isFinite, rawCount <= Double(Int.max) else { return [] }
        let count = max(1, Int(rawCount))
        return (0..<count).compactMap {
            let seconds = start + Double($0) / fps
            return seconds < start + duration
                ? CMTime(seconds: seconds, preferredTimescale: 600)
                : nil
        }
    }

    static func convert(
        _ sourceURL: URL,
        to outputURL: URL,
        timeRange: CMTimeRange? = nil,
        fps: Double = framesPerSecond,
        maximumDimension: CGFloat = defaultMaximumDimension
    ) async throws -> Int {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let assetRange = CMTimeRange(start: .zero, duration: duration)
        let range = CMTimeRangeGetIntersection(assetRange, otherRange: timeRange ?? assetRange)
        let times = frameTimes(in: range, fps: fps)
        guard !times.isEmpty else { throw ConversionError.invalidVideo }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumDimension, height: maximumDimension)
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
                kCGImagePropertyGIFDelayTime: 1 / fps,
                kCGImagePropertyGIFUnclampedDelayTime: 1 / fps,
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

    static func estimatedFileSize(
        duration: Double,
        sourceSize: CGSize,
        fps: Double,
        maximumDimension: CGFloat
    ) -> Int64 {
        guard duration.isFinite, duration > 0,
              sourceSize.width.isFinite, sourceSize.width > 0,
              sourceSize.height.isFinite, sourceSize.height > 0,
              fps.isFinite, fps > 0,
              maximumDimension.isFinite, maximumDimension > 0 else { return 0 }

        let scale = min(1, maximumDimension / max(sourceSize.width, sourceSize.height))
        let pixels = sourceSize.width * scale * sourceSize.height * scale
        let frames = (duration * fps).rounded(.up)
        // ponytail: motion and color count dominate GIF compression; use a sampled encode if precision matters.
        let estimate = (pixels * frames * 0.06).rounded(.up)
        return estimate >= Double(Int64.max) ? Int64.max : Int64(estimate)
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
