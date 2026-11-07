import Foundation

enum Links {
    static let appStoreID = "6792424131"
    static let privacyPolicy = URL(string: "https://chenghengsheng.top/opsdeck/privacy.html")!
    static let feedback = URL(string: "mailto:support@chenghengsheng.top?subject=OpsDeck%20Feedback")!
    static let appStoreProduct = URL(string: "https://apps.apple.com/app/id\(appStoreID)")!
    /// App Store 评价页（直接进入"写评论"）。
    static let appStoreReview = URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")!
}
