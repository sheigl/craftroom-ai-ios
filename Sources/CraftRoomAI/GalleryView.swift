import SwiftUI
import UIKit
import CraftRoomCore

/// Gallery (plan T4.10): every page in `Documents/renders/`, tap for the
/// before/after slider, share and delete. Old pages without a source sidecar
/// still open — the slider is hidden, nothing is migrated.
struct GalleryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var items: [RenderItem] = []

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No pages yet",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Generate a page and it appears here."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(items) { item in
                                NavigationLink {
                                    GalleryDetailView(item: item) { reload() }
                                } label: {
                                    cell(item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { reload() }
        }
        .tint(Theme.accent)
    }

    private func cell(_ item: RenderItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemGroupedBackground))
                if let image = item.pageImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func reload() {
        items = RenderStore.list()
    }
}

/// One saved page: slider when the source sidecar exists, share, delete.
struct GalleryDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let item: RenderItem
    let onDelete: () -> Void

    @State private var fraction: CGFloat = 0.5
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let source = item.sourceImage, let page = item.pageImage {
                    BeforeAfterSlider(before: source, after: page,
                                      fraction: $fraction)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if let page = item.pageImage {
                    Image(uiImage: page)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("No source photo for this page — generated before v0.6, "
                         + "so there is nothing to compare it with.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(item.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    ShareLink(item: item.pageURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Page")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this page?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.delete(item)
                onDelete()
                dismiss()
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The PNG and its source photo are removed from this iPad.")
        }
    }
}
