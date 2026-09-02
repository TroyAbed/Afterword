import EventKit
import Foundation

struct CalendarEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let link: URL?

    var timeRange: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: start))–\(f.string(from: end))"
    }
}

/// Reads the macOS Calendar — which already aggregates Google / Outlook / iCloud
/// accounts — to find the meeting running right now, so a recording can be
/// titled (and later started) automatically.
@MainActor
final class MeetingCalendar: ObservableObject {
    @Published private(set) var current: CalendarEvent?
    @Published private(set) var authorized = false
    @Published private(set) var denied = false

    private let store = EKEventStore()
    private var timer: Timer?

    /// Re-check the calendar every 20 s so a starting meeting is noticed.
    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func requestAccessAndRefresh() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .denied || status == .restricted { denied = true; return }

        if status == .fullAccess {
            authorized = true
        } else {
            authorized = (try? await store.requestFullAccessToEvents()) ?? false
            denied = !authorized
        }
        if authorized { refresh() }
    }

    /// The event that is running now (or starts within 5 minutes).
    func refresh() {
        guard authorized else { return }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-4 * 3600),
            end: now.addingTimeInterval(15 * 60),
            calendars: nil)

        current = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .filter { $0.endDate > now && $0.startDate < now.addingTimeInterval(5 * 60) }
            .sorted { $0.startDate < $1.startDate }
            .first
            .map {
                CalendarEvent(id: $0.eventIdentifier ?? UUID().uuidString,
                              title: ($0.title ?? "Meeting").trimmingCharacters(in: .whitespaces),
                              start: $0.startDate, end: $0.endDate,
                              link: Self.meetingLink(in: $0))
            }
    }

    private static let linkPatterns = [
        #"https://[^\s<>"]*zoom\.us/j/[^\s<>"]*"#,
        #"https://teams\.(microsoft|live)\.com/[^\s<>"]*"#,
        #"https://meet\.google\.com/[^\s<>"]*"#,
        #"https://[^\s<>"]*webex\.com/[^\s<>"]*"#,
        #"https://[^\s<>"]*whereby\.com/[^\s<>"]*"#,
    ]

    private static func meetingLink(in e: EKEvent) -> URL? {
        let haystack = [e.url?.absoluteString, e.notes, e.location]
            .compactMap { $0 }.joined(separator: "\n")
        for p in linkPatterns {
            if let r = haystack.range(of: p, options: .regularExpression) {
                return URL(string: String(haystack[r]))
            }
        }
        return e.url
    }
}
