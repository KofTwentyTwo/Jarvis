import Foundation

/// Phase 8 harness library version stamp.
///
/// Sole purpose at scaffold time (Plan 08-01 Task 1): give the library target
/// a single public symbol so the test target can import Harness and the
/// executable target can link it before Tasks 2/3 add real types.
public enum HarnessVersion {
    public static let value = "0.1.0"
}
