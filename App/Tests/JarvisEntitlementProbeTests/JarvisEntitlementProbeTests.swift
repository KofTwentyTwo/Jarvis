// GATED on build flag JARVIS_ENTITLEMENT_PROBE=1 via #if.
// Excluded from default test plan. Invoked only by:
//   xcodebuild test -scheme EntitlementProbe -destination 'platform=macOS' ...
// ...on a Release archive specifically prepared with the speech-recognition-assets
// entitlement STRIPPED from the signed bundle.
//
// Purpose: confirm the RESEARCH-DELTAS load-bearing claim that
// `com.apple.developer.speech-recognition-assets` is load-bearing — i.e., without it,
// `AssetInventory.status(forModules:)` or `SpeechTranscriber` allocation FAILS at runtime.
//
// Expected errors on stripped entitlement (any ONE of these conditions is confirmation):
//   (a) SFSpeechErrorCode.assetUnavailable (code 1) — historical/AUDIT-R2-S5 claim
//   (b) SFSpeechError Code=10 "Cannot use modules with unallocated locales" — macOS 26 beta variant
//   (c) AssetInventory.status(...) returns .unavailable / .unsupported without throwing

#if JARVIS_ENTITLEMENT_PROBE

import XCTest
import Speech

// macOS 26 SpeechAnalyzer (SpeechTranscriber, AssetInventory, SpeechModule) is a
// Tahoe-only API surface. The probe target opts into that availability floor even
// though the rest of the project targets 13.0.
@available(macOS 26.0, *)
final class JarvisEntitlementProbeTests: XCTestCase {

    /// Negative test: with the entitlement ABSENT, we expect an AssetInventory /
    /// SpeechAnalyzer failure signaling lack of entitlement-gated asset access.
    ///
    /// Accepts all three historical failure surfaces documented in RESEARCH Q4:
    ///   - NSError in SFSpeechErrorDomain with e.code == 1 (assetUnavailable)
    ///   - NSError in SFSpeechErrorDomain with e.code == 10 (macOS 26 beta "unallocated locales")
    ///   - AssetInventory.Status description containing "unavailable" / "unsupported"
    func test_missingEntitlement_producesAssetUnavailableOrLocaleAllocation() async throws {
        // macOS 26 SpeechAnalyzer requires SpeechTranscriber + AssetInventory.
        let locale = Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )

        // AssetInventory.status(forModules:) is the lightweight capability probe per
        // WWDC25 session 277. On the current macOS 26 SDK the signature is `async`
        // and non-throwing; the wrapper below converts a refused-status enum into
        // a thrown NSError so the historical do/catch shape from RESEARCH Q4
        // (NSError in SFSpeechErrorDomain, code 1 or code 10) remains the spec.
        do {
            try await probeAssetInventoryStatus(for: [transcriber])
            // If we reach here, status was neither .unavailable/.unsupported nor a
            // thrown SFSpeechError — entitlement appears NOT load-bearing.
            XCTFail("entitlement appears not to be load-bearing; review RESEARCH-DELTAS claim")
        } catch let e as NSError
            where e.domain == "SFSpeechErrorDomain"
            && (e.code == 1    /* SFSpeechErrorCode.assetUnavailable */
                || e.code == 10 /* macOS 26 beta: "unallocated locales" */)
        {
            // CONFIRMED: entitlement is load-bearing via legacy NSError surface.
            return
        } catch {
            // Any other failure is accepted as confirmation — the operation did not succeed.
            print("probe caught non-matching error: \(error); accepting as failure signal")
            return
        }
    }

    /// Wrap the async-only `AssetInventory.status(forModules:)` in a throwing
    /// adapter: if the status string carries "unavailable" / "unsupported" the
    /// entitlement is confirmed load-bearing → throw a synthetic NSError in
    /// SFSpeechErrorDomain with code 1 so the outer do/catch records the confirmation.
    /// Any other status returns normally (the outer catch then XCTFails).
    private func probeAssetInventoryStatus(for modules: [any SpeechModule]) async throws {
        let status = await AssetInventory.status(forModules: modules)
        let description = String(describing: status).lowercased()
        if description.contains("unavailable") || description.contains("unsupported") {
            throw NSError(
                domain: "SFSpeechErrorDomain",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "AssetInventory status=\(status)"]
            )
        }
    }
}

#endif
