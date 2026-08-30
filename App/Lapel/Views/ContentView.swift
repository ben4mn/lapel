import LapelKit
import SwiftUI

struct ContentView: View {
    @Environment(RecorderModel.self) private var recorder
    @State private var selection: StoredSession.ID?

    var body: some View {
        NavigationSplitView {
            SessionSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let selection, let session = recorder.sessions.first(where: { $0.id == selection }) {
                SessionDetailView(session: session)
            } else {
                RecorderView()
            }
        }
        // A recording that finishes while an old session is open should bring the
        // user back to the live pane rather than leaving them on stale detail.
        .onChange(of: recorder.isRecording) { _, isRecording in
            if isRecording { selection = nil }
        }
    }
}

private struct SessionSidebar: View {
    @Environment(RecorderModel.self) private var recorder
    @Binding var selection: StoredSession.ID?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Record", systemImage: "record.circle")
                    .foregroundStyle(selection == nil ? Color.accentColor : .primary)
                    .contentShape(.rect)
                    .onTapGesture { selection = nil }
            }

            Section("Recordings") {
                if recorder.sessions.isEmpty {
                    Text("Nothing recorded yet")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                ForEach(recorder.sessions) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.directory]) }
                            Divider()
                            Button("Delete", role: .destructive) {
                                if selection == session.id { selection = nil }
                                recorder.deleteSession(session)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct SessionRow: View {
    let session: StoredSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.title).lineLimit(1)
            HStack(spacing: 6) {
                Text(session.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                Text("·")
                Text(Transcript.timecode(session.duration))
                if session.metadata.tracks.count > 1 {
                    Text("·")
                    Label("\(session.metadata.tracks.count)", systemImage: "person.2.fill")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
