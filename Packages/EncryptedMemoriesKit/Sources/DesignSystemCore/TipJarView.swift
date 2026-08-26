import Foundation
import PhotosCore
import StoreKit
import SwiftUI

/// Native StoreKit merchandising for optional, repeatable tips.
///
/// Tips do not unlock content or features. StoreKit supplies localized product names, descriptions,
/// and prices from App Store Connect.
public struct TipJarView: View {
    private let productIdentifiers: [String]
    @State private var products: [Product] = []
    @State private var productLoadState = ProductLoadState.loading

    public init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        let identifier = bundleIdentifier ?? Self.fallbackBundleIdentifier
        productIdentifiers = TipJarProduct.identifiers(bundleIdentifier: identifier)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("settings.tip_jar_help"))
                .font(.footnote)
                .foregroundStyle(ProtonColor.textWeak)

            storeContent
        }
        .task { await loadProducts() }
    }

    @ViewBuilder
    private var storeContent: some View {
        switch productLoadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
        case .loaded:
            StoreView(products: products) { product in
                Image(systemName: iconName(for: product.id))
                    .foregroundStyle(ProtonColor.primary)
            }
            .productViewStyle(.compact)
            .storeButton(.hidden, for: .restorePurchases, .cancellation)
        case .unavailable:
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("settings.tip_jar_unavailable"))
                    .font(.footnote)
                    .foregroundStyle(ProtonColor.textWeak)
                Button(L10n.string("action.retry")) {
                    Task { await loadProducts() }
                }
            }
        }
    }

    @MainActor
    private func loadProducts() async {
        productLoadState = .loading
        do {
            let loaded = try await Product.products(for: productIdentifiers)
            let productsByID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            products = productIdentifiers.compactMap { productsByID[$0] }
            productLoadState = products.isEmpty ? .unavailable : .loaded
        } catch is CancellationError {
            return
        } catch {
            products = []
            productLoadState = .unavailable
        }
    }

    private func iconName(for productIdentifier: String) -> String {
        if productIdentifier.hasSuffix(".extra_large") { return "heart.square.fill" }
        if productIdentifier.hasSuffix(".large") { return "heart.circle.fill" }
        if productIdentifier.hasSuffix(".medium") { return "heart.fill" }
        return "heart"
    }

    private static let fallbackBundleIdentifier = "at.oncloud.encryptedmemories"

    private enum ProductLoadState {
        case loading
        case loaded
        case unavailable
    }
}

/// Finishes verified tip transactions and ignores every transaction owned by another feature.
public actor TipJarTransactionProcessor {
    public static let shared = TipJarTransactionProcessor()

    private var updateTask: Task<Void, Never>?

    public func start(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        guard updateTask == nil else { return }
        let identifier = bundleIdentifier ?? Self.fallbackBundleIdentifier
        updateTask = Task {
            for await result in StoreKit.Transaction.updates {
                await Self.finishVerifiedTip(result, bundleIdentifier: identifier)
            }
        }
    }

    private static func finishVerifiedTip(
        _ result: VerificationResult<StoreKit.Transaction>,
        bundleIdentifier: String
    ) async {
        guard case .verified(let transaction) = result,
            TipJarProduct.contains(transaction.productID, bundleIdentifier: bundleIdentifier)
        else { return }

        // A tip has no digital entitlement to persist or unlock. Verification completes delivery.
        await transaction.finish()
    }

    private static let fallbackBundleIdentifier = "at.oncloud.encryptedmemories"
}
