import UIKit
import UniformTypeIdentifiers
import FTCapture

/// The "Share > FieldTap" target the customer reaches from Settings > Privacy & Security > Analytics &
/// Improvements > Analytics Data. It streams the shared sysdiagnose into the App Group Inbox and tells the
/// customer to open the app, which then imports it by itself (see `AppModel.ingestSharedInbox`).
///
/// Why so little happens here: a Share Extension is capped near 120 MB of memory and a sysdiagnose is ~400 MB,
/// so the file is copied a chunk at a time and never loaded whole (`SharedInbox.streamCopy`). No decoding runs
/// in the extension, and an extension cannot launch its host app, so we do not try to — App Review rejects
/// private `openURL` tricks. The confirmation just asks the customer to open FieldTap.
final class ShareViewController: UIViewController {
    /// The UTIs a sysdiagnose_*.tar.gz advertises, most specific first. `public.data` is a last-resort match for
    /// an item that only advertises raw data; the activation rule in Info.plist stays on the specific types so
    /// FieldTap does not offer itself for every file in the share sheet.
    private static let acceptedTypes = ["org.gnu.gnu-zip-archive", "org.gnu.gnu-zip-tar-archive",
                                        "public.tar-archive", "public.data"]

    private let card = UIView()
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var didStart = false

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        Task { await run() }
    }

    private func run() async {
        do {
            guard SharedInbox.inboxURL() != nil else { throw ShareError.noAppGroup }
            _ = try await copyFirstArchive()
            finish(ok: true)
        } catch {
            finish(ok: false, message: (error as? ShareError)?.message ?? "FieldTap couldn't read that file. Share a sysdiagnose archive from Analytics Data.")
        }
    }

    /// Streams the first attachment that advertises a sysdiagnose type into the App Group Inbox and returns
    /// where it landed. The copy happens inside `loadFileRepresentation`'s handler because the temporary file it
    /// hands over is deleted the moment the handler returns. Nothing main-actor is captured in that handler.
    private func copyFirstArchive() async throws -> URL {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        guard let inbox = SharedInbox.inboxURL() else { throw ShareError.noAppGroup }
        for item in items {
            for attachment in item.attachments ?? [] {
                guard let type = Self.acceptedTypes.first(where: { attachment.hasItemConformingToTypeIdentifier($0) })
                else { continue }
                let suggested = attachment.suggestedName
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                    attachment.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                        guard let url else { continuation.resume(throwing: error ?? ShareError.notASysdiagnose); return }
                        do {
                            // Chunked, coordinated copy; memory stays flat for the ~400 MB file.
                            let name = Self.name(fromURL: url, suggested: suggested)
                            let dest = try SharedInbox.streamCopy(from: url, name: name, into: inbox)
                            continuation.resume(returning: dest)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
        throw ShareError.notASysdiagnose
    }

    /// Apple's own file name (sysdiagnose_…tar.gz); falls back to the suggested name or a timestamp.
    nonisolated private static func name(fromURL url: URL, suggested: String?) -> String {
        let candidate = url.lastPathComponent
        if candidate.hasSuffix(".tar.gz") || candidate.hasSuffix(".gz") { return candidate }
        if let suggested, suggested.hasSuffix(".tar.gz") || suggested.hasSuffix(".gz") { return suggested }
        return "sysdiagnose_\(Int(Date().timeIntervalSince1970)).tar.gz"
    }

    private func finish(ok: Bool, message: String? = nil) {
        spinner.stopAnimating()
        spinner.isHidden = true
        icon.isHidden = false
        icon.image = UIImage(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        icon.tintColor = ok ? .systemGreen : .systemOrange
        titleLabel.text = ok ? "Imported to FieldTap" : "Couldn't import"
        detailLabel.text = message ?? "Open the FieldTap app to see it."
        // Give the customer a moment to read it, then hand control back to the sharing app.
        DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 1.4 : 2.4)) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    private func buildUI() {
        view.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.001)
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
        icon.isHidden = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Saving to FieldTap…"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.text = "Streaming the sysdiagnose in."
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(card)
        [icon, spinner, titleLabel, detailLabel].forEach { card.addSubview($0) }
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            icon.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            titleLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
        ])
    }
}

private enum ShareError: Error {
    case notASysdiagnose
    case noAppGroup

    var message: String {
        switch self {
        case .notASysdiagnose: "That isn't a sysdiagnose archive. Share the newest sysdiagnose_… file from Analytics Data."
        case .noAppGroup: "FieldTap isn't set up to receive shared files on this device yet."
        }
    }
}
