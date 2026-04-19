//
//  SceneDelegate.swift
//  HeadunitPad
//
//  Created by Andy on 2026/4/18.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let requestedActivityType = connectionOptions.userActivities.first?.activityType
            ?? session.stateRestorationActivity?.activityType

        let rootViewController: UIViewController
        switch requestedActivityType {
        case AppDelegate.videoOnlyWindowActivityType:
            session.stateRestorationActivity = NSUserActivity(activityType: AppDelegate.videoOnlyWindowActivityType)
            rootViewController = VideoOnlyViewController()
        case AppDelegate.trackpadWindowActivityType:
            session.stateRestorationActivity = NSUserActivity(activityType: AppDelegate.trackpadWindowActivityType)
            rootViewController = TrackpadViewController()
        default:
            rootViewController = MainViewController()
        }

        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = rootViewController
        window?.makeKeyAndVisible()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
    }

    func sceneWillResignActive(_ scene: UIScene) {
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
    }
}
