import Foundation
import MapKit

/// Apple Maps may use the network. Only the capture coordinate and preferred locale are supplied.
@MainActor final class AppleCaptureAddressResolver: CaptureAddressResolving {
    private struct Pending {
        let id: UUID
        let request: MKReverseGeocodingRequest
        let continuation: CheckedContinuation<CaptureAddress, Error>
    }
    private var pending: Pending?
    private var timeout: Task<Void, Never>?

    func resolve(_ point: CaptureLocation, localeIdentifier: String) async throws -> CaptureAddress {
        cancel()
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: point.latitude, longitude: point.longitude)) else {
            throw URLError(.badURL)
        }
        request.preferredLocale = Locale(identifier: localeIdentifier)
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = Pending(id: id, request: request, continuation: continuation)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    self?.finish(id: id, result: .failure(URLError(.timedOut)))
                }
                request.getMapItems { [weak self] items, error in
                    guard let self, self.pending?.id == id else { return }
                    if let error { self.finish(id: id, result: .failure(error)); return }
                    let item = items?.first
                    let parts = item?.addressRepresentations
                    let text = parts?.fullAddress(includingRegion: true, singleLine: true) ?? item?.address?.fullAddress
                    guard let text, let address = CaptureAddress(text: text, localeIdentifier: localeIdentifier,
                                                               city: parts?.cityName, region: parts?.regionName) else {
                        self.finish(id: id, result: .failure(URLError(.cannotParseResponse))); return
                    }
                    self.finish(id: id, result: .success(address))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id: id, result: .failure(CancellationError())) }
        }
    }
    func cancel() {
        guard let pending else { return }
        finish(id: pending.id, result: .failure(CancellationError()))
    }
    private func finish(id: UUID, result: Result<CaptureAddress, Error>) {
        guard let current = pending, current.id == id else { return }
        pending = nil; timeout?.cancel(); timeout = nil
        current.request.cancel()
        current.continuation.resume(with: result)
    }
}
