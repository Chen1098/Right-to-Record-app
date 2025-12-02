import SwiftUI
import AVFoundation
import AVKit
import CoreMedia
import Photos
import StoreKit

// MARK: - Server Configuration
struct ServerConfig {
    static let baseURL = "http://3.133.124.13:5000"
    
    static let registerURL = "\(baseURL)/register"
    static let loginURL = "\(baseURL)/login"
    static let uploadURL = "\(baseURL)/upload"
    static let videosURL = "\(baseURL)/videos"
    static let downloadURL = "\(baseURL)/download"
    static let deleteURL = "\(baseURL)/delete"
    static let subscriptionURL = "\(baseURL)/update_subscription"
    static let storageURL = "\(baseURL)/storage_info"
    
    static func testConnection(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(baseURL)/test") else {
            completion(false)
            return
        }
        
        URLSession.shared.dataTask(with: url) { _, response, _ in
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse {
                    completion(httpResponse.statusCode == 200)
                } else {
                    completion(false)
                }
            }
        }.resume()
    }
}

// MARK: - Subscription Models
enum SubscriptionTier: String, CaseIterable {
    case free = "free"
    case premium = "com.righttorecord.premium2.monthly"
    case pro = "com.righttorecord.pro2.monthly"
    
    var displayName: String {
        switch self {
        case .free: return "Free"
        case .premium: return "Premium"
        case .pro: return "Pro"
        }
    }
    
    var price: String {
        switch self {
        case .free: return "Free"
        case .premium: return "$4.99/month"
        case .pro: return "$19.99/month"
        }
    }
    
    var storageLimit: TimeInterval {
        switch self {
        case .free: return 20 * 60        // 20 minutes (1,200 seconds)
        case .premium: return 20 * 60 * 60 // 20 hours (72,000 seconds)
        case .pro: return 200 * 60 * 60    // 200 hours (720,000 seconds)
        }
    }
    
    var videoQuality: String {
        switch self {
        case .free: return "360x480"
        case .premium, .pro: return "1080p"
        }
    }
    
    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .free: return .vga640x480
        case .premium, .pro: return .hd1920x1080
        }
    }
}

// MARK: - Subscription Manager
class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()
    
    @Published var currentTier: SubscriptionTier = .free
    @Published var isSubscribed: Bool = false
    @Published var storageUsed: TimeInterval = 0
    @Published var storageLimit: TimeInterval = 20 * 60
    @Published var products: [Product] = []
    @Published var purchaseError: String?
    @Published var showingPurchaseError = false
    @Published var subscriptionExpirationDate: Date?
    @Published var isLoading = false
    @Published var canMakePayments = false
    
    // PRODUCTION Product IDs - UPDATE THESE TO MATCH YOUR APP STORE CONNECT
    // PRODUCTION Product IDs - UPDATED FOR NEW PRICING
    private let productIDs = [
        "com.righttorecord.premium2.monthly",  // New Premium ID
        "com.righttorecord.pro2.monthly"       // New Pro ID
    ]
    
    private var transactionListener: Task<Void, Error>?
    
    private init() {
        // Check if payments are available
        canMakePayments = AppStore.canMakePayments
        
        // Start transaction listener
        transactionListener = listenForTransactions()
        
        Task {
            await loadProducts()
            await updateSubscriptionStatus()
        }
    }
    
    deinit {
        transactionListener?.cancel()
    }
    
    private func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            // Listen for transactions that occur outside the app (renewals, etc.)
            for await result in Transaction.updates {
                do {
                    let transaction = try self.checkVerified(result)
                    
                    await MainActor.run {
                        print("🔄 Transaction update received: \(transaction.productID)")
                        Task {
                            await self.updateSubscriptionStatus()
                        }
                    }
                    
                    await transaction.finish()
                } catch {
                    print("❌ Transaction verification failed: \(error)")
                    await MainActor.run {
                        self.purchaseError = "Transaction verification failed"
                        self.showingPurchaseError = true
                    }
                }
            }
        }
    }
    
    @MainActor
    func loadProducts() async {
        isLoading = true
        
        print("🔍 DEBUG: Attempting to load products: \(productIDs)")
        
        do {
            // Load products from App Store
            products = try await Product.products(for: productIDs)
            print("✅ Loaded \(products.count) subscription products")
            
            if products.isEmpty {
                print("❌ No products loaded! Product IDs might not be available yet.")
                print("❌ This can happen with new subscriptions - they need time to propagate.")
            }
            
            // Sort products by price (Premium first, then Pro)
            products.sort { product1, product2 in
                if product1.id == SubscriptionTier.premium.rawValue { return true }
                if product2.id == SubscriptionTier.premium.rawValue { return false }
                return product1.price < product2.price
            }
            
            for product in products {
                print("📦 Product loaded: \(product.id) - \(product.displayPrice)")
            }
            
        } catch {
            print("❌ Failed to load products: \(error)")
            print("❌ Error details: \(error.localizedDescription)")
            purchaseError = "Failed to load subscription options. New products may need time to appear in sandbox."
            showingPurchaseError = true
        }
        
        isLoading = false
    }
    
    @MainActor
    func updateSubscriptionStatus() async {
        // Check if this is the demo account with server-side subscription
        if let credentials = UserManager.shared.getCurrentCredentials(),
           (credentials.email.hasPrefix("reviewer-") || credentials.email == "test-demo@righttorecord.com") && credentials.email.hasSuffix("@righttorecord.com") {
            
            // For demo account, get subscription status from server
            await checkServerSubscriptionStatus()
            return
        }
        
        // For regular users, check App Store subscriptions
        await updateSubscriptionStatusFromAppStore()
    }
    
    @MainActor
    private func checkServerSubscriptionStatus() async {
        guard let credentials = UserManager.shared.getCurrentCredentials() else { return }
        
        guard let url = URL(string: ServerConfig.storageURL) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "email": credentials.email,
            "password": credentials.password
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tierString = json["subscription_tier"] as? String {
                    
                    
                    // Update subscription status based on server response
                    switch tierString {
                    case "premium":
                        currentTier = .premium
                        isSubscribed = true
                        print("✅ Demo account: Premium subscription detected - UI will update")
                    case "pro":
                        currentTier = .pro
                        isSubscribed = true
                        print("✅ Demo account: Pro subscription detected - UI will update")
                    default:
                        currentTier = .free
                        isSubscribed = false
                        print("✅ Demo account: Free tier detected - UI will update")
                    }
                    
                    // Force UI update immediately
                    DispatchQueue.main.async {
                        self.objectWillChange.send()
                    }
                    
                    storageLimit = currentTier.storageLimit
                    
                    // Set a future expiration date for demo account
                    if isSubscribed {
                        subscriptionExpirationDate = Calendar.current.date(byAdding: .month, value: 1, to: Date())
                    } else {
                        subscriptionExpirationDate = nil
                    }
                    
                    // Force UI update for subscription paywall
                    DispatchQueue.main.async {
                        self.objectWillChange.send()
                    }
                    
                    logSubscriptionState()
                }
            }
        } catch {
            print("❌ Failed to check server subscription status: \(error)")
            // Fall back to App Store check
            await updateSubscriptionStatusFromAppStore()
        }
    }
    
    @MainActor
    private func updateSubscriptionStatusFromAppStore() async {
        // This contains the original App Store subscription checking logic
        var activeSubscriptions: [Product] = []
        var latestExpiration: Date?
        
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                
                if let product = products.first(where: { $0.id == transaction.productID }),
                   product.type == .autoRenewable {
                    activeSubscriptions.append(product)
                    
                    if let expirationDate = transaction.expirationDate {
                        if latestExpiration == nil || expirationDate > latestExpiration! {
                            latestExpiration = expirationDate
                        }
                    }
                }
            } catch {
                print("❌ Failed to verify transaction: \(error)")
            }
        }
        
        // Check for new product IDs first, then old ones for backward compatibility
        if activeSubscriptions.contains(where: {
            $0.id == SubscriptionTier.pro.rawValue ||
            $0.id == "com.righttorecord.pro2.monthly"
        }) {
            currentTier = .pro
            isSubscribed = true
        } else if activeSubscriptions.contains(where: {
            $0.id == SubscriptionTier.premium.rawValue ||
            $0.id == "com.righttorecord.premium2.monthly" ||
            $0.id == "com.righttorecord.premium2.monthly"
        }) {
            currentTier = .premium
            isSubscribed = true
        } else {
            currentTier = .free
            isSubscribed = false
        }
        
        subscriptionExpirationDate = latestExpiration
        storageLimit = currentTier.storageLimit
        
        await updateServerSubscriptionStatus()
        logSubscriptionState()
    }
    
    private func updateServerSubscriptionStatus() async {
        guard let credentials = UserManager.shared.getCurrentCredentials() else { return }
        
        var latestTransactionJWS: String?
        
        // Legacy product IDs for backward compatibility
        let legacyProductIDs = [
            "com.righttorecord.premium2.monthly",
            "com.righttorecord.pro2.monthly"
        ]

        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                if productIDs.contains(transaction.productID) || legacyProductIDs.contains(transaction.productID) {
                    latestTransactionJWS = result.jwsRepresentation
                    break
                }
            } catch {
                continue
            }
        }
        
        let body: [String: Any] = [
            "email": credentials.email,
            "password": credentials.password,
            "subscription_tier": currentTier.rawValue,
            "storage_limit": storageLimit,
            "transaction_jws": latestTransactionJWS ?? "",
            "expires_at": subscriptionExpirationDate?.iso8601String ?? ""
        ]
        
        guard let url = URL(string: ServerConfig.subscriptionURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                print("✅ Updated server subscription status")
            }
        } catch {
            print("❌ Failed to update server subscription: \(error)")
        }
    }
    
    func purchase(_ product: Product) async throws {
        // Check if payments are allowed
        guard AppStore.canMakePayments else {
            await MainActor.run {
                self.purchaseError = "Purchases are not allowed on this device. Check Screen Time restrictions."
                self.showingPurchaseError = true
            }
            throw SubscriptionError.cannotMakePayments
        }
        
        await MainActor.run {
            self.isLoading = true
        }
        
        do {
            print("🛒 Starting purchase for: \(product.displayName)")
            
            let result = try await product.purchase()
            
            await MainActor.run {
                self.isLoading = false
            }
            
            switch result {
            case .success(let verification):
                print("✅ Purchase successful, verifying...")
                
                do {
                    let transaction = try checkVerified(verification)
                    
                    await MainActor.run {
                        print("🎉 Purchase verified: \(transaction.productID)")
                    }
                    
                    // Update subscription status
                    await updateSubscriptionStatus()
                    
                    // Finish the transaction
                    await transaction.finish()
                    
                    await MainActor.run {
                        print("🔄 Subscription status updated to: \(self.currentTier.displayName)")
                    }
                    
                } catch {
                    await MainActor.run {
                        self.purchaseError = "Purchase verification failed: \(error.localizedDescription)"
                        self.showingPurchaseError = true
                    }
                    throw error
                }
                
            case .userCancelled:
                print("⏹️ User cancelled purchase")
                await MainActor.run {
                    // Don't show error for user cancellation
                }
                throw SubscriptionError.userCancelled
                
            case .pending:
                print("⏳ Purchase pending approval")
                await MainActor.run {
                    self.purchaseError = "Purchase is pending approval. Please check back later."
                    self.showingPurchaseError = true
                }
                throw SubscriptionError.purchasePending
                
            @unknown default:
                print("❓ Unknown purchase result")
                await MainActor.run {
                    self.purchaseError = "An unknown error occurred during purchase."
                    self.showingPurchaseError = true
                }
                throw SubscriptionError.unknownError
            }
            
        } catch let error as SubscriptionError {
            await MainActor.run {
                self.isLoading = false
            }
            throw error
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.purchaseError = "Purchase failed: \(error.localizedDescription)"
                self.showingPurchaseError = true
            }
            throw error
        }
    }
    
    // MARK: - Restore Purchases
    @MainActor
    func restorePurchases() async {
        isLoading = true
        
        do {
            // Sync with App Store to get latest transactions
            try await AppStore.sync()
            
            // Update subscription status after sync
            await updateSubscriptionStatus()
            
            if isSubscribed {
                purchaseError = "✅ Purchases restored! You have \(currentTier.displayName) subscription."
            } else {
                purchaseError = "No active subscriptions found to restore."
            }
            showingPurchaseError = true
            
        } catch {
            purchaseError = "Failed to restore purchases: \(error.localizedDescription)"
            showingPurchaseError = true
        }
        
        isLoading = false
    }
    
    // MARK: - Manage Subscriptions (opens App Store settings)
    @MainActor
    func manageSubscriptions() async {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            do {
                try await AppStore.showManageSubscriptions(in: windowScene)
            } catch {
                purchaseError = "Unable to open subscription management. Please go to Settings > Apple ID > Subscriptions."
                showingPurchaseError = true
            }
        }
    }
    
    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw SubscriptionError.verificationFailed(error)
        case .verified(let safe):
            return safe
        }
    }
    
    var storageUsagePercentage: Double {
        guard storageLimit > 0 else { return 0 }
        return min(storageUsed / storageLimit, 1.0)
    }
    
    var isStorageFull: Bool {
        return storageUsed >= storageLimit
    }
    
    func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = Int(seconds) % 3600 / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
    
    var subscriptionStatusText: String {
        if isSubscribed {
            if let expiration = subscriptionExpirationDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                return "Active until \(formatter.string(from: expiration))"
            } else {
                return "Active"
            }
        } else {
            return "Free Plan"
        }
    }
    
    private func logSubscriptionState() {
        print("📊 SUBSCRIPTION DEBUG INFO:")
        print("📊 Current Tier: \(currentTier.displayName)")
        print("📊 Is Subscribed: \(isSubscribed)")
        print("📊 Can Make Payments: \(canMakePayments)")
        print("📊 Products Loaded: \(products.count)")
        print("📊 Storage Used: \(formatDuration(storageUsed))")
        print("📊 Storage Limit: \(formatDuration(storageLimit))")
        
        for product in products {
            print("📊 Product: \(product.id) - \(product.displayPrice)")
        }
        
        if let expiration = subscriptionExpirationDate {
            print("📊 Expires: \(expiration)")
        }
        
        print("📊 Environment: \(Bundle.main.infoDictionary?["CFBundleIdentifier"] ?? "unknown")")
    }
}

