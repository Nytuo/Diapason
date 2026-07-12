// Diapason — home-screen widget (WidgetKit).

import SwiftUI
import WidgetKit

private let appGroup = "group.fr.nytuo.diapason"

struct DiapasonEntry: TimelineEntry {
    let date: Date
    let title: String
    let artist: String
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> DiapasonEntry {
        DiapasonEntry(date: Date(), title: "Diapason", artist: "")
    }

    func getSnapshot(in context: Context, completion: @escaping (DiapasonEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DiapasonEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func entry() -> DiapasonEntry {
        let defaults = UserDefaults(suiteName: appGroup)
        return DiapasonEntry(
            date: Date(),
            title: defaults?.string(forKey: "title") ?? "",
            artist: defaults?.string(forKey: "artist") ?? ""
        )
    }
}

struct DiapasonWidgetEntryView: View {
    var entry: DiapasonEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title.isEmpty ? "Diapason" : entry.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            if !entry.artist.isEmpty {
                Text(entry.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(12)
    }
}

@main
struct DiapasonWidget: Widget {
    let kind = "DiapasonWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            DiapasonWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Diapason")
        .description("What's playing.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
