//
//  Discovery.swift
//  HeadunitPad
//
//  Network discovery for Android Auto Headunit Server (port 5277)
//

import Foundation
import Network

struct DiscoveredDevice: Identifiable, Equatable {
    let id = UUID()
    let ip: String
    let port: UInt16
    let name: String?

    var displayName: String {
        return name ?? "\(ip):\(port)"
    }

    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        return lhs.ip == rhs.ip && lhs.port == rhs.port
    }
}

protocol DiscoveryDelegate: AnyObject {
    func discoveryDidFindDevice(_ device: DiscoveredDevice)
    func discoveryDidFinish()
    func discoveryDidFail(_ error: Error)
}

class Discovery {
    weak var delegate: DiscoveryDelegate?

    private let queue = DispatchQueue(label: "com.headunitpad.discovery", qos: .userInitiated)
    private var browseWorkItem: DispatchWorkItem?
    private var isScanning = false
    private var activeProbeConnections: [UUID: NWConnection] = [:]
    private var preparedConnections: [String: NWConnection] = [:]
    private let probeLock = NSLock()

    private let targetPort: UInt16 = 5277
    private let connectionTimeout: TimeInterval = 2.5

    init() {}

    func startScan() {
        guard !isScanning else { return }
        isScanning = true

        browseWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.performSubnetScan()
        }

        browseWorkItem = workItem
        queue.async(execute: workItem)
    }

    func stopScan() {
        browseWorkItem?.cancel()
        browseWorkItem = nil
        isScanning = false

        probeLock.lock()
        let connections = activeProbeConnections.values
        activeProbeConnections.removeAll()
        let prepared = preparedConnections.values
        preparedConnections.removeAll()
        probeLock.unlock()

        for connection in connections {
            connection.cancel()
        }

        for connection in prepared {
            connection.cancel()
        }
    }

    func takePreparedConnection(ip: String, port: UInt16) -> NWConnection? {
        let key = preparedConnectionKey(ip: ip, port: port)
        probeLock.lock()
        let connection = preparedConnections.removeValue(forKey: key)
        probeLock.unlock()
        return connection
    }

    private func performSubnetScan() {
        guard let networkInfo = getWiFiNetworkInfo() else {
            print("Discovery: Could not find WiFi network info")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.discoveryDidFail(DiscoveryError.noNetworkInterface)
            }
            return
        }

        print("Discovery: Using local IP \(networkInfo.ip) on subnet \(networkInfo.subnet)")

        let group = DispatchGroup()

        for i in 1...254 {
            let ip = "\(networkInfo.subnet).\(i)"

            if ip == networkInfo.ip {
                continue
            }

            group.enter()
            checkHost(ip: ip, port: targetPort) { [weak self] success, foundIP in
                if success, let foundIP = foundIP {
                    let device = DiscoveredDevice(ip: foundIP, port: self?.targetPort ?? 5277, name: nil)
                    DispatchQueue.main.async {
                        self?.delegate?.discoveryDidFindDevice(device)
                    }
                }
                group.leave()
            }
        }

        group.notify(queue: queue) { [weak self] in
            self?.isScanning = false
            print("Discovery: Scan complete")
            DispatchQueue.main.async {
                self?.delegate?.discoveryDidFinish()
            }
        }
    }

    private func checkHost(ip: String, port: UInt16, completion: @escaping (Bool, String?) -> Void) {
        guard isScanning else {
            completion(false, nil)
            return
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: port)!)

        let parameters = NWParameters.tcp
        parameters.prohibitExpensivePaths = true

        let connection = NWConnection(to: endpoint, using: parameters)
        let probeId = UUID()

        probeLock.lock()
        activeProbeConnections[probeId] = connection
        probeLock.unlock()

        let finishProbe: (Bool, String?) -> Void = { [weak self] success, foundIP in
            guard let self = self else {
                completion(success, foundIP)
                return
            }

            self.probeLock.lock()
            self.activeProbeConnections.removeValue(forKey: probeId)
            self.probeLock.unlock()

            completion(success, foundIP)
        }

        var hasCompleted = false
        let lock = NSLock()

        let timeoutWorkItem = DispatchWorkItem {
            lock.lock()
            if !hasCompleted {
                hasCompleted = true
                lock.unlock()
                connection.cancel()
                finishProbe(false, nil)
            } else {
                lock.unlock()
            }
        }

        queue.asyncAfter(deadline: .now() + connectionTimeout, execute: timeoutWorkItem)

        connection.stateUpdateHandler = { state in
            lock.lock()
            guard !hasCompleted else {
                lock.unlock()
                return
            }

            switch state {
            case .ready:
                hasCompleted = true
                lock.unlock()
                timeoutWorkItem.cancel()
                self.storePreparedConnection(connection, ip: ip, port: port)
                finishProbe(true, ip)

            case .failed, .cancelled:
                hasCompleted = true
                lock.unlock()
                connection.cancel()
                finishProbe(false, nil)

            default:
                lock.unlock()
            }
        }

        connection.start(queue: queue)
    }

    private func storePreparedConnection(_ connection: NWConnection, ip: String, port: UInt16) {
        let key = preparedConnectionKey(ip: ip, port: port)

        probeLock.lock()
        if let oldConnection = preparedConnections[key] {
            oldConnection.cancel()
        }
        preparedConnections[key] = connection
        probeLock.unlock()
    }

    private func preparedConnectionKey(ip: String, port: UInt16) -> String {
        return "\(ip):\(port)"
    }

    private func getWiFiNetworkInfo() -> (ip: String, subnet: String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var current = ifaddr
        while let addr = current {
            let name = String(cString: addr.pointee.ifa_name)
            print("Discovery: Checking interface: \(name)")

            if name == "en0" || name == "en1" {
                if addr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))

                    let result = getnameinfo(
                        addr.pointee.ifa_addr,
                        socklen_t(addr.pointee.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )

                    if result == 0 {
                        let ip = String(cString: hostname)
                        print("Discovery: Found WiFi IP: \(ip)")

                        if ip.hasPrefix("169.254.") {
                            print("Discovery: Ignoring link-local address")
                        } else {
                            let components = ip.split(separator: ".")
                            if components.count == 4 {
                                let subnet = "\(components[0]).\(components[1]).\(components[2])"
                                return (ip, subnet)
                            }
                        }
                    }
                }
            }
            current = addr.pointee.ifa_next
        }

        print("Discovery: Could not find WiFi interface (en0/en1)")
        return nil
    }
}

enum DiscoveryError: Error, LocalizedError {
    case noNetworkInterface
    case scanFailed

    var errorDescription: String? {
        switch self {
        case .noNetworkInterface:
            return "No WiFi network interface found"
        case .scanFailed:
            return "Network scan failed"
        }
    }
}