// MARK: - Subscription Errors
enum SubscriptionError: Error, LocalizedError {
    case cannotMakePayments
    case userCancelled
    case purchasePending
    case verificationFailed(Error)
    case unknownError
    
    var errorDescription: String? {
        switch self {
        case .cannotMakePayments:
            return "Purchases are not allowed on this device"
        case .userCancelled:
            return "Purchase was cancelled"
        case .purchasePending:
            return "Purchase is pending approval"
        case .verificationFailed(let error):
            return "Purchase verification failed: \(error.localizedDescription)"
        case .unknownError:
            return "An unknown error occurred"
        }
    }
}

// MARK: - Date Extension
extension Date {
    var iso8601String: String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: self)
    }
}

// MARK: - Product.SubscriptionPeriod Extension
extension Product.SubscriptionPeriod {
    var localizedDescription: String {
        switch unit {
        case .day:
            return value == 1 ? "Daily" : "\(value) days"
        case .week:
            return value == 1 ? "Weekly" : "\(value) weeks"
        case .month:
            return value == 1 ? "Monthly" : "\(value) months"
        case .year:
            return value == 1 ? "Yearly" : "\(value) years"
        @unknown default:
            return "Unknown period"
        }
    }
}

// MARK: - Supporting Models
struct User: Codable {
    let id: String
    let email: String
    let fullName: String
    let createdAt: String
}

struct VideoInfo: Identifiable {
    let id = UUID()
    let sessionId: String
    let sessionName: String
    let chunkCount: Int
    let date: String
}

extension VideoInfo: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: VideoInfo, rhs: VideoInfo) -> Bool {
        return lhs.id == rhs.id
    }
}

struct ChunkInfo {
    let filename: String
    let downloadURL: String
    let order: Int
}

// MARK: - Custom UI Styles
struct AuthTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding()
            .background(Color.white.opacity(0.15))
            .foregroundColor(.white)
            .cornerRadius(15)
            .overlay(
                RoundedRectangle(cornerRadius: 15)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            )
    }
}

struct CustomButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .font(.title2)
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
            .frame(height: 55)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [Color.orange, Color.red]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(15)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .shadow(radius: 10)
    }
}

// MARK: - Corner Radius Extension
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var userManager = UserManager.shared
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var showingCamera = false
    @State private var showingLibrary = false
    @State private var showingSubscriptions = false
    @State private var serverStatus = "Checking connection..."
    @State private var isServerOnline = false
    
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(.systemGray6).opacity(0.3),
                    Color.black.opacity(0.8),
                    Color(.systemGray2).opacity(0.4)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            if userManager.isLoggedIn {
                VStack(spacing: 30) {
                    // App title and user info
                    VStack(spacing: 15) {
                        Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                            .font(.system(size: 60))
                            .foregroundColor(isServerOnline ? .white : .gray)
                            .shadow(radius: 5)
                        
                        Text("RightToRecord")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .shadow(radius: 3)
                        
                        Text("Constitutional Protection System")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                            .shadow(radius: 2)
                        
                        SubscriptionStatusView()
                        
                        VStack(spacing: 5) {
                            Text("Welcome, \(userManager.currentUser?.email ?? "User")")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                            
                            HStack {
                                Circle()
                                    .fill(isServerOnline ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(serverStatus)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                    }
                    .padding(.top, 40)
                    
                    Spacer()
                    
                    VStack(spacing: 25) {
                        // Record Button
                        Button(action: {
                            if subscriptionManager.isStorageFull {
                                showingSubscriptions = true
                            } else if isServerOnline {
                                showingCamera = true
                            }
                        }) {
                            HStack(spacing: 15) {
                                Image(systemName: subscriptionManager.isStorageFull ? "exclamationmark.triangle.fill" : "record.circle.fill")
                                    .font(.system(size: 30))
                                Text(subscriptionManager.isStorageFull ? "STORAGE FULL" : "START RECORDING")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .tracking(1.2)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 70)
                            .background(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        subscriptionManager.isStorageFull ? Color.orange : Color.red.opacity(0.9),
                                        subscriptionManager.isStorageFull ? Color.red : Color.red.opacity(0.7)
                                    ]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .cornerRadius(15)
                            .shadow(radius: 10)
                        }
                        .disabled(!isServerOnline)
                        
                        // Library Button
                        Button(action: {
                            if isServerOnline {
                                showingLibrary = true
                            }
                        }) {
                            HStack(spacing: 15) {
                                Image(systemName: "folder.fill.badge.gearshape")
                                    .font(.system(size: 30))
                                Text("ACCESS VAULT")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .tracking(1.2)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 70)
                            .background(
                                LinearGradient(
                                    gradient: Gradient(colors: [Color.green.opacity(0.8), Color.green.opacity(0.6)]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .cornerRadius(15)
                            .shadow(radius: 10)
                        }
                        .disabled(!isServerOnline)
                        
                        // Upgrade Button
                        Button(action: {
                            showingSubscriptions = true
                        }) {
                            HStack(spacing: 15) {
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 30))
                                Text("UPGRADE")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .tracking(1.2)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 70)
                            .background(
                                LinearGradient(
                                    gradient: Gradient(colors: [Color.purple.opacity(0.8), Color.blue.opacity(0.6)]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .cornerRadius(15)
                            .shadow(radius: 10)
                        }
                        
                        // Logout Button
                        Button(action: {
                            userManager.logout()
                        }) {
                            HStack(spacing: 15) {
                                Image(systemName: "person.fill.xmark")
                                    .font(.system(size: 20))
                                Text("LOGOUT")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(.white.opacity(0.8))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.gray.opacity(0.3))
                            .cornerRadius(10)
                        }
                    }
                    .padding(.horizontal, 30)
                    
                    Spacer()
                }
            } else {
                AuthenticationView()
            }
        }
        .onAppear {
            cameraManager.setupCamera()
            checkServerConnection()
            loadStorageInfo()
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraRecordingView()
        }
        .sheet(isPresented: $showingLibrary) {
            VideoLibraryView()
        }
        .sheet(isPresented: $showingSubscriptions) {
            SubscriptionPaywallView()
        }
        .task {
            await subscriptionManager.updateSubscriptionStatus()
        }
    }
    
    private func checkServerConnection() {
        ServerConfig.testConnection { isOnline in
            isServerOnline = isOnline
            serverStatus = isOnline ? "Server online" : "Server offline"
        }
    }
    
    private func loadStorageInfo() {
        Task {
            await VideoManager.shared.updateStorageInfo()
        }
    }
}

// MARK: - Subscription Status View
struct SubscriptionStatusView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: subscriptionManager.isSubscribed ? "crown.fill" : "person.circle")
                    .foregroundColor(subscriptionManager.isSubscribed ? .yellow : .white.opacity(0.8))
                
                Text("\(subscriptionManager.currentTier.displayName) Plan")
                    .font(.headline)
                    .foregroundColor(.white)
                
                if subscriptionManager.isSubscribed {
                    Text("(\(subscriptionManager.currentTier.price))")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            
            VStack(spacing: 4) {
                HStack {
                    Text("Storage:")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                    
                    Spacer()
                    
                    Text("\(subscriptionManager.formatDuration(subscriptionManager.storageUsed)) / \(subscriptionManager.formatDuration(subscriptionManager.storageLimit))")
                        .font(.caption)
                        .foregroundColor(subscriptionManager.isStorageFull ? .red : .white.opacity(0.7))
                }
                
                ProgressView(value: subscriptionManager.storageUsagePercentage)
                    .progressViewStyle(LinearProgressViewStyle(tint: subscriptionManager.isStorageFull ? .red : .green))
                    .frame(height: 4)
            }
            
            Text("Quality: \(subscriptionManager.currentTier.videoQuality)")
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
        }
        .padding()
        .background(Color.white.opacity(0.1))
        .cornerRadius(10)
        .padding(.horizontal)
    }
}

// MARK: - Subscription Paywall View
struct SubscriptionPaywallView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.1)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 30) {
                        // Header
                        VStack(spacing: 5) {
                            Text("🔍 DEBUG INFO:")
                                .font(.caption)
                                .foregroundColor(.red)
                                .fontWeight(.bold)
                            Text("Products loaded: \(subscriptionManager.products.count)")
                                .font(.caption)
                                .foregroundColor(.red)
                            Text("Can make payments: \(subscriptionManager.canMakePayments)")
                                .font(.caption)
                                .foregroundColor(.red)
                            Text("Is loading: \(subscriptionManager.isLoading)")
                                .font(.caption)
                                .foregroundColor(.red)
                                    
                            ForEach(subscriptionManager.products, id: \.id) { product in
                                Text("Product: \(product.id) - \(product.displayPrice)")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                        .padding()
                        .background(Color.yellow.opacity(0.3))
                        .cornerRadius(10)
                        
                        VStack(spacing: 15) {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 60))
                                .foregroundColor(.yellow)
                                .shadow(radius: 5)
                            
                            Text("Upgrade to Premium")
                                .font(.largeTitle)
                                .bold()
                                .foregroundColor(.primary)
                            
                            Text("Get more storage and better video quality")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 20)
                        
