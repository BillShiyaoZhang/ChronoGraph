import SwiftUI

/// Ship the same policy as the public URLs so it remains readable offline and before registration.
enum PrivacyPolicyDocument {
    static func text(languageCode: String, bundle: Bundle = .main) -> String? {
        let name = languageCode.lowercased().hasPrefix("zh") ? "隐私政策" : "privacy-policy"
        guard let url = bundle.url(forResource: name, withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

struct PrivacyPolicyView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let policy = PrivacyPolicyDocument.text(languageCode: locale.identifier) {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(policy.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                            policyParagraph(paragraph)
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .textSelection(.enabled)
                } else {
                    // Keep a visible recovery path if packaging is ever broken.
                    ContentUnavailableView {
                        Label("settings.privacyPolicy", systemImage: "doc.text")
                    } actions: {
                        Link("settings.privacyPolicy", destination: URL(string: "https://github.com/BillShiyaoZhang/ChronoGraph/blob/main/privacy-policy.md")!)
                    }
                }
            }
            .accessibilityIdentifier("privacy.policy.content")
            .navigationTitle("settings.privacyPolicy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                        .accessibilityIdentifier("privacy.policy.done")
                }
            }
        }
    }

    @ViewBuilder private func policyParagraph(_ paragraph: String) -> some View {
        if paragraph.hasPrefix("# ") {
            Text(String(paragraph.dropFirst(2))).font(.title.bold()).accessibilityAddTraits(.isHeader)
        } else if paragraph.hasPrefix("## ") {
            Text(String(paragraph.dropFirst(3))).font(.title2.bold()).accessibilityAddTraits(.isHeader)
        } else if paragraph.hasPrefix("|") {
            // Present the policy's visibility table as readable, wrapping rows at every text size.
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(paragraph.components(separatedBy: "\n").enumerated()), id: \.offset) { _, row in
                    let cells = row.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    if cells.count == 2 && !cells[0].hasPrefix("---") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cells[0]).fontWeight(.semibold)
                            Text(cells[1])
                        }
                    }
                }
            }
        } else {
            Text(LocalizedStringKey(paragraph))
        }
    }
}
