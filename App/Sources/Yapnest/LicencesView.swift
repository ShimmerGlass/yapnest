import SwiftUI

/// The libraries the app ships and their licences, from the folder
/// `dev/licences.py` writes into the bundle.
struct OpenSourceLicences: Decodable, Sendable {
    struct Own: Decodable, Sendable {
        let license: String
        let file: String
    }

    struct Library: Decodable, Identifiable, Sendable {
        let id: String
        let name: String
        let version: String
        let license: String
        let url: URL
        let file: String
        let modified: Bool
        let note: String?
    }

    let yapnest: Own
    let libraries: [Library]

    static let folderName = "Licences"

    static func folder(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: folderName, withExtension: nil)
    }

    static func load(from bundle: Bundle = .main) -> OpenSourceLicences? {
        guard let data = folder(in: bundle).flatMap({ try? Data(contentsOf: $0.appending(path: "manifest.json")) }) else { return nil }
        return try? JSONDecoder().decode(OpenSourceLicences.self, from: data)
    }

    static func text(of file: String, in bundle: Bundle = .main) -> String? {
        folder(in: bundle).flatMap { try? String(contentsOf: $0.appending(path: file), encoding: .utf8) }
    }
}

/// Under Settings: says Yapnest is free software, then lists the libraries
/// it is built on.
struct LicencesView: View {
    private static let licences = OpenSourceLicences.load()
    #if DEBUG
    /// From `YAPNEST_DEV_SETTINGS=licences:<library id>`, for screenshots.
    @State private var devLibrary = ProcessInfo.processInfo.environment["YAPNEST_DEV_SETTINGS"]
        .flatMap { $0.split(separator: ":").dropFirst().first }.map(String.init)
    #endif

    var body: some View {
        Form {
            Section {
                Text("Yapnest is free software, released under the GNU Affero General Public License, version 3 or later. You can read, change and share its source code.")
                if let url = AppLinks.sourceCode {
                    Link(destination: url) { Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                }
                if let own = Self.licences?.yapnest {
                    NavigationLink("Yapnest") {
                        LicenceTextView(title: "Yapnest", file: own.file)
                    }
                }
            }

            if let libraries = Self.licences?.libraries {
                Section {
                    ForEach(libraries) { library in
                        NavigationLink {
                            LicenceTextView(title: library.name, file: library.file, library: library)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(library.name)
                                Text(subtitle(of: library))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Libraries")
                } footer: {
                    Text("Martin and MartinOMEMO are modified copies. Vendor/README.md in the source lists what changed.")
                }
            } else {
                Section {
                    Text("The licence list couldn't be loaded.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Licences")
        .navigationBarTitleDisplayMode(.inline)
        .sheetDoneButton()
        #if DEBUG
        .navigationDestination(item: $devLibrary) { id in
            if let library = Self.licences?.libraries.first(where: { $0.id == id }) {
                LicenceTextView(title: library.name, file: library.file, library: library)
            }
        }
        #endif
    }

    private func subtitle(of library: OpenSourceLicences.Library) -> String {
        [library.version.isEmpty ? library.note : library.version, library.license]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// One licence's full text, to scroll and select.
struct LicenceTextView: View {
    let title: String
    let file: String
    var library: OpenSourceLicences.Library?

    @State private var text: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let library {
                    if library.modified {
                        Text("Yapnest uses a modified copy of \(library.name).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Link(library.url.absoluteString, destination: library.url)
                        .font(.footnote)
                }
                Text(text ?? String(localized: "The licence text couldn't be loaded."))
                    .font(.footnote)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheetDoneButton()
        .task { text = await offMain { [file] in OpenSourceLicences.text(of: file).map(Self.reflowed) } }
    }

    /// Licence files are hard-wrapped at about 80 columns, which wraps again
    /// on a phone. Paragraphs of plain lines are joined; indented ones (titles,
    /// lists) keep their breaks.
    private nonisolated static func reflowed(_ text: String) -> String {
        text.components(separatedBy: "\n\n").map { paragraph in
            let lines = paragraph.components(separatedBy: "\n")
            let isPlain = lines.dropFirst().allSatisfy { !$0.hasPrefix("  ") && !$0.hasPrefix("\t") }
            guard isPlain else { return paragraph }
            return lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }.joined(separator: "\n\n")
    }
}