                        // Current Plan Status
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Current Plan: \(subscriptionManager.currentTier.displayName)")
                                    .font(.headline)
                                
                                Spacer()
                                
                                if subscriptionManager.isSubscribed {
                                    Text("✅ Active")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.green.opacity(0.2))
                                        .cornerRadius(8)
                                }
                            }
                            
                            HStack {
                                Text("Storage Used:")
                                Spacer()
                                Text("\(subscriptionManager.formatDuration(subscriptionManager.storageUsed)) / \(subscriptionManager.formatDuration(subscriptionManager.storageLimit))")
                                    .foregroundColor(subscriptionManager.isStorageFull ? .red : .green)
                            }
                            
                            ProgressView(value: subscriptionManager.storageUsagePercentage)
                                .progressViewStyle(LinearProgressViewStyle(tint: subscriptionManager.isStorageFull ? .red : .blue))
                            
                            if let expiration = subscriptionManager.subscriptionExpirationDate {
                                HStack {
                                    Text("Expires:")
                                    Spacer()
                                    Text(expiration, style: .date)
                                        .foregroundColor(.orange)
                                }
                                .font(.caption)
                            }
                        }
                        .padding()
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(15)
                        .padding(.horizontal)
                        
                        
                        // Loading State
                        if subscriptionManager.isLoading {
                            VStack(spacing: 15) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                                    .scaleEffect(1.2)
                                
                                Text("Loading subscription options...")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                        }
                        
                        // Cannot Make Payments Warning
                        if !subscriptionManager.canMakePayments {
                            VStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.orange)
                                
                                Text("Purchases Disabled")
                                    .font(.headline)
                                    .foregroundColor(.orange)
                                
                                Text("Purchases are not allowed on this device. Check Screen Time restrictions.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding()
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(15)
                            .padding(.horizontal)
                        }
                        
                        // Plans
                        // Plans
                        if !subscriptionManager.isLoading {
                            VStack(spacing: 20) {
                                // Free Plan
                                PlanCard(
                                    title: "Free",
                                    price: "Free",
                                    features: [
                                        "20 minutes storage",
                                        "360x480 video quality",
                                        "Basic constitutional protection",
                                        "Cloud backup during recording"
                                    ],
                                    isCurrentPlan: subscriptionManager.currentTier == .free,
                                    isPremium: false
                                )
                                
                                // Show static cards if products haven't loaded yet (for testing)
                                if subscriptionManager.products.isEmpty {
                                    // Static Premium Card
                                    PlanCard(
                                        title: "Premium",
                                        price: "$4.99/month",
                                        features: [
                                            "20 hours storage (60x more!)",
                                            "1080p HD video quality",
                                            "Priority cloud backup",
                                            "Priority customer support",
                                            "Advanced encryption"
                                        ],
                                        isCurrentPlan: subscriptionManager.currentTier == .premium,
                                        isPremium: true,
                                        product: nil,
                                        isLoading: false,
                                        canMakePayments: subscriptionManager.canMakePayments,
                                        onPurchase: {
                                            Task {
                                                // Check if this is a demo account
                                                let isDemoAccount = {
                                                    guard let email = UserManager.shared.getCurrentCredentials()?.email else { return false }
                                                    return email.hasPrefix("reviewer-") || email == "test-demo@righttorecord.com"
                                                }()
                                                
                                                if isDemoAccount {
                                                    await switchDemoAccountTier(to: "premium")
                                                } else {
                                                    // Real users should see a message that products are loading
                                                    await MainActor.run {
                                                        subscriptionManager.purchaseError = "Subscription products are loading. Please try again in a moment."
                                                        subscriptionManager.showingPurchaseError = true
                                                    }
                                                }
                                            }
                                        }
                                    )
                                    
                                    // Static Pro Card
                                    PlanCard(
                                        title: "Pro",
                                        price: "$19.99/month",
                                        features: [
                                            "200 hours storage (600x more!)",
                                            "1080p HD video quality",
                                            "Fastest cloud backup",
                                            "Premium customer support",
                                            "Advanced encryption",
                                            "Future premium features"
                                        ],
                                        isCurrentPlan: subscriptionManager.currentTier == .pro,
                                        isPremium: true,
                                        product: nil,
                                        isLoading: false,
                                        canMakePayments: subscriptionManager.canMakePayments,
                                        onPurchase: {
                                            Task {
                                                // Check if this is a demo account
                                                let isDemoAccount = {
                                                    guard let email = UserManager.shared.getCurrentCredentials()?.email else { return false }
                                                    return email.hasPrefix("reviewer-") || email == "test-demo@righttorecord.com"
                                                }()
                                                
                                                if isDemoAccount {
                                                    await switchDemoAccountTier(to: "pro")
                                                } else {
                                                    // Real users should see a message that products are loading
                                                    await MainActor.run {
                                                        subscriptionManager.purchaseError = "Subscription products are loading. Please try again in a moment."
                                                        subscriptionManager.showingPurchaseError = true
                                                    }
                                                }
                                            }
                                        }
                                    )
                                } else {
                                    // Real App Store Products (when they load)
                                    ForEach(subscriptionManager.products, id: \.id) { product in
                                        PlanCard(
                                            title: product.id == SubscriptionTier.premium.rawValue ? "Premium" : "Pro",
                                            price: product.displayPrice,
                                            features: product.id == SubscriptionTier.premium.rawValue ? [
                                                "20 hours storage (60x more!)",
                                                "1080p HD video quality",
                                                "Priority cloud backup",
                                                "Priority customer support",
                                                "Advanced encryption"
                                            ] : [
                                                "200 hours storage (600x more!)",
                                                "1080p HD video quality",
                                                "Fastest cloud backup",
                                                "Premium customer support",
                                                "Advanced encryption",
                                                "Future premium features"
                                            ],
                                            isCurrentPlan: (product.id == SubscriptionTier.premium.rawValue && subscriptionManager.currentTier == .premium) ||
                                                          (product.id == SubscriptionTier.pro.rawValue && subscriptionManager.currentTier == .pro),
                                            isPremium: true,
                                            product: product,
                                            isLoading: subscriptionManager.isLoading,
                                            canMakePayments: subscriptionManager.canMakePayments,
                                            onPurchase: {
                                                Task {
                                                    await purchaseProduct(product)
                                                }
                                            }
                                        )
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        
                        // Subscription Management Buttons
                        if subscriptionManager.isSubscribed {
                            VStack(spacing: 15) {
                                Button("Manage Subscription") {
                                    Task {
                                        await subscriptionManager.manageSubscriptions()
                                    }
                                }
                                .font(.headline)
                                .foregroundColor(.blue)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.blue, lineWidth: 1)
                                )
                            }
                            .padding(.horizontal)
                        }
                        
                        // Restore Purchases Button
                        Button("Restore Purchases") {
                            Task {
                                await subscriptionManager.restorePurchases()
                            }
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                        .padding(.horizontal)
                        
                        // Footer with App Store Required Terms
                        VStack(spacing: 12) {
                            Text("SUBSCRIPTION TERMS")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.secondary)
                            
                            VStack(spacing: 8) {
                                Text("• Payment charged to Apple ID account at confirmation")
                                Text("• Subscription automatically renews unless cancelled 24h before period ends")
                                Text("• Account charged for renewal within 24h of current period end")
                                Text("• Manage subscriptions in Settings > Apple ID > Subscriptions")
                                Text("• Cancel anytime to avoid future charges")
                                Text("• Unused free trial forfeited when purchasing subscription")
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                            
                            HStack(spacing: 20) {
                                Button("Privacy Policy") {
                                    if let url = URL(string: "https://venerable-pie-32eb09.netlify.app/privacy") {
                                        UIApplication.shared.open(url)
                                    }
                                }
                                .font(.caption)
                                .foregroundColor(.blue)
                                
                                Button("Terms of Service") {
                                    if let url = URL(string: "https://venerable-pie-32eb09.netlify.app/terms") {
                                        UIApplication.shared.open(url)
                                    }
                                }
                                .font(.caption)
                                .foregroundColor(.blue)
                            }
                            .padding(.top, 8)
                        }
                        .padding()
                        .padding(.bottom, 20)
                    }
                }
            }
            .navigationTitle("Upgrade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .alert("Subscription Update", isPresented: $subscriptionManager.showingPurchaseError) {
            Button("OK") { }
        } message: {
            Text(subscriptionManager.purchaseError ?? "Unknown error")
        }
    }
    
    private func purchaseProduct(_ product: Product) async {
        do {
            try await subscriptionManager.purchase(product)
            // If purchase is successful, dismiss the paywall
            if subscriptionManager.isSubscribed {
                dismiss()
            }
        } catch SubscriptionError.userCancelled {
            // Don't show error for user cancellation
            print("User cancelled purchase")
        } catch {
            // Other errors are handled by the SubscriptionManager
            print("Purchase error: \(error)")
        }
    }
    private func switchDemoAccountTier(to tier: String) async {
        print("🔄 Starting tier switch to: \(tier)")
        
        guard let credentials = UserManager.shared.getCurrentCredentials(),
              (credentials.email.hasPrefix("reviewer-") || credentials.email == "test-demo@righttorecord.com") else {
            print("❌ Not a demo account")
            return
        }
        
        guard let url = URL(string: "http://3.133.124.13:5000/demo_switch_tier") else {
            print("❌ Invalid URL")
            return
        }
        
        await MainActor.run {
            subscriptionManager.purchaseError = "Switching to \(tier.capitalized) plan..."
            subscriptionManager.showingPurchaseError = true
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0  // Add timeout
        
        let body = [
            "tier": tier,
            "email": credentials.email
        ]
        
        do {
            print("🌐 Making request to switch tier...")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            print("📱 Received response")
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📊 Status code: \(httpResponse.statusCode)")
                
                if httpResponse.statusCode == 200 {
                    print("✅ Server switch successful")
                    
                    // Wait a moment for server to process
                    try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    
                    print("🔄 Refreshing subscription status...")
                    await subscriptionManager.updateSubscriptionStatus()
                    
                    await MainActor.run {
                        subscriptionManager.purchaseError = "✅ Successfully switched to \(tier.capitalized) plan! Check main screen."
                        subscriptionManager.showingPurchaseError = true
                    }
                    print("✅ UI updated with success message")
                    
                } else {
                    print("❌ Server error: \(httpResponse.statusCode)")
                    let responseString = String(data: data, encoding: .utf8) ?? "No response data"
                    print("❌ Response: \(responseString)")
                    
                    await MainActor.run {
                        subscriptionManager.purchaseError = "Server error (\(httpResponse.statusCode)). Please try again."
                        subscriptionManager.showingPurchaseError = true
                    }
                }
            } else {
                print("❌ No HTTP response")
                await MainActor.run {
                    subscriptionManager.purchaseError = "Network error. Please check connection."
                    subscriptionManager.showingPurchaseError = true
                }
            }
            
        } catch {
            print("❌ Exception: \(error)")
            await MainActor.run {
                subscriptionManager.purchaseError = "Error: \(error.localizedDescription)"
                subscriptionManager.showingPurchaseError = true
            }
        }
    }
}

