import UIKit
import VAPPlayerKit

/// Swift 示例：从 App Bundle 的 `VAP/` 目录加载仓库内提交的样例资源。
final class ViewController: UIViewController, PlayerDelegate {
    /// 与 `Tests/Fixtures/README.md` 中的默认 Demo 文件一致。
    private static let defaultFixtureName = "e9b6b7196780ea5f64b9f05034571f12a96787278ed678c83141c7913af7318a"

    private let playerView = PlayerView()
    private let statusLabel = UILabel()
    private let playButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        playerView.delegate = self
        playerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerView)

        statusLabel.text = "VAPPlayerKit Swift Example"
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        playButton.setTitle("Play Fixture", for: .normal)
        playButton.addTarget(self, action: #selector(playFixture), for: .touchUpInside)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playButton)

        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: playButton.topAnchor, constant: -16),
            playButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playButton.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
    }

    @objc private func playFixture() {
        guard let url = Bundle.main.url(
            forResource: Self.defaultFixtureName,
            withExtension: "mp4",
            subdirectory: "VAP"
        ) else {
            statusLabel.text = "Missing Tests/Fixtures/VAP in app bundle"
            return
        }
        statusLabel.text = url.lastPathComponent
        playerView.play(url: url, options: .defaultOptions)
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
