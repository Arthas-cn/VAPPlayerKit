import UIKit
import VAPPlayerKit

final class ViewController: UIViewController, PlayerDelegate {
    private let playerView = PlayerView()
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        playerView.delegate = self
        playerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerView)

        statusLabel.text = "VAPPlayerKit Swift Example"
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
    }

    func playerDidStart(_ player: PlayerView) {
        statusLabel.text = "Started"
    }

    func player(_ player: PlayerView, didUpdate metadata: AssetMetadata) {
        statusLabel.text = "Metadata \(metadata.codec)"
    }

    func playerDidFinish(_ player: PlayerView, reason: FinishReason) {
        statusLabel.text = "Finished"
    }

    func player(_ player: PlayerView, didFail error: Error) {
        statusLabel.text = error.localizedDescription
    }
}
