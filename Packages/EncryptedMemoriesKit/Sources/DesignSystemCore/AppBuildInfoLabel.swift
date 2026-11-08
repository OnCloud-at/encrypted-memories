import PhotosCore
import SwiftUI

struct SettingsFooterContent {
    enum Item: Equatable {
        case link(String, URL)
        case text(String)
    }

    let items: [Item]

    init(info: AppBuildInfo) {
        var items: [Item] = [.link(info.localizedVersion, info.releaseURL)]
        if let commit = info.shortCommit, let url = info.commitURL {
            items.append(.link(commit, url))
        }
        items.append(.text(ProductBrand.madeInAustria))
        self.items = items
    }
}

/// The version, source commit, and attribution shared by the Settings screens.
public struct AppBuildInfoLabel: View {
    private let content: SettingsFooterContent

    public init(info: AppBuildInfo = AppBuildInfo()) {
        content = SettingsFooterContent(info: info)
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            row(content.items).fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 0) {
                row(Array(content.items.dropLast())).fixedSize(horizontal: true, vertical: false)
                if let last = content.items.last { item(last) }
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 0) {
                ForEach(Array(content.items.enumerated()), id: \.offset) { _, value in
                    item(value).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(ProtonColor.textHint)
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .contain)
    }

    private func row(_ items: [SettingsFooterContent.Item]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, value in
                if index > 0 {
                    Text(verbatim: "·")
                        .accessibilityRepresentation { EmptyView() }
                }
                item(value)
            }
        }
    }

    @ViewBuilder private func item(_ value: SettingsFooterContent.Item) -> some View {
        switch value {
        case .link(let label, let url):
            Link(destination: url) {
                Text(verbatim: label)
                    .font(.caption2)
                    .foregroundStyle(ProtonColor.textHint)
                    .monospacedDigit()
            }
        case .text(let label): Text(verbatim: label)
        }
    }
}
