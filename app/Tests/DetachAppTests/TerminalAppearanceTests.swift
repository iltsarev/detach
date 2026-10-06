import AppKit
import XCTest
import SwiftTerm
import DetachKit
@testable import DetachApp

@MainActor
final class TerminalAppearanceTests: XCTestCase {
    func testStoredChoiceKeepsDarkDefaultAndIsIndependentOfAppChoice() throws {
        let name = "TerminalAppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(TerminalAppearance(storedValue: nil), .dark)
        XCTAssertEqual(TerminalAppearance(storedValue: "invalid"), .dark)
        defaults.set("dark", forKey: AppAppearance.storageKey)
        for choice in TerminalAppearance.allCases {
            defaults.set(choice.rawValue, forKey: TerminalAppearance.storageKey)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: name))
            XCTAssertEqual(TerminalAppearance(storedValue:
                reopened.string(forKey: TerminalAppearance.storageKey)), choice)
            XCTAssertEqual(reopened.string(forKey: AppAppearance.storageKey), "dark")
        }
    }

    func testAutoTracksSystemChangesUnderAnOppositeAppOverride() {
        let app = NSApplication.shared
        let original = app.appearance
        defer { app.appearance = original }
        var style: String?
        let system = SystemTerminalAppearance(readStyle: { style })
        AppAppearance.dark.apply(to: app)
        XCTAssertEqual(TerminalAppearance.system.palette(system: system.palette), .light)
        style = "Dark"
        AppAppearance.light.apply(to: app)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: app)
        XCTAssertEqual(TerminalAppearance.system.palette(system: system.palette), .dark)
        XCTAssertEqual(TerminalAppearance.light.palette(system: system.palette), .light)
        style = nil
        system.refresh()
        XCTAssertEqual(TerminalAppearance.system.palette(system: system.palette), .light)
        XCTAssertEqual(TerminalAppearance.dark.palette(system: system.palette), .dark)
        XCTAssertEqual(app.appearance?.name, .aqua)
    }

    func testLiveAndRetainedScreensRecolorWithoutLosingContent() throws {
        let terminal = SessionAttachLocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        let session = try JSONDecoder().decode(Session.self, from: Data("""
            {"schema":1,"provider":"codex","session_name":"terminal-theme","name":"theme","effective_status":"running","meta_status":null,"agent_session_id":null,"project_dir":"/tmp/p","created_at":null,"last_checkpoint_at":null,"exit_status":null,"finished_at":null}
            """.utf8))
        let controller = SessionAttachController(invocation: SessionAttachInvocation(
            detachPath: "/usr/bin/false", session: session, baseEnvironment: [:]))
        controller.configure(terminal, fontPointSize: 13)
        terminal.feed(text: "existing output\r\n\u{1B}[31mred text")
        terminal.retainScreen(Data("cached output".utf8), fontPointSize: 13)
        let overlay = try XCTUnwrap(terminal.subviews.compactMap { $0 as? RetainedTerminalScreenView }.first)
        let cached = try XCTUnwrap(overlay.subviews.compactMap { $0 as? TerminalView }.first)
        let liveContent = terminal.terminal.getBufferAsData()
        let cachedContent = cached.terminal.getBufferAsData()
        let process = terminal.process
        for palette in [TerminalPalette.light, .dark] {
            controller.applyPalette(palette)
            XCTAssertTrue(terminal.process === process)
            XCTAssertEqual(terminal.terminal.getBufferAsData(), liveContent)
            XCTAssertEqual(cached.terminal.getBufferAsData(), cachedContent)
            for view in [terminal, cached] {
                XCTAssertEqual(view.nativeBackgroundColor, palette.background)
                XCTAssertEqual(view.nativeForegroundColor, palette.foreground)
                XCTAssertEqual(view.caretColor, palette.foreground)
                XCTAssertEqual(view.selectedTextBackgroundColor, palette.selection)
                XCTAssertEqual(view.effectiveAppearance.name, palette.appearance.name)
            }
        }
        // An unrelated SwiftUI update must not overwrite a provider color.
        terminal.nativeForegroundColor = .orange
        controller.applyPalette(.dark)
        XCTAssertEqual(terminal.nativeForegroundColor, .orange)
        terminal.removeRetainedScreen()
    }

    func testCachedLogRecolorsDefaultReverseDimAndIndexedColorsPreservingRGBAndScroll() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let raw = "A\u{1B}[7mB\u{1B}[0;2mC\u{1B}[0;31mD\u{1B}[38;5;4mE"
            + "\u{1B}[38;2;12;34;56mF\u{1B}[0m\n"
            + (1...100).map { "line \($0)" }.joined(separator: "\n")
        let text = ANSIParser.parse(raw, font: font, boldFont: font,
            defaultColor: TerminalPalette.adaptiveForeground,
            defaultBackground: TerminalPalette.adaptiveBackground,
            ansiColors: TerminalPalette.adaptiveANSIColors)
        let scroll = LogTextView.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        let coordinator = LogTextView.Coordinator()
        let view = try XCTUnwrap(scroll.documentView as? NSTextView)
        for palette in [TerminalPalette.dark, .light, .dark] {
            LogTextView.apply(text: text, pointSize: 13, palette: palette,
                to: scroll, coordinator: coordinator)
            scroll.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.backgroundColor, palette.background)
            XCTAssertEqual(view.string, text.string)
            XCTAssertTrue(coordinator.lastText === text)
            let storage = try XCTUnwrap(view.textStorage)
            func color(_ offset: Int, _ key: NSAttributedString.Key = .foregroundColor) -> NSColor? {
                (storage.attribute(key, at: offset, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
            }
            XCTAssertEqual(color(0), palette.foreground.usingColorSpace(.sRGB))
            XCTAssertEqual(color(1), palette.background.usingColorSpace(.sRGB))
            XCTAssertEqual(color(1, .backgroundColor), palette.foreground.usingColorSpace(.sRGB))
            XCTAssertEqual(try XCTUnwrap(color(2)).alphaComponent, 0.55, accuracy: 0.001)
            XCTAssertEqual(color(2)?.withAlphaComponent(1), palette.foreground.usingColorSpace(.sRGB))
            XCTAssertEqual(color(3), palette.ansiColors[1])
            XCTAssertEqual(color(4), palette.ansiColors[4])
            XCTAssertEqual(color(5), NSColor(srgbRed: 12.0 / 255, green: 34.0 / 255,
                blue: 56.0 / 255, alpha: 1))
            if palette == .light {
                XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
            }
            scroll.contentView.scroll(to: .zero)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        }
    }
}
