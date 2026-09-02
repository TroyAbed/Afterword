import Foundation

/// Lets the sidebar ask the detail view to jump to a spot in a session.
@MainActor
final class Navigator: ObservableObject {
    struct SeekRequest: Equatable {
        let session: UUID
        let time: TimeInterval
        let token: UUID          // so repeating the same jump still fires
    }

    @Published var seekRequest: SeekRequest?

    func jump(to session: UUID, at time: TimeInterval) {
        seekRequest = SeekRequest(session: session, time: time, token: UUID())
    }
}
