import UIKit

final class VideoOnlyViewController: UIViewController {
    private let videoRenderer = H264VideoRendererView()
    private var frameSubscriptionId: UUID?
    private var cursorSubscriptionId: UUID?
    private let cursorView: UIView = {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 18, height: 18))
        view.backgroundColor = .systemBlue
        view.layer.cornerRadius = 9
        view.layer.borderColor = UIColor.white.cgColor
        view.layer.borderWidth = 2
        view.isUserInteractionEnabled = false
        return view
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        videoRenderer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoRenderer)

        NSLayoutConstraint.activate([
            videoRenderer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoRenderer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoRenderer.topAnchor.constraint(equalTo: view.topAnchor),
            videoRenderer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        view.addSubview(cursorView)

        frameSubscriptionId = VideoFrameBus.shared.subscribe { [weak self] frame in
            self?.videoRenderer.enqueueAnnexBFrame(frame)
        }

        cursorSubscriptionId = TrackpadInputBridge.shared.subscribeCursor { [weak self] cursorNorm in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let width = max(self.view.bounds.width, 1)
                let height = max(self.view.bounds.height, 1)
                self.cursorView.center = CGPoint(x: cursorNorm.x * width, y: cursorNorm.y * height)
            }
        }
    }

    deinit {
        if let frameSubscriptionId {
            VideoFrameBus.shared.unsubscribe(frameSubscriptionId)
        }
        if let cursorSubscriptionId {
            TrackpadInputBridge.shared.unsubscribeCursor(cursorSubscriptionId)
        }
    }
}
