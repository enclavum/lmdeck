import SwiftUI
import AppKit

// The Logs tab: a terminal-style, non-wrapping, monospaced view of model + server events (load,
// unload, auto-evict, refuse; server start/stop/restart) — oldest first, newest at the bottom.
// Backed by EventLog (persisted across relaunches); shows the most recent 200 lines. It's an AppKit
// NSTextView (for selection/find + cheap large logs) configured to not wrap — long lines scroll
// horizontally. The console sits in the native pane shell (toolbar title + refresh action).
struct LogsSettingsPane: View {
    @EnvironmentObject private var log: EventLog
    @State private var refreshID = UUID()   // bump to re-sync the text view to the latest events

    // The most recent 200 events as log lines (oldest of those first, newest last — tail at bottom).
    private var text: String { log.events.suffix(200).map(\.line).joined(separator: "\n") }

    var body: some View {
        LogTextView(text: text, fg: .labelColor, bg: .textBackgroundColor)
            .id(refreshID)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .padding(20)
            .navigationTitle("Logs")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { refreshID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh")
                }
            }
            .onAppear { refreshID = UUID() }   // refresh the logs whenever the page is opened
    }
}

// AppKit monospaced text view (Courier New 14), read-only but selectable + find-enabled, with NO
// line wrapping (a horizontal scroller appears for long lines). Follows the tail when the user is
// already pinned to the bottom, like a console.
private struct LogTextView: NSViewRepresentable {
    let text: String
    let fg: NSColor
    let bg: NSColor

    private static let font = NSFont(name: "Courier New", size: 14)
        ?? .monospacedSystemFont(ofSize: 14, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.allowsUndo = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.drawsBackground = true
        tv.backgroundColor = bg
        tv.textColor = fg
        tv.font = Self.font
        tv.textContainerInset = NSSize(width: 12, height: 10)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false

        // No wrap: let the text view grow to its widest line; the scroll view scrolls horizontally.
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = []
        if let container = tv.textContainer {
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            container.lineFragmentPadding = 0
        }

        tv.string = text
        DispatchQueue.main.async { Self.scrollToBottomLeft(scroll) }   // start at the tail (left edge)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.backgroundColor = bg
        tv.textColor = fg
        if tv.string == text { return }

        // Follow the tail only when the user is already at (near) the bottom.
        let pinnedToBottom = scroll.contentView.documentRect.maxY
            - scroll.contentView.documentVisibleRect.maxY < 40
        tv.string = text
        tv.font = Self.font   // re-applied: replacing `string` can drop typing attributes
        if pinnedToBottom { DispatchQueue.main.async { Self.scrollToBottomLeft(scroll) } }
    }

    // Scroll to the tail but keep the horizontal position at the left edge. Plain
    // scrollToEndOfDocument jumps to the *end of the last line*, which scrolls all the way right when
    // that line is wider than the view (the bug on refresh).
    private static func scrollToBottomLeft(_ scroll: NSScrollView) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.scrollToEndOfDocument(nil)                 // vertical: jump to the bottom
        let cv = scroll.contentView                   // …then snap horizontal back to the left
        cv.scroll(to: NSPoint(x: 0, y: cv.bounds.origin.y))
        scroll.reflectScrolledClipView(cv)
    }
}

#if DEBUG
struct LogsSettingsPane_Previews: PreviewProvider {
    static var previews: some View {
        LogsSettingsPane()
            .environmentObject(EventLog.preview)
            .frame(width: 760, height: 520)
    }
}
#endif
