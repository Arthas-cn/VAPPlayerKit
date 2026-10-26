import UIKit
import VAPPlayerKit

/// 实验室布局与控件构造；播放状态仍集中在同一 ViewController。
extension PlaybackDetailViewController {
    /// 配置标题与报告分享入口，保持既有测试标识。
    func configureNavigation() {
        title = "Playback Lab"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = UIColor(red: 0.03, green: 0.04, blue: 0.065, alpha: 1)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"),
            style: .plain,
            target: self,
            action: #selector(shareReport)
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "detail.shareReport"
    }

    /// 按职责组装实验页面的卡片布局。
    func configureHierarchy() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 16
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 14),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28)
        ])

        configurePreviewCard()
        contentStack.addArrangedSubview(makeAssetHeader())
        contentStack.addArrangedSubview(previewCard)
        contentStack.addArrangedSubview(makeOptionsCard())
        contentStack.addArrangedSubview(makeGiftSwitcherCard())
        contentStack.addArrangedSubview(makeTextSampleCard())
        contentStack.addArrangedSubview(makeControlsCard())
        contentStack.addArrangedSubview(makeDiagnosticsCard())
    }

    /// 在棋盘背景上放置透明播放器及状态徽标。
    func configurePreviewCard() {
        previewCard.backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1)
        previewCard.layer.cornerRadius = 22
        previewCard.layer.cornerCurve = .continuous
        previewCard.clipsToBounds = true
        previewCard.heightAnchor.constraint(equalToConstant: 360).isActive = true

        let checker = CheckerboardView()
        checker.translatesAutoresizingMaskIntoConstraints = false
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.accessibilityIdentifier = "detail.player"
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.text = "IDLE"
        stateLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        stateLabel.textColor = .white
        stateLabel.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        stateLabel.layer.cornerRadius = 9
        stateLabel.clipsToBounds = true
        stateLabel.accessibilityIdentifier = "detail.state"
        previewCard.addSubview(checker)
        previewCard.addSubview(playerView)
        previewCard.addSubview(stateLabel)
        NSLayoutConstraint.activate([
            checker.topAnchor.constraint(equalTo: previewCard.topAnchor),
            checker.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor),
            checker.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor),
            checker.bottomAnchor.constraint(equalTo: previewCard.bottomAnchor),
            playerView.topAnchor.constraint(equalTo: previewCard.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: previewCard.bottomAnchor),
            stateLabel.topAnchor.constraint(equalTo: previewCard.topAnchor, constant: 12),
            stateLabel.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor, constant: 12)
        ])
    }

    /// 展示当前样本的来源和文件大小。
    func makeAssetHeader() -> UIView {
        let eyebrow = UILabel()
        eyebrow.text = fixture.looksLikeMedia ? "LOCAL MEDIA FIXTURE" : "NEGATIVE FIXTURE"
        eyebrow.font = .systemFont(ofSize: 11, weight: .bold)
        eyebrow.textColor = UIColor(red: 0.42, green: 0.82, blue: 1, alpha: 1)
        let name = UILabel()
        name.text = fixture.shortIdentifier
        name.font = .monospacedSystemFont(ofSize: 19, weight: .semibold)
        name.textColor = .white
        name.adjustsFontSizeToFitWidth = true
        let detail = UILabel()
        detail.text = "\(fixture.formattedSize) · 本地文件 · 已自动播放，可用下方控制测试"
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = UIColor(white: 0.62, alpha: 1)
        let stack = UIStackView(arrangedSubviews: [eyebrow, name, detail])
        stack.axis = .vertical
        stack.spacing = 5
        return stack
    }

    /// 构造值配置选择区，控件索引由 currentOptions 统一解释。
    func makeOptionsCard() -> UIView {
        contentModeControl.selectedSegmentIndex = 0
        loopControl.selectedSegmentIndex = 2
        audioControl.selectedSegmentIndex = 1
        backgroundControl.selectedSegmentIndex = 0
        dynamicImageControl.selectedSegmentIndex = 1
        textOverflowControl.selectedSegmentIndex = 1
        marqueeSpeedControl.selectedSegmentIndex = 2
        marqueeDelayControl.selectedSegmentIndex = 1
        clearsSwitch.isOn = true
        [
            contentModeControl,
            loopControl,
            audioControl,
            backgroundControl,
            dynamicImageControl,
            textOverflowControl,
            marqueeSpeedControl,
            marqueeDelayControl
        ].forEach {
            $0.selectedSegmentTintColor = UIColor(red: 0.15, green: 0.43, blue: 0.62, alpha: 1)
        }
        contentModeControl.accessibilityIdentifier = "detail.contentMode"
        loopControl.accessibilityIdentifier = "detail.loopCount"
        audioControl.accessibilityIdentifier = "detail.audioMode"
        backgroundControl.accessibilityIdentifier = "detail.backgroundPolicy"
        dynamicImageControl.accessibilityIdentifier = "detail.dynamicImagePlayback"
        textOverflowControl.accessibilityIdentifier = "detail.textOverflow"
        marqueeSpeedControl.accessibilityIdentifier = "detail.marqueeSpeed"
        marqueeDelayControl.accessibilityIdentifier = "detail.marqueeDelay"
        clearsSwitch.accessibilityIdentifier = "detail.clearsAfterFinish"
        dynamicImageControl.addTarget(self, action: #selector(dynamicImageModeChanged), for: .valueChanged)
        return makeCard(title: "播放参数", accessory: "切换参数需要点击播放才生效", rows: [
            makeOptionRow(title: "画布模式", control: contentModeControl),
            makeOptionRow(title: "循环次数", control: loopControl),
            makeOptionRow(title: "音频策略", control: audioControl),
            makeOptionRow(title: "离屏策略", control: backgroundControl),
            makeOptionRow(title: "槽位图片", control: dynamicImageControl),
            makeOptionRow(title: "文字溢出", control: textOverflowControl),
            makeOptionRow(title: "跑马灯速度", control: marqueeSpeedControl),
            makeOptionRow(title: "起步停顿", control: marqueeDelayControl),
            makeOptionRow(title: "结束清屏", control: clearsSwitch)
        ])
    }

    /// 构造图片样本切换区，不在 UI 布局中解析图片。
    func makeGiftSwitcherCard() -> UIView {
        previousGiftButton.configuration = giftSwitcherConfiguration("上一张", icon: "chevron.left")
        nextGiftButton.configuration = giftSwitcherConfiguration("下一张", icon: "chevron.right")
        previousGiftButton.accessibilityIdentifier = "detail.animated.previous"
        nextGiftButton.accessibilityIdentifier = "detail.animated.next"
        previousGiftButton.addTarget(self, action: #selector(previousGiftTapped), for: .touchUpInside)
        nextGiftButton.addTarget(self, action: #selector(nextGiftTapped), for: .touchUpInside)
        giftNameLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        giftNameLabel.textColor = UIColor(red: 0.54, green: 0.9, blue: 0.75, alpha: 1)
        giftNameLabel.textAlignment = .center
        giftNameLabel.lineBreakMode = .byTruncatingMiddle
        giftNameLabel.accessibilityIdentifier = "detail.animated.name"
        refreshGiftName()
        let row = UIStackView(arrangedSubviews: [previousGiftButton, giftNameLabel, nextGiftButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        giftNameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previousGiftButton.setContentHuggingPriority(.required, for: .horizontal)
        nextGiftButton.setContentHuggingPriority(.required, for: .horizontal)
        return makeCard(title: "切换图片", rows: [row])
    }

    /// 构造动态文字样本切换区。
    func makeTextSampleCard() -> UIView {
        previousTextButton.configuration = giftSwitcherConfiguration("上一组", icon: "chevron.left")
        nextTextButton.configuration = giftSwitcherConfiguration("下一组", icon: "chevron.right")
        previousTextButton.accessibilityIdentifier = "detail.text.previous"
        nextTextButton.accessibilityIdentifier = "detail.text.next"
        previousTextButton.addTarget(self, action: #selector(previousTextTapped), for: .touchUpInside)
        nextTextButton.addTarget(self, action: #selector(nextTextTapped), for: .touchUpInside)
        textSampleLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        textSampleLabel.textColor = UIColor(red: 0.54, green: 0.9, blue: 0.75, alpha: 1)
        textSampleLabel.textAlignment = .center
        textSampleLabel.lineBreakMode = .byTruncatingMiddle
        textSampleLabel.accessibilityIdentifier = "detail.text.name"
        refreshTextSampleName()
        let row = UIStackView(arrangedSubviews: [previousTextButton, textSampleLabel, nextTextButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        textSampleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previousTextButton.setContentHuggingPriority(.required, for: .horizontal)
        nextTextButton.setContentHuggingPriority(.required, for: .horizontal)
        return makeCard(title: "切换替换文字", rows: [row])
    }

    /// 生成前后样本切换按钮的相同外观。
    func giftSwitcherConfiguration(_ title: String, icon: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = UIImage(systemName: icon)
        configuration.imagePadding = 4
        configuration.cornerStyle = .medium
        configuration.baseBackgroundColor = UIColor(red: 0.12, green: 0.48, blue: 0.72, alpha: 1)
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        return configuration
    }

    /// 按当前静图或动图模式更新样本名称。
    func refreshGiftName() {
        giftNameLabel.text = usesAnimatedGift
            ? GiftCatalog.animatedGiftDisplayName(at: animatedGiftIndex)
            : GiftCatalog.stillGiftDisplayName(at: stillGiftIndex)
    }

    /// 更新当前动态文字样本的显示摘要。
    func refreshTextSampleName() {
        textSampleLabel.text = GiftCatalog.replacementSampleDisplayName(at: replacementTextIndex)
    }

    /// 保留 prepare/play/pause/resume/stop/clear 与冒烟测试入口。
    func makeControlsCard() -> UIView {
        let prepare = makeButton("Prepare", icon: "doc.text.magnifyingglass", action: #selector(prepareTapped), id: "detail.prepare")
        let play = makeButton("Play", icon: "play.fill", action: #selector(playTapped), id: "detail.play", prominent: true)
        let pause = makeButton("Pause", icon: "pause.fill", action: #selector(pauseTapped), id: "detail.pause")
        let resume = makeButton("Resume", icon: "forward.fill", action: #selector(resumeTapped), id: "detail.resume")
        let stop = makeButton("Stop", icon: "stop.fill", action: #selector(stopTapped), id: "detail.stop")
        let clear = makeButton("Clear", icon: "trash", action: #selector(clearTapped), id: "detail.clear")
        let rows = [
            makeButtonRow([prepare, play]),
            makeButtonRow([pause, resume]),
            makeButtonRow([stop, clear])
        ]
        let auto = makeButton("运行自动真机冒烟测试", icon: "checkmark.seal.fill", action: #selector(autoTestTapped), id: "detail.autoTest", prominent: true)
        return makeCard(title: "控制矩阵", rows: rows + [auto])
    }

    /// 构造元数据、指标和日志展示区。
    func makeDiagnosticsCard() -> UIView {
        metadataLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        metadataLabel.textColor = UIColor(white: 0.78, alpha: 1)
        metadataLabel.numberOfLines = 0
        metadataLabel.text = "Metadata 尚未解析"
        metadataLabel.accessibilityIdentifier = "detail.metadata"
        metricsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        metricsLabel.textColor = UIColor(red: 0.52, green: 0.91, blue: 0.73, alpha: 1)
        metricsLabel.numberOfLines = 0
        metricsLabel.text = "Decoded 0  Rendered 0  Dropped 0"
        metricsLabel.accessibilityIdentifier = "detail.metrics"
        consoleView.backgroundColor = UIColor(red: 0.025, green: 0.03, blue: 0.045, alpha: 1)
        consoleView.textColor = UIColor(white: 0.72, alpha: 1)
        consoleView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        consoleView.isEditable = false
        consoleView.layer.cornerRadius = 12
        consoleView.heightAnchor.constraint(equalToConstant: 220).isActive = true
        consoleView.accessibilityIdentifier = "detail.console"
        return makeCard(title: "实时诊断", rows: [metadataLabel, metricsLabel, consoleView])
    }

    /// 构造统一卡片容器，可附带独立提示文字。
    func makeCard(title: String, accessory: String? = nil, rows: [UIView]) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header: UIView
        // 有提示时保留独立列，避免覆盖卡片标题。
        if let accessory {
            let hintLabel = UILabel()
            hintLabel.text = accessory
            hintLabel.font = .systemFont(ofSize: 11, weight: .regular)
            hintLabel.textColor = UIColor(white: 0.52, alpha: 1)
            hintLabel.textAlignment = .right
            hintLabel.numberOfLines = 2
            hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = UIStackView(arrangedSubviews: [titleLabel, hintLabel])
            row.axis = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 8
            header = row
        } else {
            // 无提示不创建空占位，标题使用完整宽度。
            header = titleLabel
        }
        let stack = UIStackView(arrangedSubviews: [header] + rows)
        stack.axis = .vertical
        stack.spacing = 12
        let card = UIView()
        card.backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1)
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        return card
    }

    /// 将一个参数名与对应控件排列为一行。
    func makeOptionRow(title: String, control: UIView) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = UIColor(white: 0.72, alpha: 1)
        label.setContentHuggingPriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [label, control])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }

    /// 将同组控制按钮等宽排列。
    func makeButtonRow(_ buttons: [UIButton]) -> UIView {
        let row = UIStackView(arrangedSubviews: buttons)
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 10
        return row
    }

    /// 构造带既有测试定位的控制按钮，不实现辅助功能。
    func makeButton(
        _ title: String,
        icon: String,
        action: Selector,
        id: String,
        prominent: Bool = false
    ) -> UIButton {
        var configuration: UIButton.Configuration = prominent ? .filled() : .tinted()
        configuration.title = title
        configuration.image = UIImage(systemName: icon)
        configuration.imagePadding = 7
        configuration.cornerStyle = .medium
        configuration.baseBackgroundColor = UIColor(red: 0.12, green: 0.48, blue: 0.72, alpha: 1)
        configuration.baseForegroundColor = .white
        let button = UIButton(configuration: configuration)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        button.accessibilityIdentifier = id
        return button
    }
}

/// UIKit 透明背景检查视图，只服务于 Demo 预览。
final class CheckerboardView: UIView {
    /// 绘制透明度检查棋盘，不改变播放器画面。
    override func draw(_ rect: CGRect) {
        let side: CGFloat = 18
        let rows = Int(ceil(rect.height / side))
        let columns = Int(ceil(rect.width / side))
        for row in 0..<rows {
            for column in 0..<columns {
                let light = (row + column).isMultiple(of: 2)
                (light ? UIColor(white: 0.16, alpha: 1) : UIColor(white: 0.11, alpha: 1)).setFill()
                UIRectFill(CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side))
            }
        }
    }
}

/// 带固定内边距的状态徽标，不改变文字语义。
final class InsetsLabel: UILabel {
    /// 状态徽标文字的固定内边距。
    let insets = UIEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
    /// 在徽标内边距中绘制状态文本。
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    /// 将徽标内边距计入布局尺寸。
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}
