import XCTest
@testable import Cado

/// `AppActivityFeed` through what flows report and what observers receive.
final class AppActivityFeedTests: XCTestCase {
    private var feed: AppActivityFeed!
    private var received: [AppActivityFeed.Signal] = []

    override func setUp() {
        super.setUp()
        feed = AppActivityFeed()
        received = []
        feed.observe { [unowned self] in received.append($0) }
    }

    func testStartsIdleAndQuiet() {
        XCTAssertEqual(feed.activity, .idle)
        XCTAssertTrue(received.isEmpty, "Observing replays nothing; read `activity` for the current value")
    }

    func testDictationPhasesMapToActivity() {
        let expected: [(DictationSession.Phase, AppActivity)] = [
            (.recording, .dictating), (.transcribing, .transcribing),
            (.delivering, .transcribing), (.idle, .idle),
        ]
        for (phase, activity) in expected {
            feed.dictationPhaseChanged(phase)
            XCTAssertEqual(feed.activity, activity, "\(phase)")
        }
    }

    func testPublishesOnlyChanges() {
        feed.dictationPhaseChanged(.recording)
        feed.dictationPhaseChanged(.recording)
        feed.dictationPhaseChanged(.transcribing)
        feed.dictationPhaseChanged(.delivering)   // still transcribing to the app
        feed.dictationPhaseChanged(.idle)
        feed.dictationPhaseChanged(.idle)

        XCTAssertEqual(received, [.activity(.dictating), .activity(.transcribing), .activity(.idle)])
    }

    func testLevelAndTextLandedPassThrough() {
        feed.dictationPhaseChanged(.recording)
        feed.dictationLevel(0.4)
        feed.dictationLevel(0.4)   // levels are a stream, not a state: no dedupe
        feed.dictationTextLanded()

        XCTAssertEqual(received, [.activity(.dictating), .level(0.4), .level(0.4), .textLanded])
    }

    func testEveryObserverGetsEverySignalInOrder() {
        var second: [AppActivityFeed.Signal] = []
        feed.observe { second.append($0) }
        feed.dictationPhaseChanged(.recording)
        feed.dictationTextLanded()

        XCTAssertEqual(received, [.activity(.dictating), .textLanded])
        XCTAssertEqual(second, received)
    }

    func testActivityIsCurrentWhenObserversHear() {
        var seen: AppActivity?
        feed.observe { [unowned self] _ in seen = feed.activity }
        feed.dictationPhaseChanged(.recording)
        XCTAssertEqual(seen, .dictating)
    }
}
