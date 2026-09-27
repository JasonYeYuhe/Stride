import SwiftUI

struct OnboardingView: View {
    @State private var currentPage = 0
    @AccessibilityFocusState private var focusedPage: Int?
    @Binding var isPresented: Bool

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            symbol: "figure.walk",
            title: "Welcome to Stride",
            subtitle: "Build better habits, one day at a time"
        ),
        OnboardingPage(
            symbol: "checkmark.circle.fill",
            title: "Track Daily Habits",
            subtitle: "Check off habits each day and build streaks"
        ),
        OnboardingPage(
            symbol: "chart.bar.fill",
            title: "See Your Progress",
            subtitle: "View streaks, completion rates, and patterns"
        ),
        OnboardingPage(
            symbol: "icloud.fill",
            title: "Sync Everywhere",
            subtitle: "Sign in to keep habits in sync across devices"
        ),
    ]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                pageView(pages[currentPage], isLast: currentPage == pages.count - 1)

                #if os(iOS)
                // Page dots
                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { index in
                        Circle()
                            .fill(index == currentPage ? Color.green : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Page \(currentPage + 1) of \(pages.count)")
                .padding(.bottom, 16)
                #else
                macOSControls
                    .padding(.bottom, 24)
                #endif
            }

            // Skip button
            if currentPage < pages.count - 1 {
                Button("Skip") {
                    completeOnboarding()
                }
                .foregroundStyle(.secondary)
                .padding()
            }
        }
        #if os(iOS)
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if value.translation.width < -30, currentPage < pages.count - 1 {
                        goToPage(currentPage + 1)
                    } else if value.translation.width > 30, currentPage > 0 {
                        goToPage(currentPage - 1)
                    }
                }
        )
        .accessibilityAction(.escape) { completeOnboarding() }
        // VoiceOver swallows the drag gesture above, so these rotor actions are the
        // only way through onboarding; offer them only when they can actually move.
        .accessibilityActions {
            if currentPage < pages.count - 1 {
                Button("Next") { goToPage(currentPage + 1) }
            }
            if currentPage > 0 {
                Button("Back") { goToPage(currentPage - 1) }
            }
        }
        #else
        .frame(minWidth: 500, minHeight: 450)
        #endif
    }

    // MARK: - Page Content

    @ViewBuilder
    private func pageView(_ page: OnboardingPage, isLast: Bool) -> some View {
        VStack(spacing: 24) {
            Spacer()

            // Same spacing as the enclosing VStack, so wrapping these three for
            // VoiceOver leaves the rendered layout unchanged.
            VStack(spacing: 24) {
                Image(systemName: page.symbol)
                    .font(.system(size: 72))
                    .foregroundStyle(.green)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)

                Text(page.title)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text(page.subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($focusedPage, equals: currentPage)

            Spacer()

            if isLast {
                Button(action: completeOnboarding) {
                    Text("Get Started")
                        .font(.headline)
                        .frame(maxWidth: 280)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .padding(.bottom, 60)
            } else {
                // Reserve space so layout stays stable
                Color.clear
                    .frame(height: 60)
                    .padding(.bottom, 60)
            }
        }
        .padding()
    }

    // MARK: - macOS Navigation

    #if os(macOS)
    private var macOSControls: some View {
        HStack(spacing: 16) {
            // Page dots
            HStack(spacing: 8) {
                ForEach(pages.indices, id: \.self) { index in
                    Circle()
                        .fill(index == currentPage ? Color.green : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            // Labelled here rather than after .overlay, which would swallow the
            // Back/Next buttons below into this one element.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(currentPage + 1) of \(pages.count)")
            .frame(maxWidth: .infinity)

            // Navigation buttons overlay on the right
            .overlay(alignment: .trailing) {
                HStack(spacing: 12) {
                    if currentPage > 0 {
                        Button("Back") {
                            goToPage(currentPage - 1)
                        }
                    }
                    if currentPage < pages.count - 1 {
                        Button("Next") {
                            goToPage(currentPage + 1)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                }
            }
        }
        .padding(.horizontal, 32)
    }
    #endif

    // MARK: - Actions

    private func goToPage(_ index: Int) {
        withAnimation { currentPage = index }
        // The page element keeps its identity across the change, so VoiceOver
        // re-reads it only when focus genuinely moves onto it: clear, then re-set.
        focusedPage = nil
        Task { @MainActor in focusedPage = index }
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "stride_onboarding_completed")
        withAnimation {
            isPresented = false
        }
    }
}

// MARK: - Model

private struct OnboardingPage {
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
}

#Preview {
    OnboardingView(isPresented: .constant(true))
}
