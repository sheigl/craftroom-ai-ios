import SwiftUI
import UIKit
import CraftRoomCore

/// The result screen (plan T4.9): before/after slider against the source photo,
/// share the PNG, regenerate, back.
///
/// There is no "save to Photos" step because the app never had one — pages are
/// saved to `Documents/renders/` (visible in the Files app) and shared from
/// there, so this keeps a single, already-working export path.
struct ResultView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let output: GenerationOutput

    @State private var fraction: CGFloat = 0.5

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let source = output.source, let page = output.pageImage {
                        BeforeAfterSlider(before: source, after: page,
                                          fraction: $fraction)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else if let page = output.pageImage {
                        Image(uiImage: page)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    metadata

                    HStack(spacing: 10) {
                        if let item = output.item {
                            ShareLink(item: item.pageURL) {
                                Label("Share", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button {
                            model.regenerate()
                            dismiss()
                        } label: {
                            Label("Regenerate",
                                  systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.photo == nil)
                    }
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Your page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let item = output.item {
                Text("Saved as \(item.pageURL.lastPathComponent)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headline: String {
        let engine = EngineID(rawValue: output.page.metadata.engine)?.label
            ?? output.page.metadata.engine
        return "\(engine) · \(output.page.width) × \(output.page.height) · "
            + String(format: "%.1f s", output.page.elapsed)
    }

    private var detail: String {
        var parts: [String] = []
        if let model = output.page.metadata.model { parts.append(model) }
        if let steps = output.page.metadata.steps { parts.append("\(steps) steps") }
        if let cfg = output.page.metadata.cfg {
            parts.append(String(format: "CFG %.1f", cfg))
        }
        if let seed = output.page.metadata.seed { parts.append("seed \(seed)") }
        return parts.joined(separator: " · ")
    }
}

/// Source photo on the left, generated page on the right, with a draggable
/// divider. Both images are the same aspect (the server crops to the source's
/// aspect, the device decodes to the content rect), so they stay aligned.
struct BeforeAfterSlider: View {
    let before: UIImage
    let after: UIImage
    @Binding var fraction: CGFloat

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let height = max(geo.size.height, 1)
            ZStack(alignment: .topLeading) {
                Color(.secondarySystemBackground)

                Image(uiImage: after)
                    .resizable()
                    .scaledToFit()
                    .frame(width: width, height: height)

                Image(uiImage: before)
                    .resizable()
                    .scaledToFit()
                    .frame(width: width, height: height)
                    .clipShape(LeftPortion(fraction: fraction))

                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 3, height: height)
                    .offset(x: width * clampedFraction - 1.5)

                Circle()
                    .fill(Theme.accent)
                    .frame(width: 26, height: 26)
                    .overlay {
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .offset(x: width * clampedFraction - 13,
                            y: height / 2 - 13)

                VStack {
                    Spacer()
                    HStack {
                        Text("Source")
                        Spacer()
                        Text("Page")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.45))
                }
                .frame(width: width, height: height)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        fraction = min(1, max(0, value.location.x / width))
                    }
            )
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
    }

    private var clampedFraction: CGFloat {
        min(1, max(0, fraction))
    }

    private var aspectRatio: CGFloat {
        let size = after.size
        guard size.width > 0, size.height > 0 else { return 1 }
        return size.width / size.height
    }
}

/// Everything left of `fraction` of the rect — the source photo's visible part.
private struct LeftPortion: Shape {
    var fraction: CGFloat

    func path(in rect: CGRect) -> Path {
        let width = rect.width * min(1, max(0, fraction))
        return Path(CGRect(x: rect.minX, y: rect.minY,
                           width: width, height: rect.height))
    }
}
