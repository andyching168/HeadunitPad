//
//  MainViewController.swift
//  HeadunitPad
//
//  Main screen with connection controls
//

import UIKit
import AVFoundation
import CoreLocation

class MainViewController: UIViewController {

    // MARK: - Properties

    private let connectionManager = ConnectionManager()
    private let videoRenderer = H264VideoRendererView()
    private let audioPlayer = PCMAudioPlayer()
    private let locationPermissionManager = CLLocationManager()
    private var videoWatchdogTimer: Timer?
    private var runningSinceTs: TimeInterval = 0
    private var lastVideoFrameTs: TimeInterval = 0
    private var hasReceivedFirstVideoFrame = false
    private var lastVideoRecoveryTs: TimeInterval = 0

    // MARK: - UI Components

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "HeadunitPad"
        label.font = .systemFont(ofSize: 48, weight: .bold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let videoContainerView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let touchOverlayView: TouchInputView = {
        let view = TouchInputView()
        view.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.text = "Android Auto for iPad"
        label.font = .systemFont(ofSize: 20, weight: .regular)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.text = "Ready to connect"
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var connectButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Scan for Devices"
        config.cornerStyle = .large
        config.buttonSize = .large

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(connectButtonTapped), for: .touchUpInside)
        return button
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.hidesWhenStopped = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    private lazy var settingsButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "gearshape.fill")
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.35)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(settingsButtonTapped), for: .touchUpInside)
        button.isHidden = true
        return button
    }()

    private lazy var manualIPButton: UIButton = {
        var config = UIButton.Configuration.tinted()
        config.title = "Enter IP Manually"
        config.cornerStyle = .medium

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(manualIPButtonTapped), for: .touchUpInside)
        return button
    }()

    private lazy var disconnectButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Disconnect"
        config.cornerStyle = .large
        config.buttonSize = .large
        config.baseBackgroundColor = .systemRed

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(disconnectButtonTapped), for: .touchUpInside)
        button.isHidden = true
        return button
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupConstraints()
        connectionManager.delegate = self
        requestMicrophonePermissionIfNeeded()
        connectionManager.requestLocationPermissionIfNeeded()
        updateUIForConnectionState(.disconnected)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyOrientationLock()
    }

    override var shouldAutorotate: Bool {
        return false
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        switch ProjectionSettings.orientation {
        case .landscape:
            return .landscape
        case .portrait:
            return .portrait
        }
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        switch ProjectionSettings.orientation {
        case .landscape:
            return .landscapeRight
        case .portrait:
            return .portrait
        }
    }

    private func applyOrientationLock() {
        setNeedsUpdateOfSupportedInterfaceOrientations()
        touchOverlayView.isMultipleTouchEnabled = true

        let targetMask = supportedInterfaceOrientations
        if #available(iOS 16.0, *) {
            guard let scene = view.window?.windowScene else { return }
            let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: targetMask)
            scene.requestGeometryUpdate(prefs) { error in
                print("MainViewController: Failed to apply orientation lock: \(error)")
            }
        } else {
            let orientation: UIInterfaceOrientation = ProjectionSettings.orientation == .portrait ? .portrait : .landscapeRight
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    private func requestMicrophonePermissionIfNeeded() {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                print("MainViewController: Microphone permission granted=\(granted)")
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                print("MainViewController: Microphone permission granted=\(granted)")
            }
        }
    }

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = .systemBackground

        videoContainerView.addSubview(videoRenderer)
        videoContainerView.addSubview(touchOverlayView)
        videoRenderer.translatesAutoresizingMaskIntoConstraints = false
        touchOverlayView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(videoContainerView)
        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        view.addSubview(statusLabel)
        view.addSubview(connectButton)
        view.addSubview(activityIndicator)
        view.addSubview(settingsButton)
        view.addSubview(manualIPButton)
        view.addSubview(disconnectButton)

        NSLayoutConstraint.activate([
            videoRenderer.leadingAnchor.constraint(equalTo: videoContainerView.leadingAnchor),
            videoRenderer.trailingAnchor.constraint(equalTo: videoContainerView.trailingAnchor),
            videoRenderer.topAnchor.constraint(equalTo: videoContainerView.topAnchor),
            videoRenderer.bottomAnchor.constraint(equalTo: videoContainerView.bottomAnchor),

            touchOverlayView.leadingAnchor.constraint(equalTo: videoContainerView.leadingAnchor),
            touchOverlayView.trailingAnchor.constraint(equalTo: videoContainerView.trailingAnchor),
            touchOverlayView.topAnchor.constraint(equalTo: videoContainerView.topAnchor),
            touchOverlayView.bottomAnchor.constraint(equalTo: videoContainerView.bottomAnchor)
        ])

        touchOverlayView.onTouch = { [weak self] pointers, action, actionIndex in
            guard let self = self else { return }
            var mappedPointers: [(id: Int, x: Int, y: Int)] = []
            for pointer in pointers {
                let mapped = self.mapTouchPointToAa(pointer.point)
                mappedPointers.append((id: pointer.id, x: mapped.x, y: mapped.y))
            }

            if action == .DOWN || action == .UP || action == .POINTER_DOWN || action == .POINTER_UP || action == .CANCEL {
                print("MainViewController: Touch action=\(action) pointers=\(mappedPointers.count) actionIndex=\(actionIndex)")
            }

            self.connectionManager.sendTouchEvent(pointers: mappedPointers, action: action, actionIndex: actionIndex)
        }

        videoContainerView.isHidden = true
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            videoContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoContainerView.topAnchor.constraint(equalTo: view.topAnchor),
            videoContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Title
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 100),

            // Subtitle
            subtitleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),

            // Status
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 32),

            // Connect Button
            connectButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            connectButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 48),
            connectButton.widthAnchor.constraint(equalToConstant: 200),

            // Manual IP Button
            manualIPButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            manualIPButton.topAnchor.constraint(equalTo: connectButton.bottomAnchor, constant: 16),
            manualIPButton.widthAnchor.constraint(equalToConstant: 200),

            // Disconnect Button
            disconnectButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            disconnectButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 48),
            disconnectButton.widthAnchor.constraint(equalToConstant: 200),

            // Activity Indicator
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.topAnchor.constraint(equalTo: manualIPButton.bottomAnchor, constant: 32),

            // Settings Button
            settingsButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            settingsButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12)
        ])
    }

    // MARK: - UI Updates

    private func updateUIForConnectionState(_ state: ConnectionState) {
        switch state {
        case .disconnected:
            stopVideoWatchdog()
            videoContainerView.isHidden = true
            videoRenderer.reset()
            audioPlayer.reset()
            settingsButton.isHidden = false
            titleLabel.isHidden = false
            subtitleLabel.isHidden = false
            statusLabel.isHidden = false
            statusLabel.text = "Ready to connect"
            statusLabel.textColor = .tertiaryLabel
            connectButton.isHidden = false
            connectButton.isEnabled = true
            manualIPButton.isHidden = false
            disconnectButton.isHidden = true
            activityIndicator.stopAnimating()

        case .discovering:
            stopVideoWatchdog()
            videoContainerView.isHidden = true
            settingsButton.isHidden = false
            titleLabel.isHidden = false
            subtitleLabel.isHidden = false
            statusLabel.isHidden = false
            statusLabel.text = "Scanning for devices..."
            statusLabel.textColor = .secondaryLabel
            connectButton.isHidden = true
            manualIPButton.isHidden = true
            disconnectButton.isHidden = true
            activityIndicator.startAnimating()

        case .connecting:
            stopVideoWatchdog()
            videoContainerView.isHidden = true
            settingsButton.isHidden = false
            titleLabel.isHidden = false
            subtitleLabel.isHidden = false
            statusLabel.isHidden = false
            statusLabel.text = "Connecting..."
            statusLabel.textColor = .secondaryLabel
            connectButton.isHidden = true
            manualIPButton.isHidden = true
            disconnectButton.isHidden = true
            activityIndicator.startAnimating()

        case .handshaking:
            stopVideoWatchdog()
            videoContainerView.isHidden = true
            settingsButton.isHidden = false
            titleLabel.isHidden = false
            subtitleLabel.isHidden = false
            statusLabel.isHidden = false
            statusLabel.text = "Handshaking..."
            statusLabel.textColor = .systemBlue
            connectButton.isHidden = true
            manualIPButton.isHidden = true
            disconnectButton.isHidden = true
            activityIndicator.startAnimating()

        case .running:
            startVideoWatchdog()
            videoContainerView.isHidden = false
            settingsButton.isHidden = false
            titleLabel.isHidden = true
            subtitleLabel.isHidden = true
            statusLabel.isHidden = true
            statusLabel.text = "Connected to \(connectionManager.connectedDevice?.displayName ?? "device")"
            statusLabel.textColor = .systemGreen
            connectButton.isHidden = true
            manualIPButton.isHidden = true
            disconnectButton.isHidden = true
            activityIndicator.stopAnimating()

        case .error(let message):
            stopVideoWatchdog()
            videoContainerView.isHidden = true
            audioPlayer.reset()
            settingsButton.isHidden = false
            titleLabel.isHidden = false
            subtitleLabel.isHidden = false
            statusLabel.isHidden = false
            statusLabel.text = message
            statusLabel.textColor = .systemRed
            connectButton.isHidden = false
            connectButton.isEnabled = true
            manualIPButton.isHidden = false
            disconnectButton.isHidden = true
            activityIndicator.stopAnimating()
        }
    }

    private func startVideoWatchdog() {
        if videoWatchdogTimer != nil {
            return
        }

        runningSinceTs = Date().timeIntervalSince1970
        lastVideoFrameTs = 0
        hasReceivedFirstVideoFrame = false
        lastVideoRecoveryTs = 0

        videoWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkVideoWatchdog()
        }
    }

    private func stopVideoWatchdog() {
        videoWatchdogTimer?.invalidate()
        videoWatchdogTimer = nil
        runningSinceTs = 0
        lastVideoFrameTs = 0
        hasReceivedFirstVideoFrame = false
        lastVideoRecoveryTs = 0
    }

    private func checkVideoWatchdog() {
        guard connectionManager.state == .running else {
            return
        }

        let now = Date().timeIntervalSince1970
        if !hasReceivedFirstVideoFrame {
            if now - runningSinceTs > 3.0, now - lastVideoRecoveryTs > 1.5 {
                lastVideoRecoveryTs = now
                print("MainViewController: Video watchdog requesting first-frame recovery")
                connectionManager.requestVideoRecovery()
            }
            return
        }

        if now - lastVideoFrameTs > 6.0, now - lastVideoRecoveryTs > 2.0 {
            lastVideoRecoveryTs = now
            print("MainViewController: Video watchdog detected frame stall, requesting recovery")
            connectionManager.requestVideoRecovery()
        }
    }

    // MARK: - Actions

    @objc private func connectButtonTapped() {
        connectionManager.startDiscovery()
    }

    @objc private func manualIPButtonTapped() {
        let alert = UIAlertController(title: "Enter IP Address",
                                      message: "Enter the IP address of your Android phone",
                                      preferredStyle: .alert)

        alert.addTextField { textField in
            textField.placeholder = "192.168.0.189"
            textField.keyboardType = .decimalPad
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self] _ in
            guard let ip = alert.textFields?.first?.text, !ip.isEmpty else { return }
            self?.connectionManager.connect(to: ip)
        })

        present(alert, animated: true)
    }

    @objc private func disconnectButtonTapped() {
        connectionManager.disconnect()
    }

    @objc private func settingsButtonTapped() {
        presentSettingsMenu()
    }

    private func presentSettingsMenu() {
        let orientation = ProjectionSettings.orientation.title
        let resolution = ProjectionSettings.videoResolution.title(for: ProjectionSettings.orientation)
        let fps = ProjectionSettings.fpsLimit.title
        let effectiveFps = ProjectionSettings.effectiveFpsLimit.title
        let gpsSource = ProjectionSettings.gpsSource.title
        let dpi = ProjectionSettings.dpi
        let effectiveDpi = ProjectionSettings.effectiveDpi

        let alert = UIAlertController(
            title: "Projection Settings",
            message: "Changes apply on next connection.\nOrientation: \(orientation)\nResolution: \(resolution)\nFPS: \(fps)\(fps != effectiveFps ? " (effective: \(effectiveFps))" : "")\nDPI: \(dpi)\(dpi != effectiveDpi ? " (effective: \(effectiveDpi))" : "")\nGPS: \(gpsSource)",
            preferredStyle: .actionSheet
        )

        alert.addAction(UIAlertAction(title: "Orientation", style: .default) { [weak self] _ in
            self?.presentOrientationMenu()
        })

        alert.addAction(UIAlertAction(title: "Resolution", style: .default) { [weak self] _ in
            self?.presentResolutionMenu()
        })

        alert.addAction(UIAlertAction(title: "FPS", style: .default) { [weak self] _ in
            self?.presentFpsMenu()
        })

        alert.addAction(UIAlertAction(title: "DPI", style: .default) { [weak self] _ in
            self?.presentDpiMenu()
        })

        let gpsAction = UIAlertAction(title: "GPS Source", style: .default) { [weak self] _ in
            self?.presentGpsMenu()
        }
        gpsAction.isEnabled = ProjectionSettings.supportsCellularIpad()
        alert.addAction(gpsAction)

        if !ProjectionSettings.supportsCellularIpad() {
            alert.addAction(UIAlertAction(title: "GPS Source: Phone only (non-cellular iPad)", style: .default))
        }

        if connectionManager.state == .running {
            alert.addAction(UIAlertAction(title: "Connection Details", style: .default) { [weak self] _ in
                self?.presentConnectionDetails()
            })
            alert.addAction(UIAlertAction(title: "Disconnect", style: .destructive) { [weak self] _ in
                self?.connectionManager.disconnect()
            })
        }

        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        configurePopoverSource(for: alert)
        present(alert, animated: true)
    }

    private func presentResolutionMenu() {
        let alert = UIAlertController(title: "Resolution", message: nil, preferredStyle: .actionSheet)

        let orientation = ProjectionSettings.orientation
        let options = ProjectionSettings.availableResolutions(for: orientation)

        for option in options {
            let optionTitle = option.title(for: orientation)
            let title = option == ProjectionSettings.videoResolution ? "\(optionTitle) (Current)" : optionTitle
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                ProjectionSettings.videoResolution = option
                self?.presentSettingsMenu()
            })
        }

        alert.addAction(UIAlertAction(title: "Back", style: .cancel) { [weak self] _ in
            self?.presentSettingsMenu()
        })

        configurePopoverSource(for: alert)
        present(alert, animated: true)
    }

    private func presentOrientationMenu() {
        let alert = UIAlertController(title: "Orientation", message: nil, preferredStyle: .actionSheet)

        for option in [ProjectionOrientation.landscape, .portrait] {
            let title = option == ProjectionSettings.orientation ? "\(option.title) (Current)" : option.title
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                ProjectionSettings.orientation = option
                self?.applyOrientationLock()
                self?.presentSettingsMenu()
            })
        }

        alert.addAction(UIAlertAction(title: "Back", style: .cancel) { [weak self] _ in
            self?.presentSettingsMenu()
        })

        configurePopoverSource(for: alert)
        present(alert, animated: true)
    }

    private func presentFpsMenu() {
        let alert = UIAlertController(title: "FPS", message: nil, preferredStyle: .actionSheet)

        for option in [ProjectionFpsLimit.fps30, .fps60] {
            let title = option == ProjectionSettings.fpsLimit ? "\(option.title) (Current)" : option.title
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                ProjectionSettings.fpsLimit = option
                self?.presentSettingsMenu()
            })
        }

        alert.addAction(UIAlertAction(title: "Back", style: .cancel) { [weak self] _ in
            self?.presentSettingsMenu()
        })

        configurePopoverSource(for: alert)
        present(alert, animated: true)
    }

    private func presentDpiMenu() {
        let alert = UIAlertController(
            title: "DPI",
            message: "Enter custom DPI (\(ProjectionSettings.minDpi)-\(ProjectionSettings.maxDpi)).",
            preferredStyle: .alert
        )

        alert.addTextField { textField in
            textField.keyboardType = .numberPad
            textField.placeholder = "\(ProjectionSettings.defaultDpi)"
            textField.text = "\(ProjectionSettings.dpi)"
        }

        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let raw = alert?.textFields?.first?.text,
                  let value = Int(raw) else {
                self?.presentSettingsMenu()
                return
            }

            ProjectionSettings.dpi = value
            self?.presentSettingsMenu()
        })

        alert.addAction(UIAlertAction(title: "Reset Default", style: .destructive) { [weak self] _ in
            ProjectionSettings.resetDpiToDefault()
            self?.presentSettingsMenu()
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.presentSettingsMenu()
        })

        present(alert, animated: true)
    }

    private func presentGpsMenu() {
        let alert = UIAlertController(title: "GPS Source", message: nil, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: ProjectionGpsSource.phone == ProjectionSettings.gpsSource ? "Use Phone GPS (Current)" : "Use Phone GPS", style: .default) { [weak self] _ in
            ProjectionSettings.gpsSource = .phone
            self?.presentSettingsMenu()
        })

        let ipadActionTitle = ProjectionGpsSource.ipad == ProjectionSettings.gpsSource ? "Use iPad GPS (Current)" : "Use iPad GPS"
        let ipadAction = UIAlertAction(title: ipadActionTitle, style: .default) { [weak self] _ in
            ProjectionSettings.gpsSource = .ipad
            self?.locationPermissionManager.requestWhenInUseAuthorization()
            self?.connectionManager.requestLocationPermissionIfNeeded()
            self?.presentSettingsMenu()
        }
        ipadAction.isEnabled = ProjectionSettings.supportsCellularIpad()
        alert.addAction(ipadAction)

        alert.addAction(UIAlertAction(title: "Back", style: .cancel) { [weak self] _ in
            self?.presentSettingsMenu()
        })

        configurePopoverSource(for: alert)
        present(alert, animated: true)
    }

    private func presentConnectionDetails() {
        let device = connectionManager.connectedDevice
        let details = [
            "State: \(connectionManager.state.description)",
            "Device: \(device?.displayName ?? "Unknown")",
            "IP: \(device?.ip ?? "Unknown")",
            "Port: \(device?.port ?? 0)"
        ].joined(separator: "\n")

        let alert = UIAlertController(title: "Connection", message: details, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        present(alert, animated: true)
    }

    private func configurePopoverSource(for alert: UIAlertController) {
        if let popover = alert.popoverPresentationController {
            popover.sourceView = settingsButton
            popover.sourceRect = settingsButton.bounds
            popover.permittedArrowDirections = [.up, .down]
        }
    }

    private func mapTouchPointToAa(_ point: CGPoint) -> (x: Int, y: Int) {
        let targetSize = ProjectionSettings.effectiveVideoDimensions
        let width = max(touchOverlayView.bounds.width, 1)
        let height = max(touchOverlayView.bounds.height, 1)

        // Match AVSampleBufferDisplayLayer.resizeAspect: map only inside active video rect.
        let targetAspect = CGFloat(targetSize.width) / CGFloat(targetSize.height)
        let viewAspect = width / height

        let activeRect: CGRect
        if viewAspect > targetAspect {
            let contentWidth = height * targetAspect
            let x = (width - contentWidth) / 2
            activeRect = CGRect(x: x, y: 0, width: contentWidth, height: height)
        } else {
            let contentHeight = width / targetAspect
            let y = (height - contentHeight) / 2
            activeRect = CGRect(x: 0, y: y, width: width, height: contentHeight)
        }

        let clampedX = min(max(point.x, activeRect.minX), activeRect.maxX)
        let clampedY = min(max(point.y, activeRect.minY), activeRect.maxY)

        let nx = (clampedX - activeRect.minX) / activeRect.width
        let ny = (clampedY - activeRect.minY) / activeRect.height

        let x = Int(nx * CGFloat(targetSize.width - 1))
        let y = Int(ny * CGFloat(targetSize.height - 1))
        return (x, y)
    }
}

