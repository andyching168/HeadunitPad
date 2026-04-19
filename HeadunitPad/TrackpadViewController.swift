import UIKit

final class TrackpadViewController: UIViewController {
    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "Trackpad Mode"
        label.font = .systemFont(ofSize: 28, weight: .bold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let hintLabel: UILabel = {
        let label = UILabel()
        label.text = "Single-finger drag to move cursor\nTap to click\nTap once, then hold-and-drag\nTwo-finger pinch to zoom"
        label.numberOfLines = 4
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var settingsButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "slider.horizontal.3")
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.35)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(showSettingsMenu), for: .touchUpInside)
        return button
    }()

    private let trackpadArea: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.systemGray6
        view.layer.cornerRadius = 18
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.systemGray3.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let cursorView: UIView = {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
        view.backgroundColor = .systemBlue
        view.layer.cornerRadius = 8
        view.layer.borderColor = UIColor.white.cgColor
        view.layer.borderWidth = 2
        view.isUserInteractionEnabled = false
        return view
    }()

    private var cursorSubscriptionId: UUID?
    private var lastDragLocation: CGPoint?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        view.addSubview(titleLabel)
        view.addSubview(hintLabel)
        view.addSubview(trackpadArea)
        view.addSubview(settingsButton)
        trackpadArea.addSubview(cursorView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            hintLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            trackpadArea.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 20),
            trackpadArea.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            trackpadArea.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            trackpadArea.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),

            settingsButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            settingsButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10)
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        trackpadArea.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTouchesRequired = 1
        tap.numberOfTapsRequired = 1
        trackpadArea.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        trackpadArea.addGestureRecognizer(pinch)

        let doubleTapDrag = UILongPressGestureRecognizer(target: self, action: #selector(handleDoubleTapDrag(_:)))
        // One completed tap, then the next press begins drag immediately.
        doubleTapDrag.numberOfTapsRequired = 1
        doubleTapDrag.minimumPressDuration = 0
        doubleTapDrag.allowableMovement = 120
        trackpadArea.addGestureRecognizer(doubleTapDrag)

        cursorSubscriptionId = TrackpadInputBridge.shared.subscribeCursor { [weak self] cursorNorm in
            DispatchQueue.main.async {
                self?.updateCursor(cursorNorm)
            }
        }
    }

    deinit {
        if let cursorSubscriptionId {
            TrackpadInputBridge.shared.unsubscribeCursor(cursorSubscriptionId)
        }
    }

    private func updateCursor(_ normalized: CGPoint) {
        let width = max(trackpadArea.bounds.width, 1)
        let height = max(trackpadArea.bounds.height, 1)
        cursorView.center = CGPoint(x: normalized.x * width, y: normalized.y * height)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        if TrackpadInputBridge.shared.isDoubleTapDragActive() {
            return
        }
        let delta = gesture.translation(in: trackpadArea)
        gesture.setTranslation(.zero, in: trackpadArea)
        TrackpadInputBridge.shared.moveCursor(delta: delta, in: trackpadArea.bounds.size)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        TrackpadInputBridge.shared.tap()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            TrackpadInputBridge.shared.beginPinch()
        case .changed:
            TrackpadInputBridge.shared.updatePinch(scale: gesture.scale)
        case .ended, .cancelled, .failed:
            TrackpadInputBridge.shared.endPinch()
            gesture.scale = 1
        default:
            break
        }
    }

    @objc private func handleDoubleTapDrag(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            lastDragLocation = gesture.location(in: trackpadArea)
            TrackpadInputBridge.shared.beginDoubleTapDrag()
        case .changed:
            let current = gesture.location(in: trackpadArea)
            let previous = lastDragLocation ?? current
            let delta = CGPoint(x: current.x - previous.x, y: current.y - previous.y)
            lastDragLocation = current
            TrackpadInputBridge.shared.moveCursor(delta: delta, in: trackpadArea.bounds.size)
        case .ended, .cancelled, .failed:
            lastDragLocation = nil
            TrackpadInputBridge.shared.endDoubleTapDrag()
        default:
            break
        }
    }

    @objc private func showSettingsMenu() {
        let alert = UIAlertController(title: "Trackpad Settings", message: nil, preferredStyle: .actionSheet)
        let current = TrackpadInputBridge.shared.getCursorSpeed()
        let presets: [(title: String, value: CGFloat)] = [
            ("Slow (0.6x)", 0.6),
            ("Normal (1.0x)", 1.0),
            ("Fast (1.4x)", 1.4),
            ("Very Fast (1.8x)", 1.8)
        ]

        for preset in presets {
            let isCurrent = abs(current - preset.value) < 0.05
            let title = isCurrent ? "\(preset.title) (Current)" : preset.title
            alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                TrackpadInputBridge.shared.setCursorSpeed(preset.value)
            })
        }

        alert.addAction(UIAlertAction(title: "Close", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = settingsButton
            popover.sourceRect = settingsButton.bounds
            popover.permittedArrowDirections = [.up, .down]
        }

        present(alert, animated: true)
    }
}
