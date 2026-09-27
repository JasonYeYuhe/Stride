import SwiftUI

struct ShareStreakView: View {
    let habit: Habit
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    /// Rendered once, in `.task`. It was a computed property read twice in `body` — the
    /// ShareLink item and its preview — so every render of this sheet ran ImageRenderer twice
    /// over the whole card, at 2x.
    @State private var renderedImage: Image?

    private var currentStreak: Int { habit.currentStreak() }
    private var bestStreak: Int { habit.bestStreak() }
    private var completionRate: Int { Int(habit.completionRate() * 100) }
    private var last14Days: [Date] { Date.lastNDays(14) }

    // SharePreview reads this aloud and the receiving app keeps it, so it has to be translated.
    // One key per unit, matching the Siri shortcut, rather than splicing in English streakUnit.
    private var shareText: String {
        habit.streakUnit == "week"
            ? appLocalized("\(habit.emoji) \(habit.name): \(currentStreak) week streak")
            : appLocalized("\(habit.emoji) \(habit.name): \(currentStreak) day streak")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                streakCard
                    .padding(.horizontal)

                Group {
                    if let renderedImage {
                        ShareLink(
                            item: renderedImage,
                            preview: SharePreview(shareText, image: renderedImage)
                        ) {
                            shareButtonLabel
                        }
                    } else {
                        // The first frame, before .task has rendered the image: same size and
                        // place, so the button does not jump when it becomes live.
                        shareButtonLabel
                            .opacity(0.5)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .background(Color.appBackground)
            .navigationTitle("Share Streak")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                renderedImage = renderImage()
            }
        }
    }

    private var shareButtonLabel: some View {
        Label("Share Streak", systemImage: "square.and.arrow.up")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(habit.color)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Streak Card

    private var streakCard: some View {
        VStack(spacing: 20) {
            // Emoji + name
            VStack(spacing: 6) {
                Text(habit.emoji)
                    .font(.system(size: 52))
                Text(habit.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }

            // Big streak number
            VStack(spacing: 2) {
                Text("\(currentStreak)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                // The number above is its own Text, so this is the unit alone — but it carries
                // the count, or plural rules cannot apply: Spanish drew "1" over "días de racha".
                Text(habit.streakUnit == "week" ? "week streak (label under \(currentStreak))" : "day streak (label under \(currentStreak))")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            }

            // Secondary stats
            HStack(spacing: 32) {
                VStack(spacing: 4) {
                    Text("\(bestStreak)")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("best streak")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                VStack(spacing: 4) {
                    Text("\(completionRate)%")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("30-day rate")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            // Mini streak dots for last 14 days
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(last14Days, id: \.self) { day in
                        let completed = habit.isCompletedOn(day)
                        Circle()
                            .fill(completed ? .white : .white.opacity(0.2))
                            .frame(width: 16, height: 16)
                    }
                }
                Text("last 14 days")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }

            // Branding
            Text("Stride")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.top, 4)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(
                    LinearGradient(
                        colors: [
                            habit.color,
                            habit.color.opacity(0.7)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cardAccessibilityLabel)
    }

    // The card is one graphic, but VoiceOver otherwise walks it as eight stops with each number
    // split from its caption. The 14 history dots are bare Circles carrying no text at all, so
    // they are summarised as a count here rather than as 14 extra swipes.
    //
    // One whole sentence per streak unit, as a LocalizedStringKey: a label assembled from
    // String(localized:) fragments cannot be reordered by a translator, and String(localized:)
    // reads the SYSTEM language while everything drawn here follows the in-app language picker
    // (\.environment(\.locale)) — the card would speak one language and show another.
    private var cardAccessibilityLabel: LocalizedStringKey {
        let recent = last14Days.filter { habit.isCompletedOn($0) }.count
        return habit.streakUnit == "week"
            ? "\(habit.name), \(currentStreak) week streak, best streak \(bestStreak), 30-day rate \(completionRate) percent, \(recent) of the last 14 days completed"
            : "\(habit.name), \(currentStreak) day streak, best streak \(bestStreak), 30-day rate \(completionRate) percent, \(recent) of the last 14 days completed"
    }

    // MARK: - Image Rendering

    @MainActor
    private func renderImage() -> Image {
        let cardView = streakCard
            .padding(20)
            .frame(width: 380)
            .background(Color.black)
            // ImageRenderer draws its content outside this view hierarchy, so the in-app
            // language (`.environment(\.locale)` on the window) has to be handed over, or the
            // captions in the shared picture follow the device language instead of the sheet.
            .environment(\.locale, locale)

        let renderer = ImageRenderer(content: cardView)
        renderer.scale = 2

        #if os(macOS)
        if let nsImage = renderer.nsImage {
            return Image(nsImage: nsImage)
        }
        #else
        if let uiImage = renderer.uiImage {
            return Image(uiImage: uiImage)
        }
        #endif

        return Image(systemName: "photo")
    }
}
