import UIKit

/// The composer's attach button: a circle that opens a menu, and shows a
/// spinner while picked files are prepared. What differs between iOS and the
/// Mac is kept here, so the bar needs no `#if` for it.
final class AttachControl: UIView {
    private let button: UIButton
    #if targetEnvironment(macCatalyst)
    /// What the Mac shows in place of the button's own symbol and spinner.
    private let symbol = UIImageView(image: UIImage(systemName: "plus"))
    private let spinner = UIActivityIndicatorView(style: .medium)
    #endif

    init(menu: UIMenu, size: CGFloat) {
        let button: UIButton
        if #available(iOS 26, *) {
            button = UIButton(configuration: .glass())
        } else {
            button = UIButton(configuration: .plain())
        }
        button.configuration?.image = UIImage(systemName: "plus")
        button.configuration?.baseForegroundColor = .label
        button.configuration?.cornerStyle = .capsule
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = String(localized: "Attach")
        button.isPointerInteractionEnabled = true
        // The Mac would draw its own push and pull-down buttons, which
        // don't match the field.
        button.preferredBehavioralStyle = .pad
        self.button = button
        super.init(frame: .zero)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
        install(button, size: size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A spinner in place of the symbol while picked files are prepared.
    func setPreparing(_ preparing: Bool) {
        #if targetEnvironment(macCatalyst)
        symbol.isHidden = preparing
        if preparing { spinner.startAnimating() } else { spinner.stopAnimating() }
        #else
        button.configuration?.showsActivityIndicator = preparing
        #endif
    }

    private func install(_ button: UIButton, size: CGFloat) {
        button.translatesAutoresizingMaskIntoConstraints = false
        #if targetEnvironment(macCatalyst)
        let background: UIView
        let contentView: UIView
        if #available(iOS 26, *) {
            let effectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
            effectView.cornerConfiguration = .uniformCorners(radius: .fixed(size / 2))
            background = effectView
            contentView = effectView.contentView
        } else {
            background = UIView()
            background.backgroundColor = .tertiarySystemFill
            background.layer.cornerRadius = size / 2
            contentView = background
        }
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        symbol.tintColor = .label
        for view in [symbol, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: background.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            ])
        }
        // Only the Mac's own pull-down opens its menu on click there, but
        // it draws a square behind it whatever its style, so it's kept
        // just visible enough to take clicks over a circle of our own.
        button.preferredBehavioralStyle = .mac
        button.alpha = 0.02
        contentView.addSubview(button)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: size),
            button.heightAnchor.constraint(equalToConstant: size),
        ])
        #else
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        #endif
    }
}
