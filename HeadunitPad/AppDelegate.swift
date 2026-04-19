//
//  AppDelegate.swift
//  HeadunitPad
//
//  Created by Andy on 2026/4/18.
//

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    static let videoOnlyWindowActivityType = "com.headunitpad.scene.video-only"
    static let trackpadWindowActivityType = "com.headunitpad.scene.trackpad"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    // MARK: - UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let isAuxiliaryWindow = options.userActivities.contains(where: {
            $0.activityType == Self.videoOnlyWindowActivityType || $0.activityType == Self.trackpadWindowActivityType
        })
        let configName = isAuxiliaryWindow ? "Video Window Configuration" : "Default Configuration"
        return UISceneConfiguration(name: configName, sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
    }
}
