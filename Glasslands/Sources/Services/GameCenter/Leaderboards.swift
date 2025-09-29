//
//  Leaderboards.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import Foundation
import GameKit
import UIKit

@MainActor
final class GameCenterHelper: NSObject, ObservableObject {
    static let shared = GameCenterHelper()
    @Published private(set) var isAuthenticated = false

    private override init() { super.init() }

    func authenticate() async {
        let player = GKLocalPlayer.local
        player.authenticateHandler = { [weak self] vc, error in
            if let vc = vc {
                self?.present(vc)
            } else {
                self?.isAuthenticated = player.isAuthenticated
                if let error { print("Game Center auth error:", error.localizedDescription) }
            }
        }
    }

    func presentLeaderboards() {
        guard GKLocalPlayer.local.isAuthenticated else { return }
        let gc = GKGameCenterViewController(state: .leaderboards)
        gc.gameCenterDelegate = self
        present(gc)
    }

    // MARK: - Presentation
    private func present(_ vc: UIViewController) {
        guard let top = Self.topViewController() else { return }
        top.present(vc, animated: true)
    }

    private static func topViewController(base: UIViewController? = {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWin = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
        return keyWin?.rootViewController
    }()) -> UIViewController? {
        if let nav = base as? UINavigationController { return topViewController(base: nav.visibleViewController) }
        if let tab = base as? UITabBarController, let sel = tab.selectedViewController { return topViewController(base: sel) }
        if let presented = base?.presentedViewController { return topViewController(base: presented) }
        return base
    }
}

extension GameCenterHelper: GKGameCenterControllerDelegate {
    func gameCenterViewControllerDidFinish(_ gameCenterViewController: GKGameCenterViewController) {
        gameCenterViewController.dismiss(animated: true)
    }
}
