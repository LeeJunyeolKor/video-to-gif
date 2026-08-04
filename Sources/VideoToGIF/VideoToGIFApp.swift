@preconcurrency import AVFoundation
import AVKit
import Carbon
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct VideoToGIFApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 520, minHeight: 360)
        }
        .defaultSize(width: 720, height: 560)
        .windowResizability(.contentMinSize)
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
            ("녹화 중 · 메뉴 막대의 정지 버튼 또는 ⌃⌘G로 끝내세요.", "record.circle.fill", .red)
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
    @State private var lastRegion: CGRect?

    var body: some View {
        VStack(spacing: sourceURL == nil ? 24 : 10) {
            if let player {
                VideoPreview(player: player)
                    .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
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

            if duration > 0, let sourceURL {
                VStack(spacing: 4) {
                    TrimTimeline(
                        sourceURL: sourceURL,
                        duration: duration,
                        framesPerSecond: framesPerSecond,
                        start: $trimStart,
                        end: $trimEnd,
                        onSeek: seek
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
                .help("⌃⌘G: 최근 영역에서 바로 녹화")

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
            ScreenRecorder.install { recordScreen(reusingLastRegion: $0) }
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

    private func seek(to seconds: Double) {
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
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

    private func recordScreen(reusingLastRegion: Bool = false) {
        guard !isWorking, !isSelecting, !isRecording else { return }
        guard ScreenRecorder.requestPermission() else {
            status = .failure("화면 기록 권한이 필요합니다.")
            ScreenRecorder.showPermissionAlert()
            return
        }
        player?.pause()
        let appWindow = NSApp.keyWindow ?? NSApp.windows.first {
            $0.canBecomeMain && !($0 is NSPanel)
        }
        let reusableRegion = reusingLastRegion
            ? AreaSelector.reusableRegion(lastRegion, in: NSScreen.screens.map(\.frame))
            : nil
        isSelecting = true
        status = reusableRegion == nil
            ? .selecting
            : .processing("최근 영역에서 녹화를 시작하는 중…")

        Task {
            let region: CGRect
            if let reusableRegion {
                region = reusableRegion
            } else {
                guard let selectedRegion = await AreaSelector.select(on: appWindow?.screen) else {
                    isSelecting = false
                    status = .idle("녹화를 취소했습니다.")
                    return
                }
                region = selectedRegion
                lastRegion = selectedRegion
            }
            isSelecting = false
            isRecording = true
            status = .recording
            appWindow?.orderOut(nil)
            NSApp.deactivate()
            defer {
                isRecording = false
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

enum TrimRange {
    static func clampedStart(
        _ proposed: Double,
        end: Double,
        duration: Double,
        minimumDuration: Double
    ) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        let safeEnd = min(max(end, 0), duration)
        let minimumDuration = min(max(minimumDuration, 0), duration)
        let upperBound = max(0, safeEnd - minimumDuration)
        return min(max(proposed.isFinite ? proposed : 0, 0), upperBound)
    }

    static func clampedEnd(
        _ proposed: Double,
        start: Double,
        duration: Double,
        minimumDuration: Double
    ) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        let safeStart = min(max(start, 0), duration)
        let minimumDuration = min(max(minimumDuration, 0), duration)
        let lowerBound = min(duration, safeStart + minimumDuration)
        return max(min(proposed.isFinite ? proposed : duration, duration), lowerBound)
    }

    static func time(
        at position: CGFloat,
        width: CGFloat,
        duration: Double,
        inset: CGFloat
    ) -> Double {
        let usableWidth = width - inset * 2
        guard usableWidth.isFinite, usableWidth > 0,
              duration.isFinite, duration > 0 else { return 0 }
        let progress = min(max((position - inset) / usableWidth, 0), 1)
        return Double(progress) * duration
    }

    static func position(
        for time: Double,
        width: CGFloat,
        duration: Double,
        inset: CGFloat
    ) -> CGFloat {
        let usableWidth = width - inset * 2
        guard usableWidth.isFinite, usableWidth > 0,
              duration.isFinite, duration > 0 else { return inset }
        let progress = min(max(time / duration, 0), 1)
        return inset + CGFloat(progress) * usableWidth
    }
}

private struct TrimTimeline: View {
    private static let thumbnailCount = 12
    private static let trackHeight: CGFloat = 72
    private static let handleHeight: CGFloat = 84
    private static let handleHitWidth: CGFloat = 28

    let sourceURL: URL
    let duration: Double
    let framesPerSecond: Int
    @Binding var start: Double
    @Binding var end: Double
    let onSeek: (Double) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var thumbnails: [CGImage?] = []

    private var minimumDuration: Double {
        min(duration, 1 / Double(max(framesPerSecond, 1)))
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let inset = Self.handleHitWidth / 2
                let trackWidth = max(1, width - inset * 2)
                let startX = TrimRange.position(
                    for: start,
                    width: width,
                    duration: duration,
                    inset: inset
                )
                let endX = TrimRange.position(
                    for: end,
                    width: width,
                    duration: duration,
                    inset: inset
                )
                let centerY = Self.handleHeight / 2

                ZStack {
                    thumbnailStrip(width: trackWidth)
                        .frame(width: trackWidth, height: Self.trackHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .position(x: width / 2, y: centerY)

                    shade(width: max(0, startX - inset))
                        .position(x: inset + max(0, startX - inset) / 2, y: centerY)
                    shade(width: max(0, width - inset - endX))
                        .position(x: endX + max(0, width - inset - endX) / 2, y: centerY)

                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: max(1, endX - startX), height: Self.trackHeight)
                        .position(x: (startX + endX) / 2, y: centerY)
                        .allowsHitTesting(false)

                    trimHandle(isStart: true)
                        .position(x: startX, y: centerY)
                        .gesture(dragGesture(isStart: true, width: width, inset: inset))
                    trimHandle(isStart: false)
                        .position(x: endX, y: centerY)
                        .gesture(dragGesture(isStart: false, width: width, inset: inset))
                }
                .coordinateSpace(name: "trimTimeline")
            }
            .frame(height: Self.handleHeight)

            HStack {
                Text("시작 \(formatTime(start))")
                Spacer()
                Text("선택 \(formatTime(end - start))")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("끝 \(formatTime(end))")
            }
            .font(.caption)
            .monospacedDigit()
        }
        .task(id: sourceURL) {
            await loadThumbnails()
        }
    }

    private func thumbnailStrip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<Self.thumbnailCount, id: \.self) { index in
                thumbnail(at: index)
                    .frame(
                        width: width / CGFloat(Self.thumbnailCount),
                        height: Self.trackHeight
                    )
                    .clipped()
            }
        }
    }

    @ViewBuilder
    private func thumbnail(at index: Int) -> some View {
        if thumbnails.indices.contains(index), let thumbnail = thumbnails[index] {
            Image(decorative: thumbnail, scale: 1)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.12))
        }
    }

    private func shade(width: CGFloat) -> some View {
        Rectangle()
            .fill(.black.opacity(0.55))
            .frame(width: width, height: Self.trackHeight)
            .allowsHitTesting(false)
    }

    private func trimHandle(isStart: Bool) -> some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor)
                .frame(width: 16, height: Self.handleHeight)
            HStack(spacing: 3) {
                Capsule().fill(.white.opacity(0.85)).frame(width: 1, height: 18)
                Capsule().fill(.white.opacity(0.85)).frame(width: 1, height: 18)
            }
        }
        .frame(width: Self.handleHitWidth, height: Self.handleHeight)
        .contentShape(Rectangle())
        .accessibilityRepresentation {
            Slider(
                value: Binding(
                    get: { isStart ? start : end },
                    set: {
                        isStart
                            ? updateStart($0, shouldSeek: true)
                            : updateEnd($0, shouldSeek: true)
                    }
                ),
                in: 0...duration
            ) {
                Text(isStart ? "시작 핸들" : "끝 핸들")
            }
            .accessibilityLabel(isStart ? "시작 핸들" : "끝 핸들")
            .accessibilityValue(formatTime(isStart ? start : end))
        }
    }

    private func dragGesture(isStart: Bool, width: CGFloat, inset: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("trimTimeline"))
            .onChanged { value in
                guard isEnabled else { return }
                let time = TrimRange.time(
                    at: value.location.x,
                    width: width,
                    duration: duration,
                    inset: inset
                )
                isStart
                    ? updateStart(time, shouldSeek: false)
                    : updateEnd(time, shouldSeek: false)
            }
            .onEnded { value in
                guard isEnabled else { return }
                let time = TrimRange.time(
                    at: value.location.x,
                    width: width,
                    duration: duration,
                    inset: inset
                )
                isStart
                    ? updateStart(time, shouldSeek: true)
                    : updateEnd(time, shouldSeek: true)
            }
    }

    private func updateStart(_ proposed: Double, shouldSeek: Bool) {
        let adjusted = TrimRange.clampedStart(
            proposed,
            end: end,
            duration: duration,
            minimumDuration: minimumDuration
        )
        start = adjusted
        if shouldSeek { onSeek(adjusted) }
    }

    private func updateEnd(_ proposed: Double, shouldSeek: Bool) {
        let adjusted = TrimRange.clampedEnd(
            proposed,
            start: start,
            duration: duration,
            minimumDuration: minimumDuration
        )
        end = adjusted
        if shouldSeek { onSeek(max(start, adjusted - minimumDuration)) }
    }

    @MainActor
    private func loadThumbnails() async {
        thumbnails = [CGImage?](repeating: nil, count: Self.thumbnailCount)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: sourceURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)

        for index in 0..<Self.thumbnailCount {
            guard !Task.isCancelled else { return }
            let seconds = duration * (Double(index) + 0.5) / Double(Self.thumbnailCount)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            thumbnails[index] = try? await generator.image(at: time).image
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        String(
            format: "%d:%04.1f",
            Int(seconds) / 60,
            seconds.truncatingRemainder(dividingBy: 60)
        )
    }
}