// MARK: - Plan Card View
struct PlanCard: View {
    let title: String
    let price: String
    let features: [String]
    let isCurrentPlan: Bool
    let isPremium: Bool
    let product: Product?
    let isLoading: Bool
    let canMakePayments: Bool
    let onPurchase: (() -> Void)?
    
    init(title: String, price: String, features: [String], isCurrentPlan: Bool, isPremium: Bool, product: Product? = nil, isLoading: Bool = false, canMakePayments: Bool = true, onPurchase: (() -> Void)? = nil) {
        self.title = title
        self.price = price
        self.features = features
        self.isCurrentPlan = isCurrentPlan
        self.isPremium = isPremium
        self.product = product
        self.isLoading = isLoading
        self.canMakePayments = canMakePayments
        self.onPurchase = onPurchase
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(title)
                            .font(.title2)
                            .bold()
                        
                        if isPremium && title == "Pro" {
                            Text("BEST VALUE")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.orange)
                                .cornerRadius(4)
                        } else if isPremium && title == "Premium" {
                            Text("POPULAR")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.blue)
                                .cornerRadius(4)
                        }
                    }
                    
                    Text(price)
                        .font(.headline)
                        .foregroundColor(isPremium ? .blue : .green)
                    
                    if isPremium {
                        let isDemoAccount = {
                            guard let email = UserManager.shared.getCurrentCredentials()?.email else { return false }
                            return email.hasPrefix("reviewer-") || email == "test-demo@righttorecord.com"
                        }()
                        let periodText = isDemoAccount ? "Yearly" : (product?.subscription?.subscriptionPeriod.localizedDescription ?? "Monthly")
                        
                        Text(periodText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if isCurrentPlan {
                    VStack(spacing: 4) {
                        Text("✓ Current")
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        
                        if isPremium {
                            Text("Active")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                ForEach(features, id: \.self) { feature in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(isPremium ? .blue : .green)
                            .font(.subheadline)
                        
                        Text(feature)
                            .font(.subheadline)
                            .multilineTextAlignment(.leading)
                        
                        Spacer()
                    }
                }
            }
            
            let isDemoAccount = UserManager.shared.getCurrentCredentials()?.email.hasPrefix("reviewer-") ?? false
            let showPurchaseButton = isPremium && canMakePayments && (!isCurrentPlan || isDemoAccount)

            if showPurchaseButton {
                Button(action: {
                    onPurchase?()
                }) {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        }
                        
                        Text(isLoading ? "Processing..." : "Subscribe Now")
                            .font(.headline)
                            .fontWeight(.bold)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                title == "Pro" ? Color.orange : Color.blue,
                                title == "Pro" ? Color.red : Color.purple
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(10)
                    .shadow(radius: isCurrentPlan ? 0 : 5)
                }
                .disabled(isLoading)
            } else if isPremium && !canMakePayments {
                Text("Purchases Disabled")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(10)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 15)
                .fill(Color.white.opacity(isCurrentPlan ? 0.2 : 0.1))
                .stroke(
                    isCurrentPlan ? Color.green :
                    (title == "Pro" ? Color.orange.opacity(0.5) : Color.blue.opacity(0.3)),
                    lineWidth: isCurrentPlan ? 2 : 1
                )
                .shadow(
                    color: isCurrentPlan ? Color.green.opacity(0.3) : Color.clear,
                    radius: isCurrentPlan ? 5 : 0
                )
        )
    }
}

// MARK: - Authentication View (NO USERNAME FIELD)
struct AuthenticationView: View {
    @State private var isLoginMode = true
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var keyboardHeight: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 40) {
                    VStack(spacing: 15) {
                        Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                            .font(.system(size: 70))
                            .foregroundColor(.white)
                            .shadow(radius: 10)
                        
                        Text("RightToRecord")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(.white)
                            .shadow(radius: 5)
                        
                        Text("Constitutional Protection System")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .shadow(radius: 3)
                    }
                    .padding(.top, 40)
                    
                    VStack(spacing: 30) {
                        // Mode toggle
                        HStack(spacing: 0) {
                            Button("LOGIN") {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    isLoginMode = true
                                    clearFields()
                                }
                            }
                            .foregroundColor(isLoginMode ? .white : .white.opacity(0.6))
                            .font(.headline)
                            .fontWeight(isLoginMode ? .bold : .medium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(isLoginMode ? Color.blue.opacity(0.8) : Color.clear)
                            .cornerRadius(10, corners: [.topLeft, .bottomLeft])
                            
                            Button("REGISTER") {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    isLoginMode = false
                                    clearFields()
                                }
                            }
                            .foregroundColor(!isLoginMode ? .white : .white.opacity(0.6))
                            .font(.headline)
                            .fontWeight(!isLoginMode ? .bold : .medium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(!isLoginMode ? Color.green.opacity(0.8) : Color.clear)
                            .cornerRadius(10, corners: [.topRight, .bottomRight])
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                        )
                        
                        // Form fields
                        VStack(spacing: 25) {
                            TextField("", text: $email, prompt: Text("Email Address").foregroundColor(.white.opacity(0.7)))
                                .textFieldStyle(AuthTextFieldStyle())
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .autocapitalization(.none)
                            
                            SecureField("", text: $password, prompt: Text("6-Digit Password").foregroundColor(.white.opacity(0.7)))
                                .textFieldStyle(AuthTextFieldStyle())
                                .textContentType(isLoginMode ? .password : .newPassword)
                                .keyboardType(.numberPad)
                                .onChange(of: password) { newValue in
                                    if newValue.count > 6 {
                                        password = String(newValue.prefix(6))
                                    }
                                    password = newValue.filter { $0.isNumber }
                                }
                            
                            if !isLoginMode {
                                SecureField("", text: $confirmPassword, prompt: Text("Confirm 6-Digit Password").foregroundColor(.white.opacity(0.7)))
                                    .textFieldStyle(AuthTextFieldStyle())
                                    .textContentType(.newPassword)
                                    .keyboardType(.numberPad)
                                    .onChange(of: confirmPassword) { newValue in
                                        if newValue.count > 6 {
                                            confirmPassword = String(newValue.prefix(6))
                                        }
                                        confirmPassword = newValue.filter { $0.isNumber }
                                    }
                            }
                        }
                        
                        // Submit button
                        Button(action: {
                            if isLoginMode {
                                loginUser()
                            } else {
                                registerUser()
                            }
                        }) {
                            HStack {
                                if isLoading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                }
                                Text(isLoading ? "Please wait..." : (isLoginMode ? "LOGIN" : "CREATE ACCOUNT"))
                                    .font(.title2)
                                    .fontWeight(.bold)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 60)
                            .background(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        isLoginMode ? Color.blue : Color.green,
                                        isLoginMode ? Color.cyan : Color.mint
                                    ]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .cornerRadius(15)
                            .shadow(radius: 10)
                        }
                        .disabled(isLoading || !isFormValid)
                        .opacity((isLoading || !isFormValid) ? 0.6 : 1.0)
                    }
                    .padding(.horizontal, 30)
                    
                    Text("Secure • Private • Constitutional Rights Protected")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.top, 30)
                        .padding(.bottom, max(50, keyboardHeight > 0 ? 30 : 50))
                }
                .frame(minHeight: geometry.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                withAnimation(.easeInOut(duration: 0.3)) {
                    keyboardHeight = keyboardFrame.height
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                keyboardHeight = 0
            }
        }
        .alert(errorMessage.contains("successfully") ? "Success" : "Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
    }
    
    private var isFormValid: Bool {
        if isLoginMode {
            return password.count == 6 && password.allSatisfy { $0.isNumber } && !email.isEmpty && email.contains("@")
        } else {
            return !email.isEmpty && email.contains("@") &&
                   password.count == 6 && password.allSatisfy { $0.isNumber } &&
                   password == confirmPassword
        }
    }
    
    private func clearFields() {
        email = ""
        password = ""
        confirmPassword = ""
    }
    
    private func loginUser() {
        isLoading = true
        UserManager.shared.login(email: email, password: password) { result in
            DispatchQueue.main.async {
                isLoading = false
                switch result {
                case .success:
                    break
                case .failure(let error):
                    errorMessage = error.localizedDescription
                    showingError = true
                }
            }
        }
    }
    
    private func registerUser() {
        isLoading = true
        // Use email as the display name for simplicity
        let displayName = email.components(separatedBy: "@").first ?? "User"
        UserManager.shared.register(fullName: displayName, email: email, password: password) { result in
            DispatchQueue.main.async {
                isLoading = false
                switch result {
                case .success:
                    break
                case .failure(let error):
                    errorMessage = error.localizedDescription
                    showingError = true
                }
            }
        }
    }
}

// MARK: - User Manager
class UserManager: ObservableObject {
    static let shared = UserManager()
    
    @Published var isLoggedIn = false
    @Published var currentUser: User?
    
    private let emailKey = "user_email"
    private let passwordKey = "user_password"
    
    private init() {
        checkLoginStatus()
    }
    
    private func checkLoginStatus() {
        if let email = UserDefaults.standard.string(forKey: emailKey),
           let password = UserDefaults.standard.string(forKey: passwordKey) {
            login(email: email, password: password) { _ in }
        }
    }
    
