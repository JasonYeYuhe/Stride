import Foundation

/// When Today shows its inline card (RELEASE-1.4.2.md D12). **A W0 stub: W7 fills it.**
///
/// What W7 builds here, pure, with the `Calendar` and the clock passed in:
/// - the "Your week" card's window, Monday 00:00 to Tuesday 23:59 local time, once last week has
///   an overall counted rate;
/// - Pro: every week, × hides it for that week; free: in at most 3 weeks ever, × ends it;
/// - at most one inline card on Today at a time (the week card is the only one in 1.4.2).
///
/// Its dismissal state lives in `UserDefaults.standard` only: never synced, never in the backup,
/// never read by the widget (Data safety 9). `-inlineCard none|week` overrides it in DEBUG (D14).
enum InlinePrompts {}
