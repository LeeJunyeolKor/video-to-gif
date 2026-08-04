import AppKit
import CoreMedia
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import VideoToGIF

@Test func frameSchedule() {
    let fullRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))
    let times = GIFConverter.frameTimes(in: fullRange, fps: 4)
    #expect(times.map(\.seconds) == [0, 0.25, 0.5, 0.75])

    let trimmedRange = CMTimeRange(
        start: CMTime(seconds: 0.25, preferredTimescale: 600),
        duration: CMTime(seconds: 0.5, preferredTimescale: 600)
    )
    #expect(GIFConverter.frameTimes(in: trimmedRange, fps: 4).map(\.seconds) == [0.25, 0.5])
    #expect(GIFConverter.frameTimes(in: .zero).isEmpty)
}

@Test func estimatedGIFSizeUsesDurationFPSAndOutputSize() {
    let base = GIFConverter.estimatedFileSize(
        duration: 2,
        sourceSize: CGSize(width: 1920, height: 1080),
        fps: 12,
        maximumDimension: 960
    )
    let moreFrames = GIFConverter.estimatedFileSize(
        duration: 4,
        sourceSize: CGSize(width: 1920, height: 1080),
        fps: 12,
        maximumDimension: 960
    )
    let smaller = GIFConverter.estimatedFileSize(
        duration: 2,
        sourceSize: CGSize(width: 1920, height: 1080),
        fps: 12,
        maximumDimension: 480
    )

    #expect(base > 0)
    #expect(moreFrames == base * 2)
    #expect(smaller == base / 4)
    #expect(GIFConverter.estimatedFileSize(
        duration: 0,
        sourceSize: CGSize(width: 1920, height: 1080),
        fps: 12,
        maximumDimension: 960
    ) == 0)
}

@Test func activityStatusPresentation() {
    #expect(ActivityStatus.idle("준비").presentation.symbolName == "circle.dashed")
    #expect(ActivityStatus.ready("video.mov").presentation.symbolName == "movieclapper")
    #expect(ActivityStatus.selecting.presentation.symbolName == "viewfinder")
    #expect(ActivityStatus.recording.presentation.symbolName == "record.circle.fill")
    #expect(ActivityStatus.processing("처리 중").presentation.symbolName == "arrow.triangle.2.circlepath")
    #expect(ActivityStatus.success("완료").presentation.symbolName == "checkmark.circle.fill")
    #expect(ActivityStatus.failure("실패").presentation.symbolName == "exclamationmark.triangle.fill")
    #expect(ActivityStatus.success("완료").presentation.message == "완료")
}

@Test func captureRegionArguments() {
    let arguments = ScreenRecorder.arguments(
        outputURL: URL(fileURLWithPath: "/tmp/capture.mov"),
        region: CGRect(x: 10, y: 80, width: 320, height: 200),
        mainScreenMaxY: 900
    )
    #expect(arguments == [
        "-q", "/dev/null", "/usr/sbin/screencapture",
        "-v", "-V30", "-R10,620,320,200", "/tmp/capture.mov",
    ])

    let secondaryDisplayArguments = ScreenRecorder.arguments(
        outputURL: URL(fileURLWithPath: "/tmp/capture.mov"),
        region: CGRect(x: -100.5, y: 950.25, width: 320.25, height: 200.25),
        mainScreenMaxY: 900
    )
    #expect(secondaryDisplayArguments.contains("-R-101,-251,321,201"))
}

@Test func screenRecordingPermissionRequest() {
    var requested = false
    #expect(ScreenRecorder.requestPermission(preflight: { true }, request: {
        requested = true
        return false
    }))
    #expect(!requested)

    #expect(ScreenRecorder.requestPermission(preflight: { false }, request: { true }))
    #expect(!ScreenRecorder.requestPermission(preflight: { false }, request: { false }))
}

@Test @MainActor func dragSelectsRecordingArea() {
    let view = AreaSelectionView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
    var selected: CGRect?
    view.onFinish = { selected = $0 }

    func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 20, y: 30)))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 220, y: 130)))
    view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 220, y: 130)))

    #expect(selected == CGRect(x: 20, y: 30, width: 200, height: 100))
}

@Test @MainActor func copiesSavedGIF() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("video-to-gif-pasteboard-\(UUID().uuidString).gif")
    let data = Data("GIF89a".utf8)
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let pasteboard = NSPasteboard.withUniqueName()
    #expect(SavedGIFActions.copy(url, to: pasteboard))
    #expect(pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.gif.identifier)) == data)
    #expect(pasteboard.string(forType: .fileURL) == url.absoluteString)
}
