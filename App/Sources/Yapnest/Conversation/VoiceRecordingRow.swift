import UIKit
import YapnestKit

/// What the composer's field shows while a voice message is recorded: a red
/// dot, the time so far, the loudness as it passes, and either how to cancel
/// (while the button is held) or a cancel button (once it is locked).
final class VoiceRecordingRow: UIView {
    private let dot = UIView()
    private let timeLabel = UILabel()
    private let meter = LevelMeterView()
    private let hint = UILabel()
    private let cancelButton = UIButton(configuration: .plain())

    var onCancel: (() -> Void)?
    /// The whole second and the half second shown, so the label and the dot
    /// change only when what they show does.
    private var shownSeconds = 0
    private var shownHalves = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        dot.backgroundColor = .systemRed
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
        timeLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.text = AudioFormat.clock(0)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        hint.font = .preferredFont(forTextStyle: .subheadline)
        hint.adjustsFontForContentSizeCategory = true
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.adjustsFontSizeToFitWidth = true
        hint.minimumScaleFactor = 0.7
        cancelButton.configuration?.title = String(localized: "Cancel")
        cancelButton.accessibilityLabel = String(localized: "Cancel recording")
        cancelButton.configuration?.baseForegroundColor = .systemRed
        cancelButton.preferredBehavioralStyle = .pad
        cancelButton.isPointerInteractionEnabled = true
        cancelButton.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .primaryActionTriggered)
        cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [dot, timeLabel, meter, hint, cancelButton])
        stack.spacing = 8
        stack.alignment = .center
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            meter.heightAnchor.constraint(equalToConstant: 24),
        ])
        isAccessibilityElement = false
        timeLabel.accessibilityLabel = String(localized: "Recording")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(phase: VoiceRecorder.Phase, willCancel: Bool) {
        let locked = phase == .locked
        hint.isHidden = locked
        cancelButton.isHidden = !locked
        hint.text = willCancel ? String(localized: "Release to cancel") : String(localized: "‹ Slide to cancel")
        hint.textColor = willCancel ? .systemRed : .secondaryLabel
        if phase == .idle || phase == .starting {
            meter.reset()
            shownSeconds = 0
            shownHalves = 0
            timeLabel.text = AudioFormat.clock(0)
            dot.alpha = 1
        }
    }

    /// One tick of the clock.
    func update(elapsed: TimeInterval, level: Float) {
        meter.push(level)
        if Int(elapsed) != shownSeconds {
            shownSeconds = Int(elapsed)
            timeLabel.text = AudioFormat.clock(elapsed)
            timeLabel.accessibilityValue = timeLabel.text
        }
        if Int(elapsed * 2) != shownHalves {
            shownHalves = Int(elapsed * 2)
            dot.alpha = shownHalves.isMultiple(of: 2) ? 1 : 0.35
        }
    }
}

/// A row of bars, newest at the trailing edge, scrolling as levels arrive.
final class LevelMeterView: UIView {
    private var levels: [Float] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 40, height: UIView.noIntrinsicMetric)
    }

    func push(_ level: Float) {
        let capacity = BarGeometry.capacity(in: bounds.width)
        levels.append(level)
        if levels.count > capacity { levels.removeFirst(levels.count - capacity) }
        setNeedsDisplay()
    }

    func reset() {
        levels.removeAll()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        UIColor.secondaryLabel.setFill()
        // Newest at the trailing edge, whichever way the layout runs.
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        for (offset, level) in levels.reversed().enumerated() {
            let x = rightToLeft ? CGFloat(offset) * BarGeometry.step : bounds.width - CGFloat(offset + 1) * BarGeometry.step + BarGeometry.gap
            guard x >= -BarGeometry.width, x <= bounds.width else { continue }
            UIBezierPath(roundedRect: BarGeometry.rect(x: x, level: Double(level), in: bounds.height), cornerRadius: BarGeometry.width / 2).fill()
        }
    }
}

/// The bars of the recording's level meter and of a voice message's outline.
enum BarGeometry {
    static let width: CGFloat = 3
    static let gap: CGFloat = 2
    static var step: CGFloat { width + gap }

    /// How many bars fit in `width`.
    static func capacity(in width: CGFloat) -> Int {
        max(1, Int((width + gap) / step))
    }

    /// A bar at `x`, `level` (0...1) of `height` tall and centred in it.
    static func rect(x: CGFloat, level: Double, in height: CGFloat) -> CGRect {
        let barHeight = max(width, height * CGFloat(level))
        return CGRect(x: x, y: (height - barHeight) / 2, width: width, height: barHeight)
    }
}

/// The microphone button. A touch is read by a gesture recognizer so that it
/// can follow the finger; VoiceOver activates the button instead, which
/// starts a recording that stays on.
final class MicButton: UIButton {
    var onAccessibilityActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        onAccessibilityActivate?()
        return onAccessibilityActivate != nil
    }
}
