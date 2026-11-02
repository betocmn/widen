import AppKit
import SwiftUI
import Testing

@testable import WidenKit

@Suite("Main window layout", .serialized)
@MainActor
struct MainViewLayoutTests {
    @Test func resizingAndTogglingInspectorKeepsSplitViewsInsideTheWindow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-layout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(
            connectionStore: ConnectionStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            schemaStore: SchemaStore(directory: directory)
        )
        await state.onLaunch()

        let hostingView = NSHostingView(rootView: MainView().environment(state))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderBack(nil)
        defer { window.close() }

        // Exercise the widths that triggered an AppKit constraint-update
        // crash, then hide the inspector to fit the narrower editor layout.
        let layouts: [(CGFloat, Bool)] = [
            (1600, true), (1280, true), (1120, true), (1020, true),
            (900, false), (700, false), (1280, true), (1600, true),
        ]
        for (width, showInspector) in layouts {
            if !showInspector { state.showSchemaInspector = false }
            window.setContentSize(NSSize(width: width, height: 700))
            if showInspector { state.showSchemaInspector = true }
            // Let SwiftUI's presentation and AppKit's constraint passes settle.
            try await Task.sleep(for: .milliseconds(150))
            hostingView.layoutSubtreeIfNeeded()

            let splitViews = visibleSplitViews(in: hostingView)
            #expect(!splitViews.isEmpty)
            for splitView in splitViews {
                let frame = splitView.convert(splitView.bounds, to: hostingView)
                #expect(frame.minX >= -1)
                #expect(frame.maxX <= hostingView.bounds.width + 1)
            }
            #expect(state.showSchemaInspector == showInspector)
        }
    }

    private func visibleSplitViews(in view: NSView) -> [NSSplitView] {
        guard !view.isHidden else { return [] }
        let current = (view as? NSSplitView).map { [$0] } ?? []
        return current + view.subviews.flatMap { visibleSplitViews(in: $0) }
    }
}
