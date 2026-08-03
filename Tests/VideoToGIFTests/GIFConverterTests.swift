import CoreMedia
import Testing
@testable import VideoToGIF

@Test func frameSchedule() {
    let times = GIFConverter.frameTimes(duration: 1, fps: 4)
    #expect(times.map(\.seconds) == [0, 0.25, 0.5, 0.75])
    #expect(GIFConverter.frameTimes(duration: 0).isEmpty)
}
