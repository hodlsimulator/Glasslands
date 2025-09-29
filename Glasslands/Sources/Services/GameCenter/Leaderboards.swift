//
//  Leaderboards.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import Foundation
import GameKit
import UIKit
import Combine

@MainActor
final class GameCenterHelper: NSObject, ObservableObject {
    static let shared = GameCenterHelper()
    @Published private(set) var isAuthenticated = false

    private override init() { super.init() }

    func authenticate() async {
        let player = GKLocalPlayer.local
        player.authenticateHandler = { [weak self] vc, error in
            Task { @MainActor in
                if let vc {
                    self?.present(vc)
                } else {
                    self?.isAuthenticated = player.isAuthenticated
                    if let error { print("Game Center auth error:", error.localizedDescription) }
                }
            }
        }
    }

    func presentLeaderboards() {
        guard GKLocalPlayer.local.isAuthenticated else { return }
        // iOS 26+: use Access Point trigger (no deprecated VC).
        GKAccessPoint.shared.location = .topLeading
        GKAccessPoint.shared.isActive = true
        GKAccessPoint.shared.trigger(state: .leaderboards) { }
    }

    // MARK: - Presentation helpers
    private func present(_ vc: UIViewController) {
        guard let top = GameCenterHelper.topViewController() else { return }
        top.present(vc, animated: true)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWin = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
        return crawl(from: keyWin?.rootViewController)
    }

    @MainActor
    private static func crawl(from base: UIViewController?) -> UIViewController? {
        guard let base else { return nil }
        if let nav = base as? UINavigationController { return crawl(from: nav.visibleViewController) }
        if let tab = base as? UITabBarController, let sel = tab.selectedViewController { return crawl(from: sel) }
        if let presented = base.presentedViewController { return crawl(from: presented) }
        return base
    }
}
