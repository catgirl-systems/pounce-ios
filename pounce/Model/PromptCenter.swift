import Foundation
import Observation
import PounceCore

/// host key and password questions, asked one at a time; the ssh handshake
/// waits on the answer.
@MainActor @Observable final class PromptCenter {
    enum Kind: Equatable {
        case hostKey(endpoint: SSHEndpoint, key: SSHPublicKey, previous: KnownHost?)
        case password(endpoint: SSHEndpoint, canSave: Bool)
    }

    enum Answer: Equatable {
        case accept
        case reject
        case password(String, save: Bool)
    }

    struct Prompt: Identifiable, Equatable {
        let id = UUID()
        let kind: Kind
    }

    private(set) var current: Prompt?
    @ObservationIgnored private var waiting: [(Prompt, CheckedContinuation<Answer, Never>)] = []

    func ask(_ kind: Kind) async -> Answer {
        await withCheckedContinuation { continuation in
            let prompt = Prompt(kind: kind)
            waiting.append((prompt, continuation))
            if current == nil { current = prompt }
        }
    }

    func answer(_ answer: Answer) {
        guard let current, let index = waiting.firstIndex(where: { $0.0.id == current.id }) else { return }
        let (_, continuation) = waiting.remove(at: index)
        continuation.resume(returning: answer)
        self.current = waiting.first?.0
    }
}
