import XCTest
@testable import DetachApp
@testable import DetachKit

@MainActor
final class SidebarGroupsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "SidebarGroupsTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testNamesAreTrimmedBoundedAndPrintable() {
        XCTAssertEqual(SidebarGroupsDocument.normalizedName("  Work \n"), "Work")
        XCTAssertNil(SidebarGroupsDocument.normalizedName(" \t\n"))
        XCTAssertNil(SidebarGroupsDocument.normalizedName("Wo\u{0007}rk"))
        XCTAssertEqual(
            SidebarGroupsDocument.normalizedName(String(repeating: "я", count: 80))?.count,
            SidebarGroupsDocument.maximumNameLength)
    }

    func testCreateRejectsEmptyDuplicateAndExcessGroups() throws {
        let store = SidebarGroupStore(defaults: defaults)

        let work = try store.createGroup(named: "Work").get()
        XCTAssertEqual(store.groups.map(\.name), ["Work"])
        XCTAssertEqual(store.groups.first?.id, work)
        XCTAssertEqual(store.createGroup(named: "  ").failure, .emptyName)
        XCTAssertEqual(store.createGroup(named: "work").failure, .duplicateName)

        for index in 1..<SidebarGroupsDocument.maximumGroups {
            _ = try store.createGroup(named: "Group \(index)").get()
        }
        XCTAssertEqual(store.createGroup(named: "One more").failure, .tooManyGroups)
    }

    func testRenameKeepsIdentityAndRejectsAnotherGroupsName() throws {
        let store = SidebarGroupStore(defaults: defaults)
        let work = try store.createGroup(named: "Work").get()
        _ = try store.createGroup(named: "Personal").get()

        XCTAssertNoThrow(try store.renameGroup(work, to: "WORK").get())
        XCTAssertEqual(store.groups.first, SidebarGroup(id: work, name: "WORK"))
        XCTAssertEqual(store.renameGroup(work, to: "personal").failure, .duplicateName)
        XCTAssertEqual(store.renameGroup(work, to: "").failure, .emptyName)
        XCTAssertEqual(store.renameGroup(UUID(), to: "Other").failure, .unknownGroup)
    }

    func testDeletingAGroupReturnsItsSessionsAndForgetsItsCollapseState() throws {
        let store = SidebarGroupStore(defaults: defaults)
        let work = try store.createGroup(named: "Work").get()
        let personal = try store.createGroup(named: "Personal").get()
        store.assign("a", to: work)
        store.assign("b", to: personal)
        store.setCollapsed(true, section: .active, groupID: work)
        store.setCollapsed(true, section: .finished, groupID: personal)

        store.deleteGroup(work)

        XCTAssertEqual(store.groups.map(\.id), [personal])
        XCTAssertNil(store.groupID(for: "a"))
        XCTAssertEqual(store.groupID(for: "b"), personal)
        XCTAssertFalse(store.isCollapsed(section: .active, groupID: work))
        XCTAssertTrue(store.isCollapsed(section: .finished, groupID: personal))
    }

    func testAssignMovesRemovesAndIgnoresUnknownGroups() throws {
        let store = SidebarGroupStore(defaults: defaults)
        let work = try store.createGroup(named: "Work").get()
        let personal = try store.createGroup(named: "Personal").get()

        store.assign("a", to: work)
        store.assign("a", to: personal)
        XCTAssertEqual(store.groupID(for: "a"), personal)
        store.assign("a", to: UUID())
        XCTAssertEqual(store.groupID(for: "a"), personal)
        store.assign("a", to: nil)
        XCTAssertNil(store.groupID(for: "a"))
    }

    func testCollapseIsPerSectionAndPersists() throws {
        let store = SidebarGroupStore(defaults: defaults)
        let work = try store.createGroup(named: "Work").get()
        store.assign("a", to: work)

        store.setCollapsed(true, section: .finished, groupID: work)

        XCTAssertTrue(store.isCollapsed(section: .finished, groupID: work))
        XCTAssertFalse(store.isCollapsed(section: .active, groupID: work))
        let reloaded = SidebarGroupStore(defaults: defaults)
        XCTAssertEqual(reloaded.document, store.document)
        XCTAssertTrue(reloaded.isCollapsed(section: .finished, groupID: work))
        XCTAssertEqual(reloaded.groupID(for: "a"), work)
    }

    func testRevealOpensOnlyTheGroupInTheSessionsSection() throws {
        let store = SidebarGroupStore(defaults: defaults)
        let work = try store.createGroup(named: "Work").get()
        let running = session(id: "a", status: "running")
        store.assign(running.id, to: work)
        store.setCollapsed(true, section: .active, groupID: work)
        store.setCollapsed(true, section: .finished, groupID: work)

        store.reveal(running)

        XCTAssertFalse(store.isCollapsed(section: .active, groupID: work))
        XCTAssertTrue(store.isCollapsed(section: .finished, groupID: work))
        store.reveal(session(id: "ungrouped", status: "running"))
        XCTAssertTrue(store.isCollapsed(section: .finished, groupID: work))
    }

    func testPruneKeepsOnlyListedSessions() throws {
        let store = SidebarGroupStore(defaults: defaults)
        let work = try store.createGroup(named: "Work").get()
        store.assign("kept", to: work)
        store.assign("deleted", to: work)

        store.pruneAssignments(keeping: ["kept", "other"])

        XCTAssertEqual(store.document.assignments, ["kept": work])
        XCTAssertEqual(store.groups.map(\.id), [work])
    }

    func testUnreadableDocumentsStartWithoutGroups() throws {
        XCTAssertEqual(SidebarGroupsDocument.decode(nil), SidebarGroupsDocument())
        XCTAssertEqual(
            SidebarGroupsDocument.decode(Data("not json".utf8)),
            SidebarGroupsDocument())
        var future = SidebarGroupsDocument()
        future.schema = 2
        future.groups = [SidebarGroup(id: UUID(), name: "Work")]
        XCTAssertEqual(
            SidebarGroupsDocument.decode(try JSONEncoder().encode(future)),
            SidebarGroupsDocument())
        XCTAssertEqual(
            SidebarGroupsDocument.decode(Data(count: SidebarGroupsDocument.maximumEncodedBytes + 1)),
            SidebarGroupsDocument())

        defaults.set(Data("{".utf8), forKey: SidebarGroupStore.storageKey)
        XCTAssertTrue(SidebarGroupStore(defaults: defaults).groups.isEmpty)
    }

    func testValidationDropsInvalidGroupsAndDanglingReferences() throws {
        let work = UUID()
        let missing = UUID()
        var document = SidebarGroupsDocument()
        document.groups = [
            SidebarGroup(id: work, name: " Work "),
            SidebarGroup(id: work, name: "Duplicate ID"),
            SidebarGroup(id: UUID(), name: "WORK"),
            SidebarGroup(id: UUID(), name: "   "),
        ]
        document.assignments = ["a": work, "b": missing]
        document.collapsed = [
            SidebarGroupsDocument.collapseKey(section: .active, groupID: work),
            SidebarGroupsDocument.collapseKey(section: .active, groupID: missing),
            "garbage",
        ]

        let decoded = SidebarGroupsDocument.decode(try JSONEncoder().encode(document))

        XCTAssertEqual(decoded.groups, [SidebarGroup(id: work, name: "Work")])
        XCTAssertEqual(decoded.assignments, ["a": work])
        XCTAssertEqual(decoded.collapsed, [
            SidebarGroupsDocument.collapseKey(section: .active, groupID: work),
        ])
    }

    func testLayoutKeepsStatusSectionsAndPutsGroupsFirstInUserOrder() {
        let work = SidebarGroup(id: UUID(), name: "Work")
        let personal = SidebarGroup(id: UUID(), name: "Personal")
        let empty = SidebarGroup(id: UUID(), name: "Empty")
        var document = SidebarGroupsDocument()
        document.groups = [personal, work, empty]
        document.assignments = [
            "work-running": work.id,
            "work-waiting": work.id,
            "personal-done": personal.id,
            "personal-running": personal.id,
        ]
        let sessions = [
            session(id: "loose-running", status: "running"),
            session(id: "work-running", status: "running"),
            session(id: "work-waiting", status: "running", turnState: "waiting"),
            session(id: "personal-running", status: "running"),
            session(id: "personal-done", status: "completed"),
            session(id: "loose-done", status: "completed"),
        ]

        let layout = SidebarSectionLayout.build(sessions: sessions, document: document)

        XCTAssertEqual(layout.map(\.section), [.answerReady, .active, .finished])
        XCTAssertEqual(layout[0].groupBlocks.map(\.group), [work])
        XCTAssertEqual(layout[0].groupBlocks[0].sessions.map(\.id), ["work-waiting"])
        XCTAssertTrue(layout[0].ungrouped.isEmpty)
        XCTAssertEqual(layout[1].groupBlocks.map(\.group), [personal, work])
        XCTAssertEqual(layout[1].groupBlocks.map { $0.sessions.map(\.id) }, [
            ["personal-running"], ["work-running"],
        ])
        XCTAssertEqual(layout[1].ungrouped.map(\.id), ["loose-running"])
        XCTAssertEqual(layout[1].count, 3)
        XCTAssertEqual(layout[2].groupBlocks.map(\.group), [personal])
        XCTAssertEqual(layout[2].ungrouped.map(\.id), ["loose-done"])
    }

    func testLayoutWithoutGroupsMatchesTheStatusSections() {
        let sessions = [
            session(id: "a", status: "running"),
            session(id: "b", status: "hung"),
        ]

        let layout = SidebarSectionLayout.build(
            sessions: sessions, document: SidebarGroupsDocument())

        XCTAssertEqual(layout.map(\.section), [.active, .problems])
        XCTAssertTrue(layout.allSatisfy(\.groupBlocks.isEmpty))
        XCTAssertEqual(layout.map { $0.ungrouped.map(\.id) }, [["a"], ["b"]])
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

private func session(
    id: String,
    status: String,
    turnState: String? = nil
) -> Session {
    let turnStateField = turnState.map {
        #","agent_turn_state":"\#($0)""#
    } ?? ""
    let json = #"{"schema":1,"provider":"codex","session_name":"\#(id)","name":"\#(id)","effective_status":"\#(status)","meta_status":null,"agent_session_id":"agent","project_dir":"/tmp/\#(id)","created_at":"2026-09-01T10:00:00Z","last_checkpoint_at":null,"exit_status":null,"finished_at":null\#(turnStateField)}"#
    return SessionListParser.parse(json).sessions[0]
}
