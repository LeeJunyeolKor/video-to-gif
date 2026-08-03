import AppKit
import CoreMedia
import Foundation
import Testing
@testable import VideoToGIF

@Test func frameSchedule() {
    let times = GIFConverter.frameTimes(duration: 1, fps: 4)
    #expect(times.map(\.seconds) == [0, 0.25, 0.5, 0.75])
    #expect(GIFConverter.frameTimes(duration: 0).isEmpty)
}

@Test func captureRegionArguments() {
    let arguments = ScreenRecorder.arguments(
        outputURL: URL(fileURLWithPath: "/tmp/capture.mov"),
        region: CGRect(x: 10, y: 80, width: 320, height: 200),
        mainScreenMaxY: 900
    )
    #expect(arguments == [
        "-q", "/dev/null", "/usr/sbin/screencapture",
        "-v", "-R10,620,320,200", "/tmp/capture.mov",
    ])
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
