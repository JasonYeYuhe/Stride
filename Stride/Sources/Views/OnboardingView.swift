import SwiftUI

struct OnboardingView: View {
    @State private var currentPage = 0
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
            #if os(iOS)
            TabView(selection: $currentPage) {
                ForEach(pages.indices, id: \.self) { index in
                    pageView(pages[index], isLast: index == pages.count - 1)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            #else
            VStack(spacing: 0) {
                pageView(pages[currentPage], isLast: currentPage == pages.count - 1)

                macOSControls
                    .padding(.bottom, 24)
            }
            #endif

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
        .ignoresSafeArea()
        #else
        .frame(minWidth: 500, minHeight: 450)
        #endif
    }

    // MARK: - Page Content

    @ViewBuilder
    private func pageView(_ page: OnboardingPage, isLast: Bool) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: page.symbol)
                .font(.system(size: 72))
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)

            Text(page.title)
                .font(.largeTitle)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text(page.subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

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
            .frame(maxWidth: .infinity)

            // Navigation buttons overlay on the right
            .overlay(alignment: .trailing) {
                HStack(spacing: 12) {
                    if currentPage > 0 {
                        Button("Back") {
                            withAnimation { currentPage -= 1 }
                        }
                    }
                    if currentPage < pages.count - 1 {
                        Button("Next") {
                            withAnimation { currentPage += 1 }
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

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "stride_onboarding_completed")
        isPresented = false
    }
}

// MARK: - Model

private struct OnboardingPage {
    let symbol: String
    let title: String
    let subtitle: String
}

#Preview {
    OnboardingView(isPresented: .constant(true))
}
