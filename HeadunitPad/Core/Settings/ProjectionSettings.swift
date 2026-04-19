import Foundation
import UIKit
import Network

enum ProjectionVideoResolution: Int {
    case r800x480 = 1
    case r1280x720 = 2
    case r1920x1080 = 3
    case r768x1024 = 4
    case r1200x1600 = 5

    func title(for orientation: ProjectionOrientation) -> String {
        let size = dimensions(for: orientation)
        return "\(size.width)x\(size.height)"
    }

    func dimensions(for orientation: ProjectionOrientation) -> (width: Int, height: Int) {
        switch orientation {
        case .landscape:
            switch self {
            case .r800x480:
                return (800, 480)
            case .r1280x720:
                return (1280, 720)
            case .r1920x1080:
                return (1920, 1080)
            case .r768x1024:
                return (768, 1024)
            case .r1200x1600:
                return (1200, 1600)
            }
        case .portrait:
            switch self {
            case .r800x480:
                return (480, 800)
            case .r1280x720:
                return (720, 1280)
            case .r1920x1080:
                return (1080, 1920)
            case .r768x1024:
                return (768, 1024)
            case .r1200x1600:
                return (1200, 1600)
            }
        }
    }

    func codecResolutionValue(for orientation: ProjectionOrientation) -> Int {
        switch orientation {
        case .landscape:
            return rawValue
        case .portrait:
            switch self {
            case .r800x480, .r1280x720:
                return 6
            case .r1920x1080:
                return 7
            case .r768x1024:
                return 8
            case .r1200x1600:
                return 9
            }
        }
    }
}

enum ProjectionFpsLimit: Int {
    case fps60 = 1
    case fps30 = 2

    var title: String {
        switch self {
        case .fps60:
            return "60 FPS"
        case .fps30:
            return "30 FPS"
        }
    }
}

enum ProjectionGpsSource: Int {
    case phone = 0
    case ipad = 1

    var title: String {
        switch self {
        case .phone:
            return "Use Phone GPS"
        case .ipad:
            return "Use iPad GPS"
        }
    }
}

enum ProjectionOrientation: Int {
    case landscape = 0
    case portrait = 1

    var title: String {
        switch self {
        case .landscape:
            return "Landscape"
        case .portrait:
            return "Portrait"
        }
    }
}

enum ProjectionSettings {
    private static let defaults = UserDefaults.standard
    private static let videoResolutionKey = "projection-video-resolution"
    private static let fpsLimitKey = "projection-fps-limit"
    private static let gpsSourceKey = "projection-gps-source"
    private static let orientationKey = "projection-orientation"
    private static let dpiKey = "projection-dpi"
    private static var cachedCellularSupport: Bool?
    private static let portraitCompatibilityResolution: ProjectionVideoResolution = .r1920x1080
    static let defaultDpi = 160
    static let minDpi = 80
    static let maxDpi = 640
    static let portraitMaxDpi = 190

    static var videoResolution: ProjectionVideoResolution {
        get {
            let value = defaults.integer(forKey: videoResolutionKey)
            if let resolution = ProjectionVideoResolution(rawValue: value) {
                return resolution
            }
            if orientation == .portrait {
                return .r768x1024
            }
            return .r1280x720
        }
        set {
            defaults.set(newValue.rawValue, forKey: videoResolutionKey)
        }
    }

    static var orientation: ProjectionOrientation {
        get {
            let value = defaults.integer(forKey: orientationKey)
            return ProjectionOrientation(rawValue: value) ?? .landscape
        }
        set {
            defaults.set(newValue.rawValue, forKey: orientationKey)
            if newValue == .portrait {
                let currentRes = videoResolution
                if currentRes == .r800x480 {
                    videoResolution = .r768x1024
                }
            }
        }
    }

    static var dpi: Int {
        get {
            let value = defaults.integer(forKey: dpiKey)
            if value == 0 {
                return defaultDpi
            }
            return clampDpi(value)
        }
        set {
            defaults.set(clampDpi(newValue), forKey: dpiKey)
        }
    }

    static func resetDpiToDefault() {
        defaults.set(defaultDpi, forKey: dpiKey)
    }

    static func availableResolutions(for orientation: ProjectionOrientation) -> [ProjectionVideoResolution] {
        switch orientation {
        case .landscape:
            return [.r800x480, .r1280x720, .r1920x1080, .r768x1024]
        case .portrait:
            return [.r768x1024, .r1200x1600, .r1280x720, .r1920x1080]
        }
    }

    static var effectiveVideoCodecResolutionValue: Int {
        if orientation == .portrait {
            return portraitCompatibilityResolution.codecResolutionValue(for: .portrait)
        }
        return videoResolution.codecResolutionValue(for: orientation)
    }

    static var effectiveVideoDimensions: (width: Int, height: Int) {
        if orientation == .portrait {
            return portraitCompatibilityResolution.dimensions(for: .portrait)
        }
        return videoResolution.dimensions(for: orientation)
    }

    static var fpsLimit: ProjectionFpsLimit {
        get {
            let value = defaults.integer(forKey: fpsLimitKey)
            return ProjectionFpsLimit(rawValue: value) ?? .fps30
        }
        set {
            defaults.set(newValue.rawValue, forKey: fpsLimitKey)
        }
    }

    static var effectiveFpsLimit: ProjectionFpsLimit {
        // Portrait projection has shown lower stability across some AA apps.
        // Force 30 FPS in portrait as a compatibility guardrail.
        if orientation == .portrait {
            return .fps30
        }
        return fpsLimit
    }

    static var effectiveDpi: Int {
        if orientation == .portrait {
            return min(dpi, portraitMaxDpi)
        }
        return dpi
    }

    static var gpsSource: ProjectionGpsSource {
        get {
            let value = defaults.integer(forKey: gpsSourceKey)
            let source = ProjectionGpsSource(rawValue: value) ?? .phone
            if source == .ipad && !supportsCellularIpad() {
                return .phone
            }
            return source
        }
        set {
            let source = (newValue == .ipad && !supportsCellularIpad()) ? ProjectionGpsSource.phone : newValue
            defaults.set(source.rawValue, forKey: gpsSourceKey)
        }
    }

    static func supportsCellularIpad() -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return false }
        if let cached = cachedCellularSupport {
            return cached
        }

#if targetEnvironment(simulator)
        cachedCellularSupport = false
        return false
#else
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.headunitpad.cellular-detect")
        let semaphore = DispatchSemaphore(value: 0)
        var hasCellularInterface = false

        monitor.pathUpdateHandler = { path in
            hasCellularInterface = path.availableInterfaces.contains { $0.type == .cellular }
            semaphore.signal()
        }

        monitor.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 0.35)
        monitor.cancel()

        cachedCellularSupport = hasCellularInterface
        return hasCellularInterface
#endif
    }

    private static func clampDpi(_ value: Int) -> Int {
        return min(max(value, minDpi), maxDpi)
    }
}