@MainActor
enum ScreenRecorder {
    private static var stopInput: FileHandle?
    private static var stopTask: Task<Void, Never>?
    private static var statusItem: NSStatusItem?
    private static var quitMenuItem: NSMenuItem?
    private static var menuTarget: RecordingMenuTarget?
    private static var startAction: ((Bool) -> Void)?
    private static var hotKey: EventHotKeyRef?
    private static var hotKeyHandler: EventHandlerRef?

    static func install(startAction: @escaping (Bool) -> Void) {
        self.startAction = startAction
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let target = RecordingMenuTarget()
        item.button?.target = target
        item.button?.action = #selector(RecordingMenuTarget.toggle)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let quitItem = NSMenuItem(
            title: "앱 종료",
            action: #selector(RecordingMenuTarget.quit),
            keyEquivalent: ""
        )
        quitItem.target = target
        menu.addItem(quitItem)
        item.button?.menu = menu
        statusItem = item
        quitMenuItem = quitItem
        menuTarget = target
        installShortcut()
        showStartButton()
    }

    static func record(to outputURL: URL, region: CGRect) async throws {
        guard let mainScreen = NSScreen.screens.first else { throw CancellationError() }
        reinstallShortcut()

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
        stopTask?.cancel()
        stopTask = nil
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
            "-v",
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
        guard stopTask == nil, let input = stopInput else { return }
        statusItem?.button?.isEnabled = false
        stopTask = Task {
            await sendStopSignals(to: input)
        }
    }

    static func sendStopSignals(to input: FileHandle) async {
        while !Task.isCancelled {
            do {
                try input.write(contentsOf: Data([0x78]))
            } catch {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    static func toggle() {
        stopInput == nil ? startAction?(false) : stop()
    }

    static func handleShortcut() {
        stopInput == nil ? startAction?(true) : stop()
    }

    static func reinstallShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        hotKey = nil
        hotKeyHandler = nil
        installShortcut()
    }

    private static func installShortcut() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let target = GetApplicationEventTarget()
        guard InstallEventHandler(
            target,
            recordingHotKeyHandler,
            1,
            &eventType,
            nil,
            &hotKeyHandler
        ) == noErr else { return }

        let identifier = EventHotKeyID(signature: recordingHotKeySignature, id: 1)
        guard RegisterEventHotKey(
            UInt32(kVK_ANSI_G),
            UInt32(cmdKey | controlKey),
            identifier,
            target,
            OptionBits(kEventHotKeyExclusive),
            &hotKey
        ) == noErr else {
            if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
            hotKeyHandler = nil
            return
        }
    }

    private static func showStopButton() {
        statusItem?.button?.image = NSImage(
            systemSymbolName: "stop.circle.fill",
            accessibilityDescription: "녹화 중지"
        )
        statusItem?.button?.contentTintColor = .systemRed
        statusItem?.button?.toolTip = "클릭: 녹화 중지"
        statusItem?.button?.isEnabled = true
        quitMenuItem?.isEnabled = false
    }

    private static func showStartButton() {
        statusItem?.button?.image = NSImage(
            systemSymbolName: "record.circle",
            accessibilityDescription: "화면 영역 녹화"
        )
        statusItem?.button?.contentTintColor = nil
        statusItem?.button?.toolTip = "클릭: 화면 영역 녹화 · 우클릭: 앱 종료 · ⌃⌘G 최근 영역"
        statusItem?.button?.isEnabled = true
        quitMenuItem?.isEnabled = true
    }
}

private let recordingHotKeySignature: OSType = 0x56544746
private let recordingHotKeyHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    guard GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    ) == noErr,
    identifier.signature == recordingHotKeySignature,
    identifier.id == 1 else { return OSStatus(eventNotHandledErr) }

    Task { @MainActor in ScreenRecorder.handleShortcut() }
    return noErr
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

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

@MainActor
enum AreaSelector {
    private static var windows: [AreaSelectionPanel] = []

    nonisolated static func reusableRegion(_ region: CGRect?, in screenFrames: [CGRect]) -> CGRect? {
        guard let region,
              region.width >= 16,
              region.height >= 16,
              screenFrames.contains(where: { $0.contains(region) }) else { return nil }
        return region
    }

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
                // Refresh after AppKit finishes the activation policy transition.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    ScreenRecorder.reinstallShortcut()
                }
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
