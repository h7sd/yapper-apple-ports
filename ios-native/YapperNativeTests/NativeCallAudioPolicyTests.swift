import LiveKit
import Testing
@testable import YapperNative

@MainActor @Suite struct NativeCallAudioPolicyTests {
    private let own = "abcdef01-2345-4678-9abc-def012345678"
    private let other = "fedcba98-7654-4321-8fed-cba987654321"

    @Test func `Call connection waits for the explicit subscription policy`() {
        #expect(NativeCallController.connectionOptions.autoSubscribe == false)
    }

    @Test(arguments: [
        ("ABCDEF01-2345-4678-9ABC-DEF012345678", "abcdef01-2345-4678-9abc-def012345678"),
        ("ABCDEF01-2345-4678-9ABC-DEF012345678:screen", "abcdef01-2345-4678-9abc-def012345678"),
        ("abcdef01-2345-4678-9abc-def012345678:screen", "abcdef01-2345-4678-9abc-def012345678"),
        ("unknown:screen", "unknown:screen"),
        ("abcdef01-2345-4678-9abc-def012345678:SCREEN", "abcdef01-2345-4678-9abc-def012345678:SCREEN"),
        ("abcdef01-2345-4678-9abc-def012345678:screen:screen", "abcdef01-2345-4678-9abc-def012345678:screen:screen"),
        ("", "")
    ])
    func `Only valid UUID owners are canonicalized`(_ identity: String, _ expected: String) {
        #expect(NativeCallAudioPolicy.normalizedOwner(remoteIdentity: identity) == expected)
    }

    @Test(arguments: [false, true])
    func `Own screen companion cannot be subscribed even when selected`(_ isScreenAudio: Bool) {
        for remote in [own + ":screen", own.uppercased() + ":screen"] {
            for local in [own, own.uppercased()] {
                #expect(!NativeCallAudioPolicy.shouldSubscribe(
                    remoteIdentity: remote, localIdentity: local,
                    isScreenAudio: isScreenAudio, enabledScreenAudioOwner: own
                ))
            }
        }
    }

    @Test(arguments: ["unknown:screen", "abcdef01-2345-4678-9abc-def012345678:SCREEN",
                      "abcdef01-2345-4678-9abc-def012345678:screen:screen"])
    func `Malformed screen suffixes do not masquerade as the local companion`(_ remote: String) {
        #expect(NativeCallAudioPolicy.shouldSubscribe(
            remoteIdentity: remote, localIdentity: own,
            isScreenAudio: false, enabledScreenAudioOwner: nil
        ))
        #expect(NativeCallAudioPolicy.normalizedOwner(remoteIdentity: remote) == remote)
    }

    @Test(arguments: ["unknown", "unknown:screen", ""])
    func `A malformed local identity does not trigger companion suppression`(_ local: String) {
        #expect(NativeCallAudioPolicy.shouldSubscribe(
            remoteIdentity: local + ":screen", localIdentity: local,
            isScreenAudio: false, enabledScreenAudioOwner: nil
        ))
    }

    @Test(arguments: ["fedcba98-7654-4321-8fed-cba987654321",
                      "FEDCBA98-7654-4321-8FED-CBA987654321:screen"])
    func `Screen audio requires the selected normalized owner`(_ remote: String) {
        for selected in [other, other.uppercased(), other + ":screen"] {
            #expect(NativeCallAudioPolicy.shouldSubscribe(
                remoteIdentity: remote, localIdentity: own,
                isScreenAudio: true, enabledScreenAudioOwner: selected
            ))
        }
        for selected in [nil, "", own, "another-owner", other + ":SCREEN"] as [String?] {
            #expect(!NativeCallAudioPolicy.shouldSubscribe(
                remoteIdentity: remote, localIdentity: own,
                isScreenAudio: true, enabledScreenAudioOwner: selected
            ))
        }
    }

    @Test(arguments: ["unknown:screen", "unknown", ""])
    func `Unknown identities use exact owner matching for screen audio`(_ remote: String) {
        #expect(!NativeCallAudioPolicy.shouldSubscribe(
            remoteIdentity: remote, localIdentity: own,
            isScreenAudio: true, enabledScreenAudioOwner: nil
        ))
        #expect(!NativeCallAudioPolicy.shouldSubscribe(
            remoteIdentity: remote, localIdentity: own,
            isScreenAudio: true, enabledScreenAudioOwner: "unknown:screen:screen"
        ))
        #expect(NativeCallAudioPolicy.shouldSubscribe(
            remoteIdentity: remote, localIdentity: own,
            isScreenAudio: true, enabledScreenAudioOwner: remote
        ) == !remote.isEmpty)
    }

    @Test(arguments: ["fedcba98-7654-4321-8fed-cba987654321",
                      "FEDCBA98-7654-4321-8FED-CBA987654321:screen", "unknown", "unknown:screen", ""])
    func `Ordinary audio and video remain available without screen audio selection`(_ remote: String) {
        #expect(NativeCallAudioPolicy.shouldSubscribe(
            remoteIdentity: remote, localIdentity: own,
            isScreenAudio: false, enabledScreenAudioOwner: nil
        ))
    }

    @Test(arguments: [(-1.0, 0.0), (0, 0), (0.4, 0.4), (1, 1), (1.5, 1.5), (2, 2), (3, 2)])
    func `Allowed playback volume is clamped to the supported range`(_ requested: Double, _ expected: Double) {
        #expect(NativeCallAudioPolicy.remoteAudioVolume(
            remoteIdentity: other, localIdentity: own,
            isScreenAudio: false, enabledScreenAudioOwner: nil,
            deafened: false, requestedVolume: requested
        ) == expected)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
    func `Nonfinite playback gain is silent`(_ gain: Double) {
        #expect(NativeCallAudioPolicy.remoteAudioVolume(
            remoteIdentity: other, localIdentity: own,
            isScreenAudio: false, enabledScreenAudioOwner: nil,
            deafened: false, requestedVolume: gain
        ) == 0)
    }

    @Test(arguments: [false, true])
    func `Subscription and deafen decisions also gate playback gain`(_ deafened: Bool) {
        #expect(NativeCallAudioPolicy.remoteAudioVolume(
            remoteIdentity: own + ":screen", localIdentity: own,
            isScreenAudio: false, enabledScreenAudioOwner: own,
            deafened: deafened, requestedVolume: 1
        ) == 0)
        #expect(NativeCallAudioPolicy.remoteAudioVolume(
            remoteIdentity: other + ":screen", localIdentity: own,
            isScreenAudio: true, enabledScreenAudioOwner: nil,
            deafened: deafened, requestedVolume: 1
        ) == 0)
        #expect(NativeCallAudioPolicy.remoteAudioVolume(
            remoteIdentity: other + ":screen", localIdentity: own,
            isScreenAudio: true, enabledScreenAudioOwner: other,
            deafened: deafened, requestedVolume: 1.5
        ) == (deafened ? 0 : 1.5))
        #expect(NativeCallAudioPolicy.remoteAudioVolume(
            remoteIdentity: other, localIdentity: own,
            isScreenAudio: false, enabledScreenAudioOwner: nil,
            deafened: deafened, requestedVolume: 1
        ) == (deafened ? 0 : 1))
    }
}
