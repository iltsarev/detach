import XCTest
@testable import DetachKit

final class SessionAttachTests: XCTestCase {
    func testInitialSizeAcceptsOnlyBoundedPositiveDimensions() {
        XCTAssertEqual(SessionTerminalSize(columns: 152, rows: 43)?.arguments,
                       ["--terminal-size", "152x43"])
        XCTAssertNotNil(SessionTerminalSize(columns: 1, rows: 999))
        XCTAssertNil(SessionTerminalSize(columns: 0, rows: 43))
        XCTAssertNil(SessionTerminalSize(columns: 152, rows: -1))
        XCTAssertNil(SessionTerminalSize(columns: 1000, rows: 43))
        XCTAssertNil(SessionTerminalSize(columns: 152, rows: 1000))
    }

    func testPublicAttachUsesArgvAndNeverCallsTmux() {
        let invocation = SessionAttachInvocation(
            detachPath: "/Users/me/.local/bin/detach",
            session: session(),
            baseEnvironment: [
                "PATH": "/bin",
                "HOME": "/Users/me",
                "TMUX": "/tmp/foreign.sock,123,0",
                "TMUX_PANE": "%9",
            ])

        XCTAssertEqual(invocation.executable, "/Users/me/.local/bin/detach")
        XCTAssertEqual(
            invocation.arguments,
            [
                "codex", "attach", "--terminal-features", "sync",
                "detach-codex-proj-abcd1234",
            ])
        XCTAssertFalse(invocation.arguments.contains { $0.contains("tmux") })
        XCTAssertFalse(invocation.environment.contains { $0.hasPrefix("TMUX=") })
        XCTAssertFalse(invocation.environment.contains { $0.hasPrefix("TMUX_PANE=") })
        XCTAssertTrue(invocation.environment.contains("TERM=xterm-256color"))
        XCTAssertEqual(SessionAttachInvocation.termName, "xterm-256color")
        XCTAssertTrue(
            invocation.environment.contains {
                $0.hasPrefix("PATH=") && $0.contains("/Users/me/.local/bin")
            })
    }

    func testAttachEnvironmentPreservesLocaleAndAcceptsAnExplicitTerminal() {
        let environment = SessionAttachInvocation.environment(
            from: ["LANG": "ru_RU.UTF-8"],
            termName: "vt100")

        XCTAssertTrue(environment.contains("LANG=ru_RU.UTF-8"))
        XCTAssertTrue(environment.contains("TERM=vt100"))
        XCTAssertFalse(environment.contains("LANG=en_US.UTF-8"))
    }

    func testClaudeAttachKeepsTheProviderAndInternalName() {
        XCTAssertEqual(
            SessionAttachInvocation.arguments(for: session(
                provider: .claude,
                name: "detach-claude-review")),
            [
                "claude", "attach", "--terminal-features", "sync",
                "detach-claude-review",
            ])
    }

    func testAttachClientAlwaysUsesUTF8DespiteInheritedCLocale() {
        for base in [
            ["LANG": "C"],
            ["LANG": "ru_RU.UTF-8", "LC_ALL": "C"],
            ["LANG": "ru_RU.UTF-8", "LC_CTYPE": "C", "LC_ALL": ""],
        ] {
            XCTAssertTrue(SessionAttachInvocation.environment(from: base)
                .contains("LC_ALL=en_US.UTF-8"))
        }
        for base in [
            ["LANG": "C", "LC_ALL": "ru_RU.UTF-8"],
            ["LANG": "C", "LC_CTYPE": "en_US.utf8"],
        ] {
            let environment = SessionAttachInvocation.environment(from: base)
            for (key, value) in base {
                XCTAssertTrue(environment.contains("\(key)=\(value)"))
            }
        }
    }

    func testClientSwitchBindsExactPIDSourceAndTargetProvider() {
        XCTAssertEqual(
            SessionClientSwitchInvocation.arguments(
                clientPID: 4242,
                from: session(),
                to: session(
                    provider: .claude,
                    name: "detach-claude-review")),
            [
                "client", "switch",
                "--pid", "4242",
                "--from", "detach-codex-proj-abcd1234",
                "--to", "detach-claude-review",
                "--provider", "claude",
            ])
    }

    func testOnlyLiveAttachableSessionsAreEligible() {
        XCTAssertTrue(SessionAttachInvocation.isEligible(session(status: .running)))
        XCTAssertTrue(SessionAttachInvocation.isEligible(session(status: .starting)))
        XCTAssertTrue(SessionAttachInvocation.isEligible(session(status: .hung)))
        XCTAssertFalse(SessionAttachInvocation.isEligible(session(status: .stopped)))
        XCTAssertFalse(SessionAttachInvocation.isEligible(session(status: .recoverable)))
        XCTAssertFalse(SessionAttachInvocation.isEligible(session(status: .collision)))
        XCTAssertTrue(
            SessionAttachInvocation.shouldEmbed(session(status: .running), clientActive: true))
        XCTAssertFalse(
            SessionAttachInvocation.shouldEmbed(session(status: .running), clientActive: false))
        XCTAssertFalse(
            SessionAttachInvocation.shouldEmbed(session(status: .stopped), clientActive: true))
    }

    func testResumeCanShowOnlyANewAttachableGenerationBeforeCompletion() {
        var previous = session(status: .stopped)
        previous.lifecycleID = "previous-run"
        var starting = session(status: .starting)
        starting.lifecycleID = "replacement-run"
        XCTAssertTrue(SessionAttachInvocation.shouldEmbed(
            starting, clientActive: true, replacing: previous))
        XCTAssertFalse(SessionAttachInvocation.shouldEmbed(
            starting, clientActive: false, replacing: previous),
            "An exited early client must not restart while Resume is pending")
        starting.lifecycleID = previous.lifecycleID
        XCTAssertFalse(SessionAttachInvocation.shouldEmbed(
            starting, clientActive: true, replacing: previous))
        starting.lifecycleID = "replacement-run"
        starting.sessionName = "detach-codex-other"
        XCTAssertFalse(SessionAttachInvocation.shouldEmbed(
            starting, clientActive: true, replacing: previous))
        starting = previous
        starting.lifecycleID = "replacement-run"
        XCTAssertFalse(SessionAttachInvocation.shouldEmbed(
            starting, clientActive: true, replacing: previous))
    }

    func testResumeLegacyGenerationRequiresALaterCreationTime() {
        var previous = session(status: .stopped)
        var starting = session(status: .starting)
        XCTAssertFalse(SessionAttachInvocation.shouldEmbed(
            starting, clientActive: true, replacing: previous))
        previous.createdAt = Date(timeIntervalSince1970: 100)
        for value in [99.0, 100.0, 101.0] {
            starting.createdAt = Date(timeIntervalSince1970: value)
            XCTAssertEqual(SessionAttachInvocation.shouldEmbed(
                starting, clientActive: true, replacing: previous), value > 100)
        }
    }

    private func session(
        status: EffectiveStatus = .running,
        provider: Provider = .codex,
        name: String = "detach-codex-proj-abcd1234"
    ) -> Session {
        SessionListParser.parse("""
        {"schema":1,"provider":"\(provider.rawValue)","session_name":"\(name)","name":"proj","effective_status":"\(status.rawValue)","meta_status":null,"agent_session_id":"1111-2222","project_dir":"/tmp/p","created_at":null,"last_checkpoint_at":null,"exit_status":null,"finished_at":null}
        """).sessions[0]
    }
}
