import Foundation

/// Each request in a multi-step feature operation retains its originating login boundary.
/// A late response after logout cannot authorize the next request with the old session.
nonisolated enum NativeAuthenticationContext {
    @TaskLocal static var check: (@MainActor @Sendable () throws -> Void)?
}
