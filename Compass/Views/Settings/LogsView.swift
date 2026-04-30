import SwiftUI
import UIKit

struct LogsView: View {
    @State private var filterLevel: LogStore.Entry.Level? = nil
    @State private var searchText = ""
    @State private var isFollowing = true
    @State private var showCopyAlert = false
    @State private var logStore = LogStore.shared

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var filteredEntries: [LogStore.Entry] {
        logStore.entries.filter { entry in
            if let level = filterLevel, entry.level != level { return false }
            if !searchText.isEmpty {
                let needle = searchText.lowercased()
                return entry.message.lowercased().contains(needle)
                    || entry.category.lowercased().contains(needle)
            }
            return true
        }
    }

    private var levelColors: [LogStore.Entry.Level: Color] {
        [
            .debug: .blue,
            .info: .green,
            .warning: .orange,
            .error: .red,
        ]
    }

    var body: some View {
        NavigationStack {
            contentBody
                .navigationTitle("Logs")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter by message or category")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        filterMenu
                    }

                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            isFollowing.toggle()
                        } label: {
                            Image(systemName: isFollowing ? "arrow.down.circle.fill" : "arrow.down.circle")
                        }
                        .help(isFollowing ? "Auto-scrolling to latest" : "Scroll to latest paused")

                        Button {
                            UIPasteboard.general.string = getLogsText()
                            showCopyAlert = true
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }

                        Button {
                            presentShareSheet()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                .alert("Copied", isPresented: $showCopyAlert) {
                    Button("OK") {}
                } message: {
                    Text("Logs copied to clipboard")
                }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if filteredEntries.isEmpty {
            ContentUnavailableView {
                Label(searchText.isEmpty ? "No Logs" : "No Matching Logs", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(searchText.isEmpty ? "Logs will appear here as the app runs." : "Try a different search term or filter.")
            }
        } else {
            logsList
        }
    }

    @ViewBuilder
    private var logsList: some View {
        ScrollViewReader { proxy in
            List(filteredEntries, id: \.id) { entry in
                logListRow(for: entry)
                    .id(entry.id)
            }
            .listStyle(.plain)
            .onChange(of: filteredEntries.count) { _, _ in
                if isFollowing, let last = filteredEntries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: isFollowing) { _, following in
                if following, let last = filteredEntries.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func logListRow(for entry: LogStore.Entry) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(levelColors[entry.level] ?? .gray)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Self.timeFormatter.string(from: entry.timestamp))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(entry.category)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(4)

                    Spacer()

                    Text(entry.level.displayName)
                        .font(.caption2)
                        .foregroundStyle(levelColors[entry.level] ?? .gray)
                }

                Text(entry.message)
                    .font(.caption)
                    .lineLimit(3)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 4)
    }

    private var filterMenu: some View {
        Menu {
            Button {
                filterLevel = nil
            } label: {
                HStack {
                    if filterLevel == nil {
                        Image(systemName: "checkmark")
                    }
                    Text("All")
                }
            }

            Divider()

            ForEach(LogStore.Entry.Level.allCases, id: \.self) { level in
                Button {
                    filterLevel = level
                } label: {
                    HStack {
                        if filterLevel == level {
                            Image(systemName: "checkmark")
                        }
                        Text(level.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
    }

    private func getLogsText() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return logStore.entries.map { entry in
            "[\(dateFormatter.string(from: entry.timestamp))] [\(entry.level.displayName)] [\(entry.category)] \(entry.message)"
        }.joined(separator: "\n")
    }

    private func presentShareSheet() {
        let text = getLogsText()
        let fileName = "compass-logs-\(Date().formatted(.dateTime.year().month().day())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.keyWindow else { return }
        // Walk to the topmost presented view controller so we don't double-present.
        var topVC = window.rootViewController
        while let presented = topVC?.presentedViewController {
            topVC = presented
        }
        // iPad needs a popover source rect; on iPhone this is ignored.
        vc.popoverPresentationController?.sourceView = window
        vc.popoverPresentationController?.sourceRect = CGRect(
            x: window.bounds.midX, y: window.safeAreaInsets.top, width: 0, height: 0
        )
        topVC?.present(vc, animated: true)
    }
}

#Preview {
    LogsView()
}
