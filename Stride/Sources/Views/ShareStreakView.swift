import SwiftUI

struct ShareStreakView: View {
    let habit: Habit
    @Environment(\.dismiss) private var dismiss

    private var currentStreak: Int { habit.currentStreak() }
    private var bestStreak: Int { habit.bestStreak() }
    private var completionRate: Int { Int(habit.completionRate() * 100) }
    private var last14Days: [Date] { Date.lastNDays(14) }

    private var shareText: String {
        "\(habit.emoji) \(currentStreak) day streak on \(habit.name)! 🔥"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                streakCard
                    .padding(.horizontal)

                ShareLink(
                    item: renderedImage,
                    preview: SharePreview(shareText, image: renderedImage)
                ) {
                    Label("Share Streak", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(habit.color)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
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
        }
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
                Text("day streak")
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
    }

    // MARK: - Image Rendering

    @MainActor
    private var renderedImage: Image {
        let cardView = streakCard
            .padding(20)
            .frame(width: 380)
            .background(Color.black)

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
