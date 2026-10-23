#if os(iOS)
import AuthenticationServices
import UIKit

/// System browser sign-in with a separate, IPv4 loopback HTTP callback.
/// A fresh attempt owns every resource; callbacks from earlier attempts are ignored.
@MainActor
final class ChatGPTBrowserAuthorization: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var activeID: UUID?
    private var continuation: CheckedContinuation<URL, Error>?
    private var loopback: ChatGPTLoopback?
    private var session: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?
    private var startupTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func authorize(buildURL: @escaping (URL) throws -> URL) async throws -> URL {
        cancel()
        guard !Task.isCancelled else { throw ChatGPTError.cancelled }
        let id = UUID()
        activeID = id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else {
                    finish(id, result: .failure(ChatGPTError.cancelled))
                    return
                }
                timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    self?.finish(id, result: .failure(ChatGPTError.network))
                }
                startupTask = Task { @MainActor [weak self] in
                    await self?.begin(id, buildURL: buildURL)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id, result: .failure(ChatGPTError.cancelled))
            }
        }
    }

    func cancel() {
        guard let id = activeID else { return }
        finish(id, result: .failure(ChatGPTError.cancelled))
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Kept strongly for the full session; begin() requires a visible key window.
        anchor ?? ASPresentationAnchor()
    }

    private func begin(_ id: UUID, buildURL: @escaping (URL) throws -> URL) async {
        let listener = ChatGPTLoopback()
        guard activeID == id else { return }
        loopback = listener
        listener.onCallback = { [weak self] callback in self?.finish(id, result: .success(callback)) }
        listener.onFailure = { [weak self] in self?.finish(id, result: .failure(ChatGPTError.network)) }
        do {
            // The listener must be ready, with its actual ephemeral port, before PKCE URL construction.
            let callbackURL = try await listener.start()
            guard activeID == id, !Task.isCancelled else { return }
            let authorizationURL = try buildURL(callbackURL)
            guard let components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false),
                  components.scheme == "https", components.host != nil,
                  components.user == nil, components.password == nil,
                  components.fragment == nil,
                  let states = components.queryItems?.filter({ $0.name == "state" }),
                  states.count == 1, let state = states.first?.value, !state.isEmpty else {
                throw ChatGPTError.invalidCallback
            }
            listener.expectedState = state
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .filter({ $0.activationState == .foregroundActive })
                .flatMap(\.windows).first(where: \.isKeyWindow) else { throw ChatGPTError.network }
            anchor = window
            let browser = ASWebAuthenticationSession(url: authorizationURL, callbackURLScheme: nil) { [weak self] _, error in
                // Success is exclusively the validated HTTP listener callback. The web
                // session callback is relevant only for user cancellation or failure.
                guard let error else { return }
                let nsError = error as NSError
                let cancelled = nsError.domain == ASWebAuthenticationSessionError.errorDomain
                    && nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
                Task { @MainActor in
                    self?.finish(id, result: .failure(cancelled ? ChatGPTError.cancelled : ChatGPTError.network))
                }
            }
            browser.presentationContextProvider = self
            session = browser
            guard browser.start() else { throw ChatGPTError.network }
        } catch {
            let mapped: Error = error is CancellationError ? ChatGPTError.cancelled : error
            finish(id, result: .failure(mapped))
        }
    }

    private func finish(_ id: UUID, result: Result<URL, Error>) {
        guard activeID == id else { return }
        // Invalidate first: cancel() and queued callbacks can synchronously reenter.
        activeID = nil
        let pending = continuation
        continuation = nil
        startupTask?.cancel()
        startupTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        loopback?.stop()
        loopback = nil
        let browser = session
        session = nil
        browser?.cancel()
        anchor = nil
        pending?.resume(with: result)
    }
}
#endif
