import SwiftUI

struct MainWindow: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    NavigationSplitView {
      SessionListView()
        .navigationSplitViewColumnWidth(min: 180, ideal: 230)
    } detail: {
      Group {
        if let session = model.displayedSession {
          TranscriptView(session: session)
        } else {
          ContentUnavailableView(
            "No Session",
            systemImage: "waveform",
            description: Text("Start recording to see the live transcript here.")
          )
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 0) {
          if let message = model.recording.lastError {
            Banner(message: message, icon: "exclamationmark.triangle.fill", tint: .yellow) {
              model.recording.lastError = nil
            }
          }
          if let message = model.recording.infoMessage {
            Banner(message: message, icon: "info.circle.fill", tint: .blue) {
              model.recording.infoMessage = nil
            }
          }
        }
      }
    }
    .toolbar { RecordingToolbar() }
    .sheet(isPresented: $model.showingNewSessionSheet) {
      NewSessionSheet()
    }
    .frame(minWidth: 640, minHeight: 400)
  }
}

private struct Banner: View {
  let message: String
  let icon: String
  let tint: Color
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: icon)
        .foregroundStyle(tint)
      Text(message)
        .lineLimit(2)
        .textSelection(.enabled)
      Spacer()
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(tint.opacity(0.15))
    .background(.bar)
  }
}
