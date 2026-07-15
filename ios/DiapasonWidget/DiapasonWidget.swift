// Diapason — home-screen widget (WidgetKit).

import AppIntents
import ImageIO
import SwiftUI
import UIKit
import WidgetKit

private func downsampledImage(path: String, maxPixel: CGFloat) -> UIImage? {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return UIImage(cgImage: cgImage)
}

private let appGroup = "group.fr.nytuo.diapason"

private let widgetControlDarwinPrefix = "fr.nytuo.diapason.widget."

extension Color {
    init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

private func hexLuminance(_ hex: String) -> Double? {
    let trimmed = hex.trimmingCharacters(in: .whitespaces)
    guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else { return nil }
    let r = Double((value >> 16) & 0xFF) / 255
    let g = Double((value >> 8) & 0xFF) / 255
    let b = Double(value & 0xFF) / 255
    return 0.299 * r + 0.587 * g + 0.114 * b
}

/// Interactive control invoked by the widget's playback buttons (iOS 17+).
@available(iOS 17, *)
struct WidgetControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Diapason Playback Control"

    @Parameter(title: "Command")
    var command: String

    init() {}
    init(command: String) { self.command = command }

    func perform() async throws -> some IntentResult {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("\(widgetControlDarwinPrefix)\(command)" as CFString),
            nil, nil, true
        )
        return .result()
    }
}

struct DiapasonEntry: TimelineEntry {
    let date: Date
    let title: String
    let artist: String
    let playing: Bool
    let cover: UIImage?
    let bgColor: Color?
    let accentColor: Color?
    let foreground: Color
    let secondaryForeground: Color
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> DiapasonEntry {
        entry()
    }

    func getSnapshot(in context: Context, completion: @escaping (DiapasonEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DiapasonEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func entry() -> DiapasonEntry {
        let defaults = UserDefaults(suiteName: appGroup)

        var cover: UIImage?
        if let path = defaults?.string(forKey: "cover"), !path.isEmpty {
            cover = downsampledImage(path: path, maxPixel: 600)
        }

        let bgHex = defaults?.string(forKey: "bgColor") ?? ""
        let bgColor = Color(hex: bgHex)
        let accentColor = Color(hex: defaults?.string(forKey: "accentColor") ?? "")

        let foreground: Color
        let secondaryForeground: Color
        if cover != nil {
            foreground = .white
            secondaryForeground = .white.opacity(0.75)
        } else if bgColor != nil {
            let isDark = (hexLuminance(bgHex) ?? 0) < 0.5
            foreground = isDark ? .white : .black
            secondaryForeground = (isDark ? Color.white : Color.black).opacity(0.7)
        } else {
            foreground = .primary
            secondaryForeground = .secondary
        }

        return DiapasonEntry(
            date: Date(),
            title: defaults?.string(forKey: "title") ?? "",
            artist: defaults?.string(forKey: "artist") ?? "",
            playing: defaults?.bool(forKey: "playing") ?? false,
            cover: cover,
            bgColor: bgColor,
            accentColor: accentColor,
            foreground: foreground,
            secondaryForeground: secondaryForeground
        )
    }
}

private struct Backdrop: View {
    let entry: DiapasonEntry

    var body: some View {
        if let cover = entry.cover {
            Image(uiImage: cover)
                .resizable()
                .scaledToFill()
                .blur(radius: 24, opaque: true)
                .overlay(
                    LinearGradient(
                        colors: [.black.opacity(0.25), .black.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipped()
        } else if let bg = entry.bgColor {
            LinearGradient(
                colors: [(entry.accentColor ?? bg).opacity(0.65), bg],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Rectangle().fill(.background)
        }
    }
}

private struct CoverArt: View {
    let image: UIImage?
    let placeholderColor: Color

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    placeholderColor.opacity(0.2)
                    Image(systemName: "music.note")
                        .font(.system(size: 22))
                        .foregroundStyle(placeholderColor)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TrackText: View {
    let entry: DiapasonEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: entry.playing ? "play.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(entry.playing ? "Now playing" : "Paused")
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
            }
            .foregroundStyle(entry.secondaryForeground)
            Text(entry.title.isEmpty ? "Diapason" : entry.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(entry.foreground)
                .lineLimit(2)
            if !entry.artist.isEmpty {
                Text(entry.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(entry.secondaryForeground)
                    .lineLimit(1)
            }
        }
    }
}

@available(iOS 17, *)
private struct ControlsRow: View {
    let playing: Bool
    let spacing: CGFloat
    let tint: Color

    var body: some View {
        HStack(spacing: spacing) {
            Button(intent: WidgetControlIntent(command: "previous")) {
                Image(systemName: "backward.fill")
            }
            Button(intent: WidgetControlIntent(command: "playpause")) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .frame(width: 22)
            }
            Button(intent: WidgetControlIntent(command: "next")) {
                Image(systemName: "forward.fill")
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .buttonStyle(.plain)
        .tint(tint)
        .foregroundStyle(tint)
    }
}

struct DiapasonWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: DiapasonEntry

    @ViewBuilder
    private var controls: some View {
        if #available(iOS 17, *) {
            ControlsRow(
                playing: entry.playing,
                spacing: family == .systemSmall ? 20 : 18,
                tint: entry.foreground
            )
        }
    }

    var body: some View {
        Group {
            if family == .systemSmall {
                VStack(alignment: .leading, spacing: 8) {
                    CoverArt(image: entry.cover, placeholderColor: entry.secondaryForeground)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                    TrackText(entry: entry)
                    Spacer(minLength: 0)
                    controls
                        .frame(maxWidth: .infinity)
                }
            } else {
                HStack(spacing: 12) {
                    CoverArt(image: entry.cover, placeholderColor: entry.secondaryForeground)
                        .aspectRatio(1, contentMode: .fit)
                    VStack(alignment: .leading, spacing: 10) {
                        TrackText(entry: entry)
                        controls
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(12)
        .widgetBackground { Backdrop(entry: entry) }
    }
}

extension View {
    @ViewBuilder
    func widgetBackground<Background: View>(@ViewBuilder _ background: () -> Background) -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(for: .widget) { background() }
        } else {
            self.background(background())
        }
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
