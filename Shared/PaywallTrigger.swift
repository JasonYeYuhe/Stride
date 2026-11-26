import Foundation

/// Why the paywall was opened (RELEASE-1.4.2.md D4). Every presenter passes its own, so the
/// paywall can say why it is showing:
/// - W3 words the header's subtitle by it and puts the trigger's feature row first (the other
///   two follow in D11's order);
/// - D8's shell request `.paywall(trigger:resume:)` carries it, so Continue knows what to resume.
///
/// W0 adds the type and has every presenter pass it; nothing reads it yet. A pure value, as
/// everything in Shared/ is: no words here, the view owns the keys.
enum PaywallTrigger: String, CaseIterable, Hashable, Identifiable {
    /// Statistics' locked Advanced Analytics card.
    case analytics
    /// The Weekly Review button (Statistics' toolbar, the Mac's View menu) for a free user.
    case weeklyReview
    /// Today's "Your week" card (D12), for a free user.
    case today
    /// New Group in the habit editor (AddHabitView).
    case groups
    /// Settings' Upgrade to Pro row, and the default.
    case settings
    /// Onboarding's "What's in Stride Pro" (D12).
    case onboarding
    /// Settings' "Pro ended on <date>" row, with Resubscribe.
    case lapsed

    var id: Self { self }
}
