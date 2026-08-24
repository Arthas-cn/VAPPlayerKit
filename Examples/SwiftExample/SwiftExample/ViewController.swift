import UIKit

/// 自动扫描 Bundle/VAP 的资源浏览器。每个文件对应一行，点击进入完整播放器实验室。
final class ViewController: UIViewController {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let searchController = UISearchController(searchResultsController: nil)
    private var fixtures: [VAPFixture] = []
    private var filteredFixtures: [VAPFixture] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        configureAppearance()
        configureTableView()
        configureSearch()
        reloadFixtures()
    }

    private func configureAppearance() {
        title = "VAP Gallery"
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationController?.navigationBar.tintColor = UIColor(red: 0.47, green: 0.84, blue: 1, alpha: 1)
        view.backgroundColor = UIColor(red: 0.035, green: 0.045, blue: 0.075, alpha: 1)
        let reload = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            style: .plain,
            target: self,
            action: #selector(reloadFixtures)
        )
        reload.accessibilityIdentifier = "catalog.reload"
        let batch = UIBarButtonItem(
            image: UIImage(systemName: "checkmark.seal"),
            style: .plain,
            target: self,
            action: #selector(runBatchTest)
        )
        batch.accessibilityIdentifier = "catalog.batchTest"
        navigationItem.rightBarButtonItems = [reload, batch]
    }

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = 104
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(FixtureCell.self, forCellReuseIdentifier: FixtureCell.reuseIdentifier)
        tableView.accessibilityIdentifier = "catalog.list"
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureSearch() {
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "搜索文件 Hash"
        searchController.searchResultsUpdater = self
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    @objc private func reloadFixtures() {
        fixtures = FixtureCatalog.scan()
        tableView.accessibilityValue = fixtures.map(\.identifier).joined(separator: ",")
        applyFilter(searchController.searchBar.text)
    }

    @objc private func runBatchTest() {
        navigationController?.pushViewController(BatchTestViewController(fixtures: fixtures), animated: true)
    }

    private func applyFilter(_ query: String?) {
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        filteredFixtures = query.isEmpty
            ? fixtures
            : fixtures.filter { $0.fileName.localizedCaseInsensitiveContains(query) }
        tableView.reloadData()
        updateBackground()
    }

    private func updateBackground() {
        guard filteredFixtures.isEmpty else {
            tableView.backgroundView = nil
            return
        }
        let label = UILabel()
        label.text = fixtures.isEmpty
            ? "未在 App Bundle/VAP 中发现 MP4\n请检查 Copy Bundle Resources"
            : "没有匹配的资源"
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.accessibilityIdentifier = "catalog.empty"
        tableView.backgroundView = label
    }
}

extension ViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        filteredFixtures.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "已扫描 \(fixtures.count) 个资源 · 当前显示 \(filteredFixtures.count) 个"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: FixtureCell.reuseIdentifier, for: indexPath)
        guard let cell = cell as? FixtureCell else { return cell }
        let fixture = filteredFixtures[indexPath.row]
        cell.configure(with: fixture, index: fixtures.firstIndex(of: fixture) ?? indexPath.row)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(
            PlaybackDetailViewController(fixture: filteredFixtures[indexPath.row]),
            animated: true
        )
    }
}

extension ViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        applyFilter(searchController.searchBar.text)
    }
}

private final class FixtureCell: UITableViewCell {
    static let reuseIdentifier = "FixtureCell"

    private let card = UIView()
    private let indexLabel = UILabel()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let sizeLabel = PaddingLabel()
    private let stateImage = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(red: 0.075, green: 0.09, blue: 0.14, alpha: 1)
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        contentView.addSubview(card)

        indexLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        indexLabel.textColor = UIColor(red: 0.42, green: 0.82, blue: 1, alpha: 1)
        indexLabel.textAlignment = .center
        indexLabel.backgroundColor = UIColor(red: 0.11, green: 0.22, blue: 0.31, alpha: 1)
        indexLabel.layer.cornerRadius = 14
        indexLabel.clipsToBounds = true

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = UIColor(white: 0.62, alpha: 1)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        sizeLabel.textColor = UIColor(red: 0.54, green: 0.9, blue: 0.75, alpha: 1)
        sizeLabel.backgroundColor = UIColor(red: 0.08, green: 0.22, blue: 0.17, alpha: 1)
        sizeLabel.layer.cornerRadius = 8
        sizeLabel.clipsToBounds = true

        stateImage.image = UIImage(systemName: "chevron.right")
        stateImage.tintColor = UIColor(white: 0.45, alpha: 1)

        [indexLabel, titleLabel, subtitleLabel, sizeLabel, stateImage].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview($0)
        }
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            indexLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            indexLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            indexLabel.widthAnchor.constraint(equalToConstant: 48),
            indexLabel.heightAnchor.constraint(equalToConstant: 48),
            titleLabel.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 17),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: stateImage.leadingAnchor, constant: -10),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: stateImage.leadingAnchor, constant: -10),
            sizeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            sizeLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 7),
            sizeLabel.heightAnchor.constraint(equalToConstant: 20),
            stateImage.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stateImage.centerYAnchor.constraint(equalTo: card.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with fixture: VAPFixture, index: Int) {
        indexLabel.text = String(format: "%02d", index + 1)
        titleLabel.text = fixture.looksLikeMedia ? "VAP 动画资源" : "损坏资源（负向样例）"
        subtitleLabel.text = fixture.shortIdentifier
        sizeLabel.text = "  \(fixture.formattedSize)  "
        accessibilityIdentifier = "catalog.item.\(index)"
        accessibilityLabel = "资源 \(index + 1)，\(fixture.formattedSize)，\(fixture.shortIdentifier)"
    }
}

private final class PaddingLabel: UILabel {
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 12, height: size.height + 4)
    }
}