    func register(fullName: String, email: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: ServerConfig.registerURL) else {
            completion(.failure(NSError(domain: "Invalid URL", code: 0)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "full_name": fullName,
            "email": email,
            "password": password
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(NSError(domain: "Invalid response", code: 0)))
                return
            }
            
            if httpResponse.statusCode == 201 {
                DispatchQueue.main.async {
                    self.login(email: email, password: password) { result in
                        completion(result)
                    }
                }
            } else {
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMsg = json["error"] as? String {
                    completion(.failure(NSError(domain: errorMsg, code: httpResponse.statusCode)))
                } else {
                    completion(.failure(NSError(domain: "Registration failed", code: httpResponse.statusCode)))
                }
            }
        }.resume()
    }
    
    func login(email: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: ServerConfig.loginURL) else {
            completion(.failure(NSError(domain: "Invalid URL", code: 0)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15.0
        
        let body = [
            "email": email,
            "password": password
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(NSError(domain: "Invalid response", code: 0)))
                return
            }
            
            if httpResponse.statusCode == 200 {
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let userData = json["user"] as? [String: Any],
                   let userId = userData["id"] as? String,
                   let userEmail = userData["email"] as? String,
                   let fullName = userData["full_name"] as? String,
                   let createdAt = userData["created_at"] as? String {
                    
                    let user = User(id: userId, email: userEmail, fullName: fullName, createdAt: createdAt)
                    
                    DispatchQueue.main.async {
                        self.currentUser = user
                        self.isLoggedIn = true
                        
                        UserDefaults.standard.set(email, forKey: self.emailKey)
                        UserDefaults.standard.set(password, forKey: self.passwordKey)
                        UserDefaults.standard.synchronize()
                        
                        // Refresh subscription status and storage info after login
                        Task {
                            await SubscriptionManager.shared.updateSubscriptionStatus()
                            await VideoManager.shared.updateStorageInfo()
                            print("✅ Subscription status refreshed after login")
                        }
                        
                        completion(.success(()))
                    }
                } else {
                    completion(.failure(NSError(domain: "Invalid user data", code: 0)))
                }
            } else {
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    
                    var errorMsg = json["error"] as? String ?? "Login failed"
                    
                    // Handle rate limiting
                    if let rateLimited = json["rate_limited"] as? Bool, rateLimited {
                        let remaining = json["remaining_attempts"] as? Int ?? 0
                        if remaining == 0 {
                            errorMsg = "🚫 Account temporarily locked due to too many failed attempts. Please try again in 24 hours."
                        } else {
                            errorMsg = "⚠️ \(errorMsg)\n\nRemaining attempts today: \(remaining)"
                        }
                    } else if let remaining = json["remaining_attempts"] as? Int {
                        errorMsg = "❌ \(errorMsg)\n\nRemaining attempts today: \(remaining)"
                    }
                    
                    completion(.failure(NSError(domain: errorMsg, code: httpResponse.statusCode)))
                } else {
                    completion(.failure(NSError(domain: "Login failed", code: httpResponse.statusCode)))
                }
            }
        }.resume()
    }
    
    func logout() {
        DispatchQueue.main.async {
            self.currentUser = nil
            self.isLoggedIn = false
            
            UserDefaults.standard.removeObject(forKey: self.emailKey)
            UserDefaults.standard.removeObject(forKey: self.passwordKey)
            UserDefaults.standard.synchronize()
        }
    }
    
    func getCurrentCredentials() -> (email: String, password: String)? {
        guard let email = UserDefaults.standard.string(forKey: emailKey),
              let password = UserDefaults.standard.string(forKey: passwordKey) else {
            return nil
        }
        return (email, password)
    }
}

// MARK: - Camera Manager
class CameraManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isUploading = false
    @Published var lastUploadStatus = ""
    
    private var currentChunk = 0
    private var uploadedChunks = 0
    private var wasIdleTimerDisabled = false
    
    let session = AVCaptureSession()
    var preview: AVCaptureVideoPreviewLayer?
    private var movieOutput = AVCaptureMovieFileOutput()
    private var chunkTimer: Timer?
    private var sessionID = UUID().uuidString
    
    private let chunkDuration: TimeInterval = 15.0
    
    func setupCamera() {
        checkPermissions()
        setupSession()
    }
    
    private func setupSession() {
        session.beginConfiguration()
        
        let subscriptionTier = SubscriptionManager.shared.currentTier
        session.sessionPreset = subscriptionTier.sessionPreset
        
        setupCameraInputs()
        
        session.commitConfiguration()
        
        DispatchQueue.global(qos: .background).async {
            self.session.startRunning()
        }
    }
    
    private func setupCameraInputs() {
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return
        }
        
        guard let videoInput = try? AVCaptureDeviceInput(device: videoDevice) else {
            return
        }
        
        if session.canAddInput(videoInput) {
            session.addInput(videoInput)
        }
        
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            return
        }
        
        guard let audioInput = try? AVCaptureDeviceInput(device: audioDevice) else {
            return
        }
        
        if session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }
        
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            
            if let connection = movieOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .off
                }
            }
        }
    }
    
    private func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if !granted {
                    print("Camera permission denied")
                }
            }
        default:
            print("Camera permission denied")
        }
    }
    
    func startRecording() {
        if SubscriptionManager.shared.isStorageFull {
            lastUploadStatus = "Storage full - please upgrade"
            return
        }
        
        guard !isRecording else { return }
        
        // Prevent screen sleep during recording
        DispatchQueue.main.async {
            self.wasIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            print("🔒 Screen sleep disabled for recording")
        }
        
        isRecording = true
        currentChunk = 1
        uploadedChunks = 0
        sessionID = UUID().uuidString
        lastUploadStatus = "Recording started..."
        
        startNextChunk()
        setupChunkTimer()
    }
    
    func stopRecording() {
        guard isRecording else { return }
        
        isRecording = false
        chunkTimer?.invalidate()
        chunkTimer = nil
        
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
        
        // Restore screen sleep setting
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = self.wasIdleTimerDisabled
            print("🔓 Screen sleep restored after recording")
        }
        
        lastUploadStatus = "Recording stopped."
    }
    
    private func setupChunkTimer() {
        chunkTimer = Timer.scheduledTimer(withTimeInterval: chunkDuration, repeats: true) { _ in
            if self.isRecording {
                self.switchToNextChunk()
            }
        }
    }
    
    private func switchToNextChunk() {
        guard isRecording else { return }
        
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if self.isRecording {
                self.currentChunk += 1
                self.startNextChunk()
            }
        }
    }
    
    private func startNextChunk() {
        guard isRecording else { return }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let videoPath = documentsPath.appendingPathComponent("\(sessionID)_chunk_\(currentChunk).mov")
        
        movieOutput.startRecording(to: videoPath, recordingDelegate: self)
    }
    
    private func compressAndUpload(videoURL: URL, chunkNumber: Int) {
        guard let credentials = UserManager.shared.getCurrentCredentials() else {
            DispatchQueue.main.async {
                self.isUploading = false
                self.lastUploadStatus = "Not logged in"
            }
            return
        }
        
        isUploading = true
        lastUploadStatus = "Compressing..."
        
        let asset = AVAsset(url: videoURL)
        
        // FIXED: Use better preset that maintains resolution
        let preset: String
        switch SubscriptionManager.shared.currentTier {
        case .free:
            preset = AVAssetExportPresetMediumQuality  // 360p for free users
        case .premium, .pro:
            preset = AVAssetExportPreset1920x1080      // KEEP 1080p resolution!
        }
        
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
            DispatchQueue.main.async {
                self.isUploading = false
                self.lastUploadStatus = "Compression failed"
            }
            return
        }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let compressedURL = documentsPath.appendingPathComponent("compressed_\(UUID().uuidString).mov")
        
        exporter.outputURL = compressedURL
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = true
        
        // IMPORTANT: Don't modify video composition for premium users
        if SubscriptionManager.shared.currentTier != .free {
            exporter.videoComposition = nil  // Keep original resolution
        }
        
        exporter.exportAsynchronously {
            DispatchQueue.main.async {
                switch exporter.status {
                case .completed:
                    self.lastUploadStatus = "Uploading..."
                    
                    // Log compression results
                    let originalSize = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int64) ?? 0
                    let compressedSize = (try? FileManager.default.attributesOfItem(atPath: compressedURL.path)[.size] as? Int64) ?? 0
                    
                    print("📦 Compression: \(originalSize/1024/1024)MB → \(compressedSize/1024/1024)MB")
                    print("📦 Preset used: \(preset)")
                    
                    self.uploadCompressedVideo(compressedURL: compressedURL, originalURL: videoURL, chunkNumber: chunkNumber, credentials: credentials)
                    
                case .failed:
                    self.isUploading = false
                    self.lastUploadStatus = "Compression failed: \(exporter.error?.localizedDescription ?? "Unknown")"
                    
                default:
                    self.isUploading = false
                    self.lastUploadStatus = "Compression cancelled"
                }
            }
        }
    }

    private func uploadCompressedVideo(compressedURL: URL, originalURL: URL, chunkNumber: Int, credentials: (email: String, password: String)) {
        // Use your existing upload code but with compressedURL
        var request = URLRequest(url: URL(string: ServerConfig.uploadURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60.0
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var data = Data()
        
        // Add form fields (same as before)
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"email\"\r\n\r\n".data(using: .utf8)!)
        data.append("\(credentials.email)\r\n".data(using: .utf8)!)
        
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"password\"\r\n\r\n".data(using: .utf8)!)
        data.append("\(credentials.password)\r\n".data(using: .utf8)!)
        
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"subscription_tier\"\r\n\r\n".data(using: .utf8)!)
        data.append("\(SubscriptionManager.shared.currentTier.rawValue)\r\n".data(using: .utf8)!)
        
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"session_id\"\r\n\r\n".data(using: .utf8)!)
        data.append("\(sessionID)\r\n".data(using: .utf8)!)
        
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"chunk_number\"\r\n\r\n".data(using: .utf8)!)
        data.append("\(chunkNumber)\r\n".data(using: .utf8)!)
        
        // Add compressed video file
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"video\"; filename=\"\(compressedURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: video/quicktime\r\n\r\n".data(using: .utf8)!)
        
        do {
            let fileData = try Data(contentsOf: compressedURL)
            data.append(fileData)
        } catch {
            DispatchQueue.main.async {
                self.isUploading = false
                self.lastUploadStatus = "Upload failed"
            }
            return
        }
        
        data.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        let task = URLSession.shared.uploadTask(with: request, from: data) { responseData, response, error in
            DispatchQueue.main.async {
                self.isUploading = false
                
                // Clean up compressed file
                try? FileManager.default.removeItem(at: compressedURL)
                
                if let error = error {
                    self.lastUploadStatus = "Upload failed: \(error.localizedDescription)"
                } else if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        self.uploadedChunks += 1
                        self.lastUploadStatus = "✅ Uploaded"
                        
                        try? FileManager.default.removeItem(at: originalURL)
                        
                        Task {
                            await self.updateStorageUsage()
                        }
                    } else {
                        self.lastUploadStatus = "Upload failed: HTTP \(httpResponse.statusCode)"
                    }
                }
            }
        }
        
        task.resume()
    }
    
    private func uploadVideo(at url: URL, chunkNumber: Int) {
        guard let credentials = UserManager.shared.getCurrentCredentials() else {
            DispatchQueue.main.async {
                self.isUploading = false
                self.lastUploadStatus = "Not logged in"
            }
            return
        }
        
        isUploading = true
        lastUploadStatus = "Uploading..."
        
        var request = URLRequest(url: URL(string: ServerConfig.uploadURL)!)
        request.httpMethod = "POST"
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var data = Data()
        
        // Add credentials
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"email\"\r\n\r\n".data(using: .utf8)!)
        data.append("\(credentials.email)\r\n".data(using: .utf8)!)
        
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"password\"\r\n\r\n".data(using: .utf8)!)
        data.append("\(credentials.password)\r\n".data(using: .utf8)!)
        
        // Add subscription tier
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"subscription_tier\"\r\n\r\n".data(using: .utf8)!)
        data.append("\(SubscriptionManager.shared.currentTier.rawValue)\r\n".data(using: .utf8)!)
        
        // Add session info
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"session_id\"\r\n\r\n".data(using: .utf8)!)
        data.append("\(sessionID)\r\n".data(using: .utf8)!)
        
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"chunk_number\"\r\n\r\n".data(using: .utf8)!)
        data.append("\(chunkNumber)\r\n".data(using: .utf8)!)
        
        // Add file data
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"video\"; filename=\"\(url.lastPathComponent)\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: video/quicktime\r\n\r\n".data(using: .utf8)!)
        
        do {
            let fileData = try Data(contentsOf: url)
            data.append(fileData)
        } catch {
            DispatchQueue.main.async {
                self.isUploading = false
                self.lastUploadStatus = "Upload failed"
            }
            return
        }
        
        data.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        let task = URLSession.shared.uploadTask(with: request, from: data) { responseData, response, error in
            DispatchQueue.main.async {
                self.isUploading = false
                
                if let error = error {
                    self.lastUploadStatus = "Upload failed: \(error.localizedDescription)"
                } else if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        self.uploadedChunks += 1
                        self.lastUploadStatus = "Uploaded successfully"
                        
                        try? FileManager.default.removeItem(at: url)
                        
                        Task {
                            await self.updateStorageUsage()
                        }
                    } else if httpResponse.statusCode == 401 {
                        self.lastUploadStatus = "Session expired"
                        UserManager.shared.logout()
                    } else if httpResponse.statusCode == 413 {
                        self.lastUploadStatus = "Storage limit reached"
                    } else {
                        self.lastUploadStatus = "Upload failed: HTTP \(httpResponse.statusCode)"
                    }
                }
            }
        }
        
        task.resume()
    }
    
    private func updateStorageUsage() async {
        await VideoManager.shared.updateStorageInfo()
    }
}

