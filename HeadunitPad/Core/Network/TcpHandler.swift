//
//  TcpHandler.swift
//  HeadunitPad
//
//  Plain TCP connection handler (no TLS at socket level)
//  Note: Android Auto uses TLS inside the AAP protocol, not at socket level
//

import Foundation
import Network

enum TcpHandlerError: Error {
    case connectionFailed(String)
    case connectionClosed
    case invalidState
    case writeFailed
    case readFailed
    case timeout
}

protocol TcpHandlerDelegate: AnyObject {
    func tcpHandlerDidConnect(_ handler: TcpHandler)
    func tcpHandler(_ handler: TcpHandler, didFailWithError error: Error)
    func tcpHandler(_ handler: TcpHandler, didReceiveData data: Data)
    func tcpHandlerDidDisconnect(_ handler: TcpHandler)
}

class TcpHandler {
    weak var delegate: TcpHandlerDelegate?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.headunitpad.tcp", qos: .userInitiated)
    private let receiveQueue = DispatchQueue(label: "com.headunitpad.tcp.receive", qos: .userInitiated)
    private var connectionTimer: DispatchWorkItem?
    private let connectionTimeout: TimeInterval = 15.0

    private(set) var isConnected = false

    private var pendingData = Data()
    private let pendingDataLock = NSLock()
    private let dataAvailableSemaphore = DispatchSemaphore(value: 0)

    init() {}

    func adoptConnection(_ preparedConnection: NWConnection, host: String, port: UInt16) {
        print("TcpHandler: adopting prepared connection for host=\(host), port=\(port)")

        disconnect()
        connection = preparedConnection
        setupStateHandler(host: host, port: port)

        isConnected = true
        DispatchQueue.main.async {
            self.delegate?.tcpHandlerDidConnect(self)
        }
        startReceiving()
    }

    func connect(host: String, port: UInt16) {
        print("TcpHandler: connect called with host=\(host), port=\(port)")

        disconnect()

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.noDelay = true

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)

        print("TcpHandler: Creating NWConnection (plain TCP) to \(endpoint)")
        connection = NWConnection(to: endpoint, using: parameters)

        setupStateHandler(host: host, port: port)

        print("TcpHandler: Starting connection...")
        connection?.start(queue: queue)
        print("TcpHandler: connection.start() called")

        startConnectionTimeout()
    }

    private func setupStateHandler(host: String, port: UInt16) {
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }

            print("TcpHandler: connection state changed to: \(String(describing: state))")

            switch state {
            case .setup:
                print("TcpHandler: state = setup")

            case .preparing:
                print("TcpHandler: state = preparing")

            case .ready:
                print("TcpHandler: state = ready, connected!")
                self.connectionTimer?.cancel()
                self.isConnected = true
                DispatchQueue.main.async {
                    self.delegate?.tcpHandlerDidConnect(self)
                }
                self.startReceiving()

            case .failed(let error):
                print("TcpHandler: state = failed, error=\(error)")
                self.connectionTimer?.cancel()
                self.isConnected = false
                DispatchQueue.main.async {
                    self.delegate?.tcpHandler(self, didFailWithError: error)
                }

            case .cancelled:
                print("TcpHandler: state = cancelled")
                self.connectionTimer?.cancel()
                self.isConnected = false
                DispatchQueue.main.async {
                    self.delegate?.tcpHandlerDidDisconnect(self)
                }

            case .waiting(let error):
                print("TcpHandler: state = waiting, error=\(error)")

            @unknown default:
                print("TcpHandler: state = unknown")
            }
        }
    }

    private func startConnectionTimeout() {
        let timer = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if !self.isConnected {
                print("TcpHandler: Connection timeout after \(self.connectionTimeout)s")
                DispatchQueue.main.async {
                    self.delegate?.tcpHandler(self, didFailWithError: TcpHandlerError.timeout)
                }
                self.disconnect()
            }
        }
        connectionTimer = timer
        queue.asyncAfter(deadline: .now() + connectionTimeout, execute: timer)
    }

    func disconnect() {
        print("TcpHandler: disconnect called")
        connectionTimer?.cancel()
        connectionTimer = nil
        connection?.cancel()
        connection = nil
        isConnected = false
    }

    func send(_ data: Data, completion: ((Error?) -> Void)? = nil) {
        guard let connection = connection, isConnected else {
            print("TcpHandler: send called but not connected")
            completion?(TcpHandlerError.invalidState)
            return
        }

        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("TcpHandler: send error: \(error)")
            }
            completion?(error)
        })
    }

    func send(_ data: Data) {
        send(data, completion: nil)
    }

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                self.receiveQueue.async {
                    self.delegate?.tcpHandler(self, didReceiveData: data)
                }
            }

            if let error = error {
                print("TcpHandler: receive error: \(error)")
                self.disconnect()
                return
            }

            if isComplete {
                print("TcpHandler: connection complete")
                self.disconnect()
                return
            }

            self.startReceiving()
        }
    }
}
