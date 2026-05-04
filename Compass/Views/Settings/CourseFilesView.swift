import SwiftUI

struct CourseFilesView: View {
    @State private var files: [CourseFileStore.StoredFile] = []
    @State private var showShareSheet = false
    @State private var shareItems: [URL] = []
    @State private var selectedFiles: Set<UUID> = []
    @State private var isSelectionMode = false

    private let fileStore = CourseFileStore.shared

    var body: some View {
        NavigationStack {
            contentBody
                .navigationTitle("Course Files")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if !files.isEmpty {
                            if isSelectionMode {
                                Button("Done") {
                                    isSelectionMode = false
                                    selectedFiles.removeAll()
                                }
                                
                                if !selectedFiles.isEmpty {
                                    Button("Share Selected") {
                                        shareSelectedFiles()
                                    }
                                }
                            } else {
                                Button {
                                    isSelectionMode = true
                                } label: {
                                    Label("Select", systemImage: "checklist")
                                }
                                
                                Button {
                                    shareAllFiles()
                                } label: {
                                    Label("Export All", systemImage: "arrow.up.doc")
                                }
                            }
                        }
                    }
                }
                .sheet(isPresented: $showShareSheet) {
                    ActivityView(items: shareItems)
                }
                .onAppear {
                    refreshFiles()
                }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if files.isEmpty {
            ContentUnavailableView {
                Label("No Files", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            } description: {
                Text("FIT course files uploaded to the watch will appear here.")
            }
        } else {
            filesList
        }
    }

    @ViewBuilder
    private var filesList: some View {
        List(files, id: \.id) { file in
            fileListRow(for: file)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelectionMode {
                        if selectedFiles.contains(file.id) {
                            selectedFiles.remove(file.id)
                        } else {
                            selectedFiles.insert(file.id)
                        }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if !isSelectionMode {
                        ShareLink(item: file.url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .tint(.blue)

                        Button(role: .destructive) {
                            deleteFile(file)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
        }
        .listStyle(.plain)
    }

    private func fileListRow(for file: CourseFileStore.StoredFile) -> some View {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short

        return HStack(spacing: 12) {
            if isSelectionMode {
                Image(systemName: selectedFiles.contains(file.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedFiles.contains(file.id) ? .green : .secondary)
                    .font(.title3)
            }
            
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Text(formatFileSize(file.size))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(dateFormatter.string(from: file.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func shareSelectedFiles() {
        let selectedUrls = files.filter { selectedFiles.contains($0.id) }.map { $0.url }
        if selectedUrls.isEmpty { return }
        
        FileArchive.shareMultipleFiles(selectedUrls, archiveName: "course-files") { urlsToShare in
            shareItems = urlsToShare
            showShareSheet = true
        }
    }
    
    private func shareAllFiles() {
        let allUrls = files.map { $0.url }
        FileArchive.shareMultipleFiles(allUrls, archiveName: "course-files-all") { urlsToShare in
            shareItems = urlsToShare
            showShareSheet = true
        }
    }
    
    private func refreshFiles() {
        files = fileStore.allFiles()
    }

    private func deleteFile(_ file: CourseFileStore.StoredFile) {
        try? fileStore.delete(file)
        refreshFiles()
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useBytes]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    CourseFilesView()
}
