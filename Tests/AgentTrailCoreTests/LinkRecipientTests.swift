import XCTest
@testable import AgentTrailCore

final class LinkRecipientTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_793_500_000)

    private func instance(_ pid: Int32, after seconds: TimeInterval?) -> LinkRecipient.Instance {
        LinkRecipient.Instance(pid: pid, launchDate: seconds.map { start.addingTimeInterval($0) })
    }

    /// The real layout on 2026-11-05: Second (4120) started six seconds before Main
    /// (4269), and every link went to Second, even with Main in front.
    func testInstanceLaunchedFirstReceivesLinks() {
        XCTAssertEqual(LinkRecipient.pid(among: [instance(4120, after: 0), instance(4269, after: 6)]), 4120)
        XCTAssertEqual(LinkRecipient.pid(among: [instance(4269, after: 6), instance(4120, after: 0)]), 4120)
    }

    /// Launch order decides, not pid order.
    func testLaunchOrderWinsOverPidOrder() {
        XCTAssertEqual(LinkRecipient.pid(among: [instance(900, after: 30), instance(70_000, after: 1), instance(500, after: 12)]),
                       70_000)
    }

    func testSoleInstanceReceivesLinks() {
        XCTAssertEqual(LinkRecipient.pid(among: [instance(4269, after: 6)]), 4269)
    }

    func testUnknownOrderNamesNoInstance() {
        XCTAssertNil(LinkRecipient.pid(among: []))
        XCTAssertNil(LinkRecipient.pid(among: [instance(4120, after: 0), instance(4269, after: nil)]))
        XCTAssertNil(LinkRecipient.pid(among: [instance(4269, after: nil)]))
        XCTAssertNil(LinkRecipient.pid(among: [instance(4120, after: 3), instance(4269, after: 3)]))
    }

    /// A tie for a later place does not hide the instance launched first.
    func testLaterTieStillNamesEarliest() {
        XCTAssertEqual(LinkRecipient.pid(among: [instance(10, after: 5), instance(11, after: 5), instance(12, after: 1)]), 12)
        XCTAssertEqual(LinkRecipient.pid(among: [instance(12, after: 1), instance(10, after: 5), instance(11, after: 5)]), 12)
    }

    /// The layout on 2026-11-22: Main (1587) opened first, Second (17438) later.
    func testRouteOpensWithBundleOnlyForInstanceLaunchedFirst() {
        let instances = [instance(17_438, after: 1_103), instance(1_587, after: 0)]
        XCTAssertEqual(LinkRecipient.route(to: 1_587, among: instances), .bundle)
        XCTAssertEqual(LinkRecipient.route(to: 17_438, among: instances), .process)
    }

    /// One instance gets every link, even when its launch date is unknown.
    func testRouteToSoleInstanceUsesBundle() {
        XCTAssertEqual(LinkRecipient.route(to: 4269, among: [instance(4269, after: 6)]), .bundle)
        XCTAssertEqual(LinkRecipient.route(to: 4269, among: [instance(4269, after: nil)]), .bundle)
    }

    /// With the order unknown, or an instance not in the list, the link goes to the process.
    func testRouteWithUnknownOrderUsesProcess() {
        XCTAssertEqual(LinkRecipient.route(to: 4120, among: [instance(4120, after: 0), instance(4269, after: nil)]), .process)
        XCTAssertEqual(LinkRecipient.route(to: 4120, among: [instance(4120, after: 3), instance(4269, after: 3)]), .process)
        XCTAssertEqual(LinkRecipient.route(to: 99, among: [instance(4120, after: 0)]), .process)
        XCTAssertEqual(LinkRecipient.route(to: 99, among: []), .process)
    }

    /// Without direct links, only the instance launched first gets a link; the
    /// other gets none (Jump shows a hint). With them, the other gets it at its process.
    func testDeliveryFollowsDirectLinkSetting() {
        let instances = [instance(17_438, after: 1_103), instance(1_587, after: 0)]
        XCTAssertEqual(LinkRecipient.delivery(to: 1_587, among: instances, sendsToProcess: false), .bundle)
        XCTAssertEqual(LinkRecipient.delivery(to: 1_587, among: instances, sendsToProcess: true), .bundle)
        XCTAssertNil(LinkRecipient.delivery(to: 17_438, among: instances, sendsToProcess: false))
        XCTAssertEqual(LinkRecipient.delivery(to: 17_438, among: instances, sendsToProcess: true), .process)
    }
}
