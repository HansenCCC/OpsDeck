import Foundation
import StoreKit

@MainActor
final class PurchaseService: ObservableObject {
    static let lifetimeProductID = "com.hansen.opsdeck.pro.lifetime"

    @Published var products: [Product] = []
    @Published var isLoading = false
    @Published var lastMessage: String?

    var lifetimeProduct: Product? {
        products.first { $0.id == Self.lifetimeProductID }
    }

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: [Self.lifetimeProductID])
            if products.isEmpty {
                lastMessage = "Pro product is not configured in StoreKit yet."
            }
        } catch {
            lastMessage = error.localizedDescription
        }
    }

    func purchaseLifetime() async throws -> Bool {
        if products.isEmpty {
            await loadProducts()
        }
        guard let product = lifetimeProduct else {
            lastMessage = "Pro product is unavailable."
            return false
        }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            lastMessage = "Pro unlocked."
            return transaction.productID == Self.lifetimeProductID
        case .userCancelled:
            lastMessage = "Purchase cancelled."
            return false
        case .pending:
            lastMessage = "Purchase is pending approval."
            return false
        @unknown default:
            lastMessage = "Purchase did not finish."
            return false
        }
    }

    func restorePurchases() async throws -> Bool {
        try await AppStore.sync()
        let unlocked = await refreshEntitlements()
        lastMessage = unlocked ? "Purchase restored." : "No Pro purchase found."
        return unlocked
    }

    func refreshEntitlements() async -> Bool {
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            if transaction.productID == Self.lifetimeProductID {
                return true
            }
        }
        return false
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreKitError.notAvailableInStorefront
        case .verified(let safe):
            return safe
        }
    }
}