// MARK: - Camera Recording Delegate
extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let error = error {
            return
        }
        
        let filename = outputFileURL.lastPathComponent
        if let chunkStr = filename.split(separator: "_").last?.split(separator: ".").first,
           let chunkNumber = Int(chunkStr) {
            compressAndUpload(videoURL: outputFileURL, chunkNumber: chunkNumber)
        }
    }
}

// MARK: - Camera Recording View
struct CameraRecordingView: View {
    @StateObject private var cameraManager = CameraManager()
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            CameraPreview(cameraManager: cameraManager)
                .ignoresSafeArea()
            
            VStack {
                HStack {
                    Button("Close") {
                        if cameraManager.isRecording {
                            cameraManager.stopRecording()
                        }
                        // Ensure screen sleep is restored
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            if !cameraManager.isRecording {
                                print("🔓 Ensuring screen sleep is restored on camera close")
                            }
                        }
                        dismiss()
                    }
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
                    
                    Spacer()
                    
                    if cameraManager.isUploading {
                        HStack {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                            Text("UPLOADING")
                                .foregroundColor(.white)
                                .font(.caption)
                        }
                        .padding(8)
                        .background(Color.blue.opacity(0.8))
                        .cornerRadius(8)
                    }
                }
                .padding()
                .padding(.top, 40)
                
                Spacer()
                
                if cameraManager.isRecording {
                    HStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 12, height: 12)
                            .opacity(cameraManager.isRecording ? 1 : 0)
                            .animation(.easeInOut(duration: 1).repeatForever(), value: cameraManager.isRecording)
                        
                        Text("RECORDING")
                            .foregroundColor(.red)
                            .font(.headline)
                            .bold()
                    }
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(10)
                }
                
                Spacer()
                
                Button(action: {
                    if cameraManager.isRecording {
                        cameraManager.stopRecording()
                    } else {
                        cameraManager.startRecording()
                    }
                }) {
                    Circle()
                        .fill(cameraManager.isRecording ? Color.red : Color.white)
                        .frame(width: 80, height: 80)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: 4)
                        )
                        .shadow(radius: 10)
                }
                .padding(.bottom, 80)
            }
        }
        .onAppear {
            cameraManager.setupCamera()
        }
        .onDisappear {
            // Ensure recording stops and screen sleep is restored if view disappears
            if cameraManager.isRecording {
                cameraManager.stopRecording()
                print("🔓 Camera view disappeared - ensuring recording stops")
            }
        }
    }
}

// MARK: - Camera Preview
struct CameraPreview: UIViewRepresentable {
    let cameraManager: CameraManager
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: UIScreen.main.bounds)
        cameraManager.preview = AVCaptureVideoPreviewLayer(session: cameraManager.session)
        cameraManager.preview?.frame = view.frame
        cameraManager.preview?.videoGravity = .resizeAspectFill
        view.layer.addSublayer(cameraManager.preview!)
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Video Library View
struct VideoLibraryView: View {
    @State private var password = ""
    @State private var videos: [VideoInfo] = []
    @State private var isLoading = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var selectedVideoForPlay: VideoInfo?
    @State private var selectedVideoForDelete: VideoInfo?
    @State private var showingDeleteAlert = false
    @State private var isPasswordEntered = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(.systemGray6).opacity(0.3),
                        Color.black.opacity(0.8),
                        Color(.systemGray2).opacity(0.4)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                if !isPasswordEntered {
                    VStack(spacing: 30) {
                        VStack(spacing: 15) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 60))
                                .foregroundColor(.white)
                            
                            Text("Enter Your Password")
                                .font(.largeTitle)
                                .bold()
                                .foregroundColor(.white)
                            
                            Text("Enter password to access recordings")
                                .foregroundColor(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                        }
                        
                        VStack(spacing: 20) {
                            SecureField("", text: $password, prompt: Text("6-Digit Password").foregroundColor(.white.opacity(0.7)))
                                .keyboardType(.numberPad)
                                .textFieldStyle(AuthTextFieldStyle())
                                .multilineTextAlignment(.center)
                                .font(.title)
                                .onChange(of: password) { newValue in
                                    if newValue.count > 6 {
                                        password = String(newValue.prefix(6))
                                    }
                                    password = newValue.filter { $0.isNumber }
                                    
                                    if newValue.count == 6 {
                                        authenticateAndLoad()
                                    }
                                }
                            
                            Button("Access Videos") {
                                authenticateAndLoad()
                            }
                            .disabled(password.count != 6)
                            .buttonStyle(CustomButtonStyle())
                        }
                        
                        Button("Cancel") {
                            dismiss()
                        }
                        .foregroundColor(.white.opacity(0.8))
                        
                        Spacer()
                    }
                    .padding()
                } else {
                    VStack {
                        if isLoading {
                            VStack {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                Text("Loading your videos...")
                                    .foregroundColor(.white)
                            }
                        } else if videos.isEmpty {
                            VStack(spacing: 20) {
                                Image(systemName: "video.slash")
                                    .font(.system(size: 60))
                                    .foregroundColor(.white.opacity(0.6))
                                Text("No recordings found")
                                    .font(.title2)
                                    .foregroundColor(.white.opacity(0.8))
                                Text("No recordings yet")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.6))
                            }
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 15) {
                                    ForEach(videos) { video in
                                        VideoCardView(
                                            video: video,
                                            onPlay: {
                                                selectedVideoForPlay = video
                                            },
                                            onDelete: {
                                                selectedVideoForDelete = video
                                                showingDeleteAlert = true
                                            }
                                        )
                                        .padding(.horizontal)
                                    }
                                }
                                .padding(.top)
                            }
                        }
                    }
                    .navigationTitle("My Recordings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Close") {
                                dismiss()
                            }
                            .foregroundColor(.white)
                        }
                    }
                }
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
            .alert("Delete Video", isPresented: $showingDeleteAlert) {
                Button("Cancel", role: .cancel) {
                    selectedVideoForDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let videoToDelete = selectedVideoForDelete {
                        deleteVideo(videoToDelete)
                    }
                }
            } message: {
                Text("Are you sure you want to delete this recording? This action cannot be undone.")
            }
        }
        .sheet(item: $selectedVideoForPlay) { video in
            VideoPlayerView(video: video)
        }
    }
    
    private func authenticateAndLoad() {
        guard let currentUser = UserManager.shared.currentUser,
              let credentials = UserManager.shared.getCurrentCredentials(),
              password == credentials.password else {
            errorMessage = "Incorrect password"
            showingError = true
            password = ""
            return
        }
        
        isPasswordEntered = true
        loadVideos()
    }
    
    private func loadVideos() {
        isLoading = true
        VideoManager.shared.fetchVideos { result in
            DispatchQueue.main.async {
                isLoading = false
                switch result {
                case .success(let fetchedVideos):
                    videos = fetchedVideos
                case .failure(let error):
                    errorMessage = error.localizedDescription
                    showingError = true
                }
            }
        }
    }
    
    private func deleteVideo(_ video: VideoInfo) {
        VideoManager.shared.deleteVideo(sessionId: video.sessionId) { success in
            DispatchQueue.main.async {
                if success {
                    // Reload videos and update storage
                    loadVideos()
                    Task {
                        await VideoManager.shared.updateStorageInfo()
                    }
                } else {
                    errorMessage = "Failed to delete video"
                    showingError = true
                }
                selectedVideoForDelete = nil
            }
        }
    }
}

// MARK: - Video Card View
struct VideoCardView: View {
    let video: VideoInfo
    let onPlay: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        VStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "video.fill")
                        .foregroundColor(.white)
                        .font(.title2)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(video.sessionName)
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        Text(video.date)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    
                    Spacer()
                }
            }
            
            HStack(spacing: 20) {
                Button(action: onPlay) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.title3)
                        Text("PLAY VIDEO")
                            .font(.subheadline)
                            .fontWeight(.bold)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.blue, Color.cyan]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(12)
                }
                
                Button(action: onDelete) {
                    Image(systemName: "trash.fill")
                        .font(.title3)
                        .foregroundColor(.white)
                        .frame(width: 50, height: 50)
                        .background(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.red, Color.pink]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(12)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 15)
                .fill(Color.white.opacity(0.15))
                .shadow(radius: 5)
        )
    }
}

