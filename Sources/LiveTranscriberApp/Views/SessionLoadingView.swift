import SwiftUI

/// Detail pane while a stored session's transcript is being read.
///
/// Reading one is quick (a few ms for Markdown, tens for YAML), so the point
/// is not to entertain during a wait — it is to stop the pane from announcing
/// "No Session" for a frame on the way to showing one. The title comes from
/// the sidebar row, which is already loaded, so only the body fills in late.
struct SessionLoadingView: View {
  let summary: SessionSummary?

  /// Held back so the usual sub-frame load does not flash a spinner; a
  /// genuinely slow read still explains itself.
  @State private var showsSpinner = false

  var body: some View {
    // Scroll-backed like the transcript and the empty state, so AppKit keeps
    // auto-hiding the toolbar separator instead of blinking it in on every
    // selection.
    GeometryReader { proxy in
      ScrollView {
        ProgressView()
          .controlSize(.small)
          .opacity(showsSpinner ? 1 : 0)
          .animation(.easeIn(duration: 0.15), value: showsSpinner)
          .frame(width: proxy.size.width, height: proxy.size.height)
      }
    }
    .navigationTitle(summary?.name ?? "")
    .navigationSubtitle(subtitle)
    .task(id: summary?.url) {
      showsSpinner = false
      try? await Task.sleep(for: .milliseconds(250))
      showsSpinner = true
    }
  }

  private var subtitle: String {
    guard let summary else { return "" }
    return summary.startedAt.formatted(.dateTime.month().day().hour().minute())
  }
}
