//
//  CloudKitEntitlement.swift
//  hyperwhisper
//
//  Runtime check for whether this build actually carries the iCloud container
//  entitlement.
//
//  WHY THIS EXISTS
//  Core Data's CloudKit mirroring asks CloudKit for a container by identifier.
//  When the binary lacks `com.apple.developer.icloud-container-identifiers`,
//  CloudKit does not return an error — it traps, and the app dies with
//  EXC_BREAKPOINT inside `PFCloudKitContainerProvider containerWithIdentifier:`
//  before any of our code can react.
//
//  That is reachable in any build signed without the entitlement: ad-hoc or
//  self-signed local builds, forks that cannot provision the upstream iCloud
//  container, and CI artifacts. If the user's stored preference says sync is on,
//  the app crashes on every launch with no way back other than editing defaults.
//
//  Checking the entitlement up front turns that unrecoverable trap into a plain
//  capability check that callers can branch on.
//

import Foundation
import Security

enum CloudKitEntitlement {

    /// Entitlement key naming the iCloud containers a binary may open.
    private static let containerIdentifiersKey = "com.apple.developer.icloud-container-identifiers"

    /// True when the running binary is entitled to at least one iCloud container.
    ///
    /// Evaluated once: the signature cannot change while the process is alive.
    static let isPresent: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }

        var error: Unmanaged<CFError>?
        guard let value = SecTaskCopyValueForEntitlement(task, containerIdentifiersKey as CFString, &error) else {
            error?.release()
            return false
        }

        // Present but empty means no container is actually usable.
        guard let identifiers = value as? [String] else { return false }
        return !identifiers.isEmpty
    }()
}