// MARK: - Video Player View
struct VideoPlayerView: View {
    let video: VideoInfo
    @State private var isDownloading = false
    @State private var downloadProgress = 0.0
    @State private var downloadStatus = "Ready to download"
    @State private var localVideoURL: URL?
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var wasIdleTimerDisabled = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 20) {
                    if isDownloading {
                        VStack(spacing: 20) {
                            Image(systemName: "icloud.and.arrow.down")
                                .font(.system(size: 60))
                                .foregroundColor(.white)
                            
                            Text("Downloading Video...")
                                .foregroundColor(.white)
                                .font(.headline)
                            
                            ProgressView(value: downloadProgress, total: 1.0)
                                .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                                .scaleEffect(y: 3)
                                .padding(.horizontal, 40)
                            
                            Text(downloadStatus)
                                .foregroundColor(.white.opacity(0.8))
                                .font(.caption)
                                .multilineTextAlignment(.center)
                        }
                    } else if localVideoURL == nil {
                        VStack(spacing: 30) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 60))
                                .foregroundColor(.white)
                            
                            Text("Download to View")
                                .foregroundColor(.white)
                                .font(.title)
                                .bold()
                            
                            Text("This video will be downloaded to your device so you can watch it anytime, even offline.")
                                .foregroundColor(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                            
                            Button(action: {
                                downloadVideo()
                            }) {
                                HStack {
                                    Image(systemName: "icloud.and.arrow.down.fill")
                                    Text("Download Video")
                                        .fontWeight(.semibold)
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 55)
                                .background(
                                    LinearGradient(
                                        gradient: Gradient(colors: [Color.blue, Color.cyan]),
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .cornerRadius(15)
                            }
                            .padding(.horizontal, 40)
                        }
                    } else {
                        VStack(spacing: 20) {
                            VideoPlayer(player: player) {
                                VStack {
                                    Spacer()
                                    HStack {
                                        Spacer()
                                        VStack(alignment: .trailing) {
                                            Text("📱 Playing locally")
                                                .foregroundColor(.white)
                                                .font(.caption)
                                                .padding(8)
                                                .background(Color.green.opacity(0.8))
                                                .cornerRadius(8)
                                        }
                                        .padding()
                                    }
                                }
                            }
                            .frame(height: 400)
                            .cornerRadius(15)
                            .clipped()
                            .padding(.horizontal)
                            
                            VStack(spacing: 15) {
                                VStack(spacing: 5) {
                                    Text(video.sessionName)
                                        .foregroundColor(.white)
                                        .font(.headline)
                                        .multilineTextAlignment(.center)
                                    
                                    Text("Ready to play")
                                        .foregroundColor(.white.opacity(0.7))
                                        .font(.caption)
                                }
                                
                                HStack(spacing: 15) {
                                    Button(action: {
                                        player.seek(to: CMTime.zero)
                                        player.play()
                                        isPlaying = true
                                    }) {
                                        Image(systemName: "gobackward")
                                            .font(.title2)
                                            .foregroundColor(.white)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 50)
                                            .background(Color.blue.opacity(0.8))
                                            .cornerRadius(10)
                                    }
                                    
                                    Button(action: {
                                        if isPlaying {
                                            player.pause()
                                            isPlaying = false
                                        } else {
                                            player.play()
                                            isPlaying = true
                                        }
                                    }) {
                                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                            .font(.title2)
                                            .foregroundColor(.white)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 50)
                                            .background(isPlaying ? Color.orange.opacity(0.8) : Color.green.opacity(0.8))
                                            .cornerRadius(10)
                                    }
                                    
                                    Button(action: {
                                        deleteLocalVideo()
                                    }) {
                                        Image(systemName: "trash")
                                            .font(.title2)
                                            .foregroundColor(.white)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 50)
                                            .background(Color.red.opacity(0.8))
                                            .cornerRadius(10)
                                    }
                                    
                                    Button(action: {
                                        saveToPhotos()
                                    }) {
                                        Image(systemName: "square.and.arrow.down")
                                            .font(.title2)
                                            .foregroundColor(.white)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 50)
                                            .background(Color.purple.opacity(0.8))
                                            .cornerRadius(10)
                                    }
                                }
                            }
                            .padding()
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(15)
                            .padding(.horizontal)
                        }
                    }
                    
                    Spacer()
                }
            }
            .navigationTitle("Video Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        player.pause()
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
        }
        .onAppear {
            checkForLocalVideo()
        }
        .onDisappear {
            player.pause()
            
            // Restore screen sleep if it was changed during download
            if isDownloading {
                UIApplication.shared.isIdleTimerDisabled = wasIdleTimerDisabled
                print("🔓 Screen sleep restored on view dismiss")
            }
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
    }
    
    private func checkForLocalVideo() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localVideoPath = documentsPath.appendingPathComponent("downloaded_\(video.sessionId).mov")
        
        if FileManager.default.fileExists(atPath: localVideoPath.path) {
            localVideoURL = localVideoPath
            playLocalVideo()
        }
    }
    
    private func downloadVideo() {
        // Prevent screen sleep during download
        wasIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        print("🔒 Screen sleep disabled for download")
        
        isDownloading = true
        downloadProgress = 0.0
        downloadStatus = "Starting download..."
        
        VideoManager.shared.downloadVideo(sessionId: video.sessionId) { progress, status in
            DispatchQueue.main.async {
                downloadProgress = progress
                downloadStatus = status
            }
        } completion: { result in
            DispatchQueue.main.async {
                isDownloading = false
                
                // Restore screen sleep setting
                UIApplication.shared.isIdleTimerDisabled = self.wasIdleTimerDisabled
                print("🔓 Screen sleep restored after download")
                
                switch result {
                case .success(let url):
                    localVideoURL = url
                    downloadStatus = "Download complete!"
                    playLocalVideo()
                case .failure(let error):
                    errorMessage = error.localizedDescription
                    showingError = true
                    downloadStatus = "Download failed"
                }
            }
        }
    }
    
    private func playLocalVideo() {
        guard let videoURL = localVideoURL else { return }
        
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            DispatchQueue.main.async {
                self.errorMessage = "Video file not found"
                self.showingError = true
                self.localVideoURL = nil
            }
            return
        }
        
        do {
            let fileSize = try FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int64 ?? 0
            if fileSize == 0 {
                DispatchQueue.main.async {
                    self.errorMessage = "Video file is empty"
                    self.showingError = true
                    self.localVideoURL = nil
                }
                return
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Cannot read video file"
                self.showingError = true
                self.localVideoURL = nil
            }
            return
        }
        
        let playerItem = AVPlayerItem(url: videoURL)
        player.replaceCurrentItem(with: playerItem)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.player.play()
            self.isPlaying = true
        }
    }
    
    private func saveToPhotos() {
        guard let videoURL = localVideoURL else {
            DispatchQueue.main.async {
                self.errorMessage = "No video available to save"
                self.showingError = true
            }
            return
        }
        
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            DispatchQueue.main.async {
                self.errorMessage = "Video file not found"
                self.showingError = true
            }
            return
        }
        
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                DispatchQueue.main.async {
                    self.handlePhotoPermission(status: status, videoURL: videoURL)
                }
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                DispatchQueue.main.async {
                    self.handlePhotoPermissionLegacy(status: status, videoURL: videoURL)
                }
            }
        }
    }
    
    @available(iOS 14, *)
    private func handlePhotoPermission(status: PHAuthorizationStatus, videoURL: URL) {
        switch status {
        case .authorized, .limited:
            saveVideoToPhotoLibrary(videoURL: videoURL)
        case .denied:
            errorMessage = "Photo access denied. Go to Settings > Privacy > Photos to allow access."
            showingError = true
        case .restricted:
            errorMessage = "Photo access restricted by device policy."
            showingError = true
        case .notDetermined:
            errorMessage = "Photo permission not determined. Please try again."
            showingError = true
        @unknown default:
            errorMessage = "Unknown photo permission status."
            showingError = true
        }
    }
    
    private func handlePhotoPermissionLegacy(status: PHAuthorizationStatus, videoURL: URL) {
        switch status {
        case .authorized:
            saveVideoToPhotoLibrary(videoURL: videoURL)
        case .denied:
            errorMessage = "Photo access denied. Go to Settings > Privacy > Photos to allow access."
            showingError = true
        case .restricted:
            errorMessage = "Photo access restricted by device policy."
            showingError = true
        case .notDetermined:
            errorMessage = "Photo permission not determined. Please try again."
            showingError = true
        @unknown default:
            errorMessage = "Unknown photo permission status."
            showingError = true
        }
    }
    
    private func saveVideoToPhotoLibrary(videoURL: URL) {
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            request?.creationDate = Date()
        }) { success, error in
            DispatchQueue.main.async {
                if success {
                    self.errorMessage = "Video saved to Photos successfully!"
                    self.showingError = true
                } else if let error = error {
                    self.errorMessage = "Failed to save: \(error.localizedDescription)"
                    self.showingError = true
                } else {
                    self.errorMessage = "Failed to save video to Photos"
                    self.showingError = true
                }
            }
        }
    }
    
    private func deleteLocalVideo() {
        guard let videoURL = localVideoURL else { return }
        
        do {
            try FileManager.default.removeItem(at: videoURL)
            localVideoURL = nil
        } catch {
            // Handle error silently
        }
    }
}

// MARK: - Video Manager
class VideoManager {
    static let shared = VideoManager()
    
    private init() {}
    