// MARK: - ConnectionManagerDelegate

extension MainViewController: ConnectionManagerDelegate {
    func connectionManager(_ manager: ConnectionManager, didChangeState state: ConnectionState) {
        updateUIForConnectionState(state)
    }

    func connectionManager(_ manager: ConnectionManager, didDiscoverDevice device: DiscoveredDevice) {
        if manager.discoveredDevices.count == 1 {
            statusLabel.text = "Found: \(device.displayName)"
            statusLabel.textColor = .systemBlue
        }

        let alert = UIAlertController(title: "Device Found",
                                      message: "Would you like to connect to \(device.displayName)?",
                                      preferredStyle: .alert)

        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self] _ in
            self?.connectionManager.connect(to: device)
        })

        alert.addAction(UIAlertAction(title: "Continue Scanning", style: .cancel))

        present(alert, animated: true)
    }

    func connectionManager(_ manager: ConnectionManager, didReceiveVideoData data: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.hasReceivedFirstVideoFrame = true
            self.lastVideoFrameTs = Date().timeIntervalSince1970
            self.videoRenderer.enqueueAnnexBFrame(data)
        }
    }

    func connectionManager(_ manager: ConnectionManager, didReceiveAudioData data: Data, on channel: UInt8) {
        audioPlayer.playPCM(data, on: channel)
    }
}
