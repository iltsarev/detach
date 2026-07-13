import XCTest
@testable import DetachKit

final class TerminalCommandTests: XCTestCase {
    let detach = "/Users/me/.local/bin/detach"

    func session(_ status: EffectiveStatus = .running, uuid: String? = "1111-2222") -> Session {
        SessionListParser.parse("""
        {"schema":1,"provider":"codex","session_name":"codex-detached-proj-abcd1234","name":"proj-abcd1234","effective_status":"\(status.rawValue)","meta_status":null,"agent_session_id":\(uuid.map { "\"\($0)\"" } ?? "null"),"project_dir":"/tmp/p","created_at":null,"last_checkpoint_at":null,"exit_status":null,"finished_at":null}
        """).sessions[0]
    }

    func testQuotingEscapesSingleQuotes() {
        XCTAssertEqual(shellQuoted("it's; rm -rf *"), "'it'\\''s; rm -rf *'")
    }

    func testAttach() {
        XCTAssertEqual(
            TerminalCommand.attach(detachPath: detach, session: session()),
            "exec '/Users/me/.local/bin/detach' codex attach 'codex-detached-proj-abcd1234'")
    }

    func testResumeNeedsUUID() {
        XCTAssertEqual(
            TerminalCommand.resume(detachPath: detach, session: session(.stopped)),
            "exec '/Users/me/.local/bin/detach' resume '1111-2222'")
        XCTAssertNil(TerminalCommand.resume(detachPath: detach, session: session(.stopped, uuid: nil)))
    }

    func testRecover() {
        XCTAssertEqual(
            TerminalCommand.recover(detachPath: detach, session: session(.recoverable)),
            "exec '/Users/me/.local/bin/detach' codex recover 'codex-detached-proj-abcd1234'")
    }

    func testStartComposesAllParts() {
        XCTAssertEqual(
            TerminalCommand.start(detachPath: detach, provider: .claude,
                                  projectDir: "/Users/me/dev/it's", name: "migration",
                                  prompt: "fix \"all\" tests"),
            "cd '/Users/me/dev/it'\\''s' && exec '/Users/me/.local/bin/detach' claude --name 'migration' -- 'fix \"all\" tests'")
    }

    func testStartOmitsEmptyParts() {
        XCTAssertEqual(
            TerminalCommand.start(detachPath: detach, provider: .codex,
                                  projectDir: "/tmp/p", name: nil, prompt: nil),
            "cd '/tmp/p' && exec '/Users/me/.local/bin/detach' codex")
    }
}