    func fetchVideos(completion: @escaping (Result<[VideoInfo], Error>) -> Void) {
        guard let credentials = UserManager.shared.getCurrentCredentials() else {
            completion(.failure(NSError(domain: "Not logged in", code: 401)))
            return
        }
        
        guard let url = URL(string: ServerConfig.videosURL) else {
            completion(.failure(NSError(domain: "Invalid server configuration", code: 0)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15.0
        
        let body = [
            "email": credentials.email,
            "password": credentials.password
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 {
                    DispatchQueue.main.async {
                        UserManager.shared.logout()
                    }
                    completion(.failure(NSError(domain: "Session expired", code: 401)))
                    return
                } else if httpResponse.statusCode != 200 {
                    completion(.failure(NSError(domain: "Server error", code: httpResponse.statusCode)))
                    return
                }
            }
            
            guard let data = data else {
                completion(.failure(NSError(domain: "No response from server", code: 0)))
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let videosArray = json["videos"] as? [[String: Any]] {
                    
                    let videos = videosArray.compactMap { videoDict -> VideoInfo? in
                        guard let sessionId = videoDict["session_id"] as? String,
                              let sessionName = videoDict["session_name"] as? String,
                              let chunkCount = videoDict["chunk_count"] as? Int,
                              let date = videoDict["date"] as? String else {
                            return nil
                        }
                        return VideoInfo(sessionId: sessionId, sessionName: sessionName, chunkCount: chunkCount, date: date)
                    }
                    
                    completion(.success(videos))
                } else {
                    completion(.failure(NSError(domain: "Invalid server response", code: 0)))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
    
    // FIXED: Delete function with proper authentication
    func deleteVideo(sessionId: String, completion: @escaping (Bool) -> Void) {
        guard let credentials = UserManager.shared.getCurrentCredentials() else {
            completion(false)
            return
        }
        
        guard let url = URL(string: ServerConfig.deleteURL) else {
            completion(false)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "email": credentials.email,
            "password": credentials.password,
            "session_id": sessionId
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ Delete error: \(error)")
                completion(false)
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    print("✅ Video deleted successfully")
                    
                    // Update storage info after deletion
                    DispatchQueue.main.async {
                        Task {
                            await self.updateStorageInfo()
                        }
                    }
                    
                    completion(true)
                } else {
                    print("❌ Delete failed with status: \(httpResponse.statusCode)")
                    if let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errorMsg = json["error"] as? String {
                        print("❌ Delete error: \(errorMsg)")
                    }
                    completion(false)
                }
            } else {
                completion(false)
            }
        }.resume()
    }
    
    // NEW: Storage info update function
    @MainActor
    func updateStorageInfo() async {
        guard let credentials = UserManager.shared.getCurrentCredentials() else {
            print("❌ No credentials for storage update")
            return
        }
        guard let url = URL(string: ServerConfig.storageURL) else {
            print("❌ Invalid storage URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0
        
        let body = [
            "email": credentials.email,
            "password": credentials.password
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        
                        let storageUsed = json["storage_used"] as? Double ?? 0
                        let storageLimit = json["storage_limit"] as? Double ?? 1200 // 20 minutes default
                        let videoCount = json["video_count"] as? Int ?? 0
                        
                        print("✅ Storage update: \(storageUsed)s used / \(storageLimit)s limit (\(videoCount) videos)")
                        
                        // Update SubscriptionManager on main thread
                        await MainActor.run {
                            SubscriptionManager.shared.storageUsed = storageUsed
                            SubscriptionManager.shared.storageLimit = storageLimit
                            
                            // Force UI update
                            SubscriptionManager.shared.objectWillChange.send()
                        }
                    }
                } else {
                    print("❌ Storage info request failed with status: \(httpResponse.statusCode)")
                    if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errorMsg = errorJson["error"] as? String {
                        print("❌ Storage error: \(errorMsg)")
                    }
                }
            }
        } catch {
            print("❌ Failed to update storage info: \(error)")
        }
    }
    
    func downloadVideo(sessionId: String, progress: @escaping (Double, String) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let credentials = UserManager.shared.getCurrentCredentials() else {
            completion(.failure(NSError(domain: "Not logged in", code: 401)))
            return
        }
        
        guard let url = URL(string: "\(ServerConfig.downloadURL)/\(sessionId)") else {
            completion(.failure(NSError(domain: "Invalid URL", code: 0)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "email": credentials.email,
            "password": credentials.password
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        progress(0.1, "Getting download info...")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let data = data else {
                completion(.failure(NSError(domain: "No data", code: 0)))
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let chunks = json["chunks"] as? [[String: Any]] {
                    
                    let chunkInfos = chunks.compactMap { chunkDict -> ChunkInfo? in
                        guard let filename = chunkDict["filename"] as? String,
                              let downloadURL = chunkDict["download_url"] as? String,
                              let order = chunkDict["order"] as? Int else {
                            return nil
                        }
                        return ChunkInfo(filename: filename, downloadURL: downloadURL, order: order)
                    }.sorted { $0.order < $1.order }
                    
                    self.downloadChunks(chunkInfos: chunkInfos, sessionId: sessionId, progress: progress, completion: completion)
                    
                } else {
                    completion(.failure(NSError(domain: "Invalid download response", code: 0)))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
    
    private func downloadChunks(chunkInfos: [ChunkInfo], sessionId: String, progress: @escaping (Double, String) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let tempFolder = documentsPath.appendingPathComponent("temp_\(sessionId)")
        
        do {
            try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        } catch {
            completion(.failure(error))
            return
        }
        
        let group = DispatchGroup()
        var downloadedChunks: [URL] = Array(repeating: URL(fileURLWithPath: ""), count: chunkInfos.count)
        var hasError = false
        var downloadError: Error?
        
        progress(0.2, "Downloading \(chunkInfos.count) chunks...")
        
        for (index, chunkInfo) in chunkInfos.enumerated() {
            group.enter()
            
            guard let url = URL(string: chunkInfo.downloadURL) else {
                group.leave()
                continue
            }
            
            let localChunkURL = tempFolder.appendingPathComponent(chunkInfo.filename)
            
            let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
                defer { group.leave() }
                
                if let error = error {
                    downloadError = error
                    hasError = true
                    return
                }
                
                guard let tempURL = tempURL else {
                    downloadError = NSError(domain: "No temp URL", code: 0)
                    hasError = true
                    return
                }
                
                do {
                    if FileManager.default.fileExists(atPath: localChunkURL.path) {
                        try FileManager.default.removeItem(at: localChunkURL)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: localChunkURL)
                    downloadedChunks[index] = localChunkURL
                    
                    let progressValue = 0.2 + (0.6 * Double(index + 1) / Double(chunkInfos.count))
                    DispatchQueue.main.async {
                        progress(progressValue, "Downloaded chunk \(index + 1) of \(chunkInfos.count)")
                    }
                    
                } catch {
                    downloadError = error
                    hasError = true
                }
            }
            
            task.resume()
        }
        
        group.notify(queue: .global()) {
            if hasError {
                try? FileManager.default.removeItem(at: tempFolder)
                completion(.failure(downloadError ?? NSError(domain: "Download failed", code: 0)))
                return
            }
            
            DispatchQueue.main.async {
                progress(0.8, "Combining video chunks...")
            }
            
            self.combineVideoChunks(chunkURLs: downloadedChunks, sessionId: sessionId, tempFolder: tempFolder, progress: progress, completion: completion)
        }
    }
    
    private func combineVideoChunks(chunkURLs: [URL], sessionId: String, tempFolder: URL, progress: @escaping (Double, String) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let finalVideoURL = documentsPath.appendingPathComponent("downloaded_\(sessionId).mov")
        
        for chunkURL in chunkURLs {
            guard FileManager.default.fileExists(atPath: chunkURL.path) else {
                completion(.failure(NSError(domain: "Chunk file missing", code: 0)))
                return
            }
            
            do {
                let fileSize = try FileManager.default.attributesOfItem(atPath: chunkURL.path)[.size] as? Int64 ?? 0
                if fileSize == 0 {
                    completion(.failure(NSError(domain: "Empty chunk file", code: 0)))
                    return
                }
            } catch {
                completion(.failure(error))
                return
            }
        }
        
        // If only one chunk, just move it
        if chunkURLs.count == 1 {
            do {
                if FileManager.default.fileExists(atPath: finalVideoURL.path) {
                    try FileManager.default.removeItem(at: finalVideoURL)
                }
                
                try FileManager.default.copyItem(at: chunkURLs[0], to: finalVideoURL)
                try FileManager.default.removeItem(at: tempFolder)
                
                DispatchQueue.main.async {
                    progress(1.0, "Download complete!")
                    completion(.success(finalVideoURL))
                }
            } catch {
                completion(.failure(error))
            }
            return
        }
        
        // For multiple chunks, combine them using AVAssetExportSession
        progress(0.9, "Combining \(chunkURLs.count) chunks...")
        
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: CMPersistentTrackID()) else {
            completion(.failure(NSError(domain: "Failed to create video track", code: 0)))
            return
        }
        
        guard let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: CMPersistentTrackID()) else {
            completion(.failure(NSError(domain: "Failed to create audio track", code: 0)))
            return
        }
        
        var currentTime = CMTime.zero
        var hasValidContent = false
        
        for (index, chunkURL) in chunkURLs.enumerated() {
            let asset = AVAsset(url: chunkURL)
            
            let semaphore = DispatchSemaphore(value: 0)
            var loadingError: Error?
            
            asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
                defer { semaphore.signal() }
                
                var error: NSError?
                let tracksStatus = asset.statusOfValue(forKey: "tracks", error: &error)
                let durationStatus = asset.statusOfValue(forKey: "duration", error: &error)
                
                if tracksStatus == .failed || durationStatus == .failed {
                    loadingError = error ?? NSError(domain: "Failed to load asset", code: 0)
                }
            }
            
            let result = semaphore.wait(timeout: .now() + 10.0)
            if result == .timedOut {
                completion(.failure(NSError(domain: "Timeout loading video chunk", code: 0)))
                return
            }
            
            if let error = loadingError {
                print("Asset loading error for chunk \(index): \(error)")
                continue
            }
            
            guard asset.duration.seconds > 0 else {
                print("Skipping chunk \(index) - zero duration")
                continue
            }
            
            guard let assetVideoTrack = asset.tracks(withMediaType: .video).first else {
                print("Skipping chunk \(index) - no video track")
                continue
            }
            
            let timeRange = CMTimeRange(start: .zero, duration: asset.duration)
            
            do {
                try videoTrack.insertTimeRange(timeRange, of: assetVideoTrack, at: currentTime)
                
                if let assetAudioTrack = asset.tracks(withMediaType: .audio).first {
                    try audioTrack.insertTimeRange(timeRange, of: assetAudioTrack, at: currentTime)
                }
                
                currentTime = CMTimeAdd(currentTime, asset.duration)
                hasValidContent = true
                
            } catch {
                print("Error inserting chunk \(index): \(error)")
                continue
            }
        }
        	
        guard hasValidContent else {
            completion(.failure(NSError(domain: "No valid video content found", code: 0)))
            return
        }
        
        // BEST OPTION - No quality loss:
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {completion(.failure(NSError(domain: "Failed to create exporter", code: 0)))
            return
        }
        
        if FileManager.default.fileExists(atPath: finalVideoURL.path) {
            try? FileManager.default.removeItem(at: finalVideoURL)
        }
        
        exporter.outputURL = finalVideoURL
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = true
        
        progress(0.95, "Optimizing for fast playback...")
        
        exporter.exportAsynchronously {
            DispatchQueue.main.async {
                switch exporter.status {
                case .completed:
                    try? FileManager.default.removeItem(at: tempFolder)
                    progress(1.0, "Video ready to play!")
                    completion(.success(finalVideoURL))
                    
                case .failed:
                    let error = exporter.error ?? NSError(domain: "Export failed", code: 0)
                    completion(.failure(error))
                    
                case .cancelled:
                    completion(.failure(NSError(domain: "Export cancelled", code: 0)))
                    
                default:
                    completion(.failure(NSError(domain: "Unknown export status", code: 0)))
                }
            }
        }
    }
}
