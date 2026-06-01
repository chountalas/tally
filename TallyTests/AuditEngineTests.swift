import Foundation
import Testing
@testable import Tally

@Suite("Audit engine scoring")
struct AuditEngineTests {
    @Test func stableSubscriptionScoresLow() {
        let subscription = makeSubscription(
            name: "Netflix",
            price: 15.49,
            cadence: .monthly,
            confidence: 0.95,
            status: .active,
            tenure: 36
        )
        let score = AuditEngine.score(
            subscription: subscription,
            allActive: [subscription],
            transactions: []
        )
        #expect(score.cancelWorthiness < 30)
        #expect(score.action == .keep)
    }

    @Test func overlappingSubscriptionScoresHigher() {
        let netflix = makeSubscription(
            name: "Netflix",
            price: 15.49,
            cadence: .monthly,
            confidence: 0.95,
            status: .active,
            category: "Streaming"
        )
        let hulu = makeSubscription(
            name: "Hulu",
            price: 7.99,
            cadence: .monthly,
            confidence: 0.95,
            status: .active,
            category: "Streaming"
        )
        let score = AuditEngine.score(
            subscription: hulu,
            allActive: [netflix, hulu],
            transactions: []
        )
        #expect(score.cancelWorthiness >= 25)
    }

    @Test func priceIncreasedSubscriptionFlagged() {
        let subscription = makeSubscription(
            name: "Spotify",
            price: 11.99,
            cadence: .monthly,
            confidence: 0.9,
            status: .active,
            priceChange: 0.12
        )
        let score = AuditEngine.score(
            subscription: subscription,
            allActive: [subscription],
            transactions: []
        )
        #expect(score.cancelWorthiness >= 20)
    }

    @Test func actionThresholds() {
        #expect(AuditEngine.action(for: 10) == .keep)
        #expect(AuditEngine.action(for: 35) == .review)
        #expect(AuditEngine.action(for: 60) == .cancel)
    }

    private func makeSubscription(
        name: String,
        price: Double,
        cadence: SubscriptionCadence,
        confidence: Double = 0.9,
        status: SubscriptionStatus = .active,
        category: String = "Uncategorized",
        tenure: Int? = 24,
        priceChange: Double? = nil
    ) -> Subscription {
        let sub = Subscription(
            canonicalName: name,
            displayName: name,
            status: status,
            cadence: cadence,
            priceAmount: Decimal(price),
            priceCurrency: "USD",
            normalizedMonthlyAmount: Decimal(price),
            lastChargeDate: .now,
            predictedNextChargeDate: Calendar.current.date(
                byAdding: .month,
                value: 1,
                to: .now
            ),
            confidenceScore: confidence,
            serviceCategory: category
        )
        sub.tenureMonths = tenure
        sub.priceChangePercent = priceChange
        return sub
    }
}

@Suite("Dashboard metrics")
struct DashboardMetricsRegressionTests {
    @Test func spendChartsUseLinkedSubscriptionDebitsOnly() {
        let formatter = ISO8601DateFormatter()
        let subscription = makeSubscription(
            name: "Netflix",
            price: 19.99,
            cadence: .monthly,
            status: .active
        )
        let januaryDebit = makeTransaction(
            id: UUID(),
            date: formatter.date(from: "2025-01-05T00:00:00Z") ?? .now,
            amount: Decimal(string: "-19.99") ?? -19.99,
            subscriptionID: subscription.id
        )
        let januaryRefund = makeTransaction(
            id: UUID(),
            date: formatter.date(from: "2025-01-08T00:00:00Z") ?? .now,
            amount: Decimal(string: "19.99") ?? 19.99,
            subscriptionID: subscription.id
        )
        let februaryDebit = makeTransaction(
            id: UUID(),
            date: formatter.date(from: "2025-02-05T00:00:00Z") ?? .now,
            amount: Decimal(string: "-9.99") ?? -9.99,
            subscriptionID: subscription.id
        )
        let unrelatedDebit = makeTransaction(
            id: UUID(),
            date: formatter.date(from: "2025-02-08T00:00:00Z") ?? .now,
            amount: Decimal(string: "-2500.00") ?? -2500,
            subscriptionID: nil
        )

        let metrics = DashboardMetrics(
            subscriptions: [subscription],
            transactions: [januaryDebit, januaryRefund, februaryDebit, unrelatedDebit]
        )

        #expect(metrics.monthlySpend.count == 2)
        #expect(metrics.monthlySpend[0].totalSpend == Decimal(string: "19.99"))
        #expect(metrics.monthlySpend[1].totalSpend == Decimal(string: "9.99"))
        #expect(metrics.yearlySpend.count == 1)
        #expect(metrics.yearlySpend[0].totalSpend == Decimal(string: "29.98"))
    }

    @Test func spendChartsKeepHistoricalDebitsForFormerSubscriptions() {
        let formatter = ISO8601DateFormatter()
        let active = makeSubscription(
            name: "Netflix",
            price: 19.99,
            cadence: .monthly,
            status: .active
        )
        let former = makeSubscription(
            name: "Old SaaS",
            price: 49.99,
            cadence: .monthly,
            status: .former
        )

        let activeDebit = makeTransaction(
            id: UUID(),
            date: formatter.date(from: "2026-01-05T00:00:00Z") ?? .now,
            amount: Decimal(string: "-19.99") ?? -19.99,
            subscriptionID: active.id
        )
        let formerDebit = makeTransaction(
            id: UUID(),
            date: formatter.date(from: "2026-01-08T00:00:00Z") ?? .now,
            amount: Decimal(string: "-49.99") ?? -49.99,
            subscriptionID: former.id
        )

        let metrics = DashboardMetrics(
            subscriptions: [active, former],
            transactions: [activeDebit, formerDebit]
        )

        #expect(metrics.monthlyRunRate == active.normalizedMonthlyAmount)
        #expect(metrics.monthlySpend.first?.totalSpend == Decimal(string: "69.98"))
    }

    @Test func annualChangeFormatsDecimalPercentWithoutTruncatingToZero() {
        let formatter = ISO8601DateFormatter()
        let subscription = makeSubscription(
            name: "Netflix",
            price: 100,
            cadence: .annual,
            status: .active
        )
        let previous = makeTransaction(
            id: UUID(),
            date: formatter.date(from: "2025-01-05T00:00:00Z") ?? .now,
            amount: Decimal(string: "-100.00") ?? -100,
            subscriptionID: subscription.id
        )
        let current = makeTransaction(
            id: UUID(),
            date: formatter.date(from: "2026-01-05T00:00:00Z") ?? .now,
            amount: Decimal(string: "-50.00") ?? -50,
            subscriptionID: subscription.id
        )

        let metrics = DashboardMetrics(
            subscriptions: [subscription],
            transactions: [previous, current]
        )

        #expect(metrics.annualChange?.label == "50% YoY")
        #expect(metrics.annualChange?.isPositive == true)
    }

    @Test func monthlyChangeUsesAbsoluteAmountForDownNarrative() {
        let formatter = ISO8601DateFormatter()
        let subscription = makeSubscription(
            name: "Netflix",
            price: 100,
            cadence: .monthly,
            status: .active
        )
        let previous = makeTransaction(
            id: UUID(),
            date: formatter.date(from: "2026-01-05T00:00:00Z") ?? .now,
            amount: Decimal(string: "-100.00") ?? -100,
            subscriptionID: subscription.id
        )
        let current = makeTransaction(
            id: UUID(),
            date: formatter.date(from: "2026-02-05T00:00:00Z") ?? .now,
            amount: Decimal(string: "-50.00") ?? -50,
            subscriptionID: subscription.id
        )

        let metrics = DashboardMetrics(
            subscriptions: [subscription],
            transactions: [previous, current]
        )

        #expect(metrics.monthlyChange?.label == Decimal(50).currencyString())
        #expect(metrics.monthlyChange?.isPositive == true)
    }

    @MainActor
    @Test func dashboardMetricsProviderInvalidatesOnRevisionEvenWhenCountsMatch() {
        let provider = DashboardMetricsProvider()
        let transaction = makeTransaction(
            id: UUID(),
            date: .now,
            amount: Decimal(string: "-9.99") ?? -9.99
        )

        let original = makeSubscription(
            name: "Spotify",
            price: 9.99,
            cadence: .monthly,
            confidence: 0.88,
            status: .active
        )
        let revised = makeSubscription(
            name: "Spotify",
            price: 14.99,
            cadence: .monthly,
            confidence: 0.88,
            status: .active
        )

        let originalSnapshot = provider.snapshot(
            subscriptions: [original],
            transactions: [transaction],
            revision: .initial.advanced(at: .distantPast)
        )
        let revisedSnapshot = provider.snapshot(
            subscriptions: [revised],
            transactions: [transaction],
            revision: originalSnapshot.revision.advanced()
        )

        #expect(originalSnapshot.metrics.monthlyRunRate != revisedSnapshot.metrics.monthlyRunRate)
    }

    @MainActor
    @Test func dashboardContentSnapshotInvalidatesReviewPreviewsOnRevisionEvenWhenCountsMatch() {
        let provider = DashboardMetricsProvider()
        let original = makeSubscription(
            name: "Spotify",
            price: 9.99,
            cadence: .monthly,
            confidence: 0.42,
            status: .needsReview
        )
        let revised = makeSubscription(
            name: "Spotify Premium",
            price: 9.99,
            cadence: .monthly,
            confidence: 0.42,
            status: .needsReview
        )

        let originalSnapshot = provider.contentSnapshot(
            subscriptions: [original],
            transactions: [],
            revision: .initial.advanced(at: .distantPast)
        ) { subscription, _ in
            MerchantLearningPreview(
                mode: .rename,
                sourceCanonicalName: subscription.canonicalName,
                targetCanonicalName: subscription.displayName,
                rawMerchants: [subscription.displayName],
                affectedTransactionCount: 0,
                affectedImportCount: 0
            )
        }
        let revisedSnapshot = provider.contentSnapshot(
            subscriptions: [revised],
            transactions: [],
            revision: originalSnapshot.revision.advanced()
        ) { subscription, _ in
            MerchantLearningPreview(
                mode: .rename,
                sourceCanonicalName: subscription.canonicalName,
                targetCanonicalName: subscription.displayName,
                rawMerchants: [subscription.displayName],
                affectedTransactionCount: 0,
                affectedImportCount: 0
            )
        }

        #expect(
            originalSnapshot.reviewQueueSubscriptions.first?.displayName
                != revisedSnapshot.reviewQueueSubscriptions.first?.displayName
        )
        #expect(
            originalSnapshot.reviewPreviews.values.first?.targetCanonicalName
                != revisedSnapshot.reviewPreviews.values.first?.targetCanonicalName
        )
    }

    @Test func actNowItemsDescribeRenewalAndReasonContext() throws {
        let renewalDate = Calendar.current.date(byAdding: .day, value: 6, to: .now) ?? .now
        let spotify = makeSubscription(
            name: "Spotify",
            price: 11.99,
            cadence: .monthly,
            confidence: 0.94,
            status: .active,
            category: "Music"
        )
        spotify.predictedNextChargeDate = renewalDate

        let appleMusic = makeSubscription(
            name: "Apple Music",
            price: 10.99,
            cadence: .monthly,
            confidence: 0.94,
            status: .active,
            category: "Music"
        )
        appleMusic.predictedNextChargeDate = Calendar.current.date(
            byAdding: .day,
            value: 18,
            to: .now
        )

        let metrics = DashboardMetrics(
            subscriptions: [spotify, appleMusic],
            transactions: []
        )

        let item = try #require(
            metrics.actNowItems.first(where: { $0.subscriptionID == spotify.id })
        )
        #expect(item.action == .review)
        #expect(item.detail.contains("Renews"))
        #expect(item.detail.contains("Review because category overlap."))
    }

    @Test func actNowItemsDescribeSteadyRenewalsWhenNoRisksExist() throws {
        let renewalDate = Calendar.current.date(byAdding: .day, value: 12, to: .now) ?? .now
        let dropbox = makeSubscription(
            name: "Dropbox",
            price: 11.99,
            cadence: .monthly,
            confidence: 0.94,
            status: .active,
            category: "Storage"
        )
        dropbox.predictedNextChargeDate = renewalDate

        let metrics = DashboardMetrics(
            subscriptions: [dropbox],
            transactions: []
        )

        let item = try #require(metrics.actNowItems.first)
        #expect(item.action == .keep)
        #expect(item.detail.contains("Renews"))
        #expect(item.detail.contains("No risk signals detected."))
    }

    private func makeTransaction(
        id: UUID,
        date: Date,
        amount: Decimal,
        subscriptionID: UUID? = UUID()
    ) -> NormalizedTransaction {
        NormalizedTransaction(
            id: id,
            transactionDate: date,
            transactionAmount: amount,
            merchantRaw: "Netflix",
            merchantNormalized: "Netflix",
            currency: "USD",
            accountName: "Visa",
            category: "Streaming",
            memo: nil,
            importRecordID: UUID(),
            subscriptionID: subscriptionID
        )
    }

    private func makeSubscription(
        name: String,
        price: Double,
        cadence: SubscriptionCadence,
        confidence: Double = 0.9,
        status: SubscriptionStatus = .active,
        category: String = "Uncategorized",
        tenure: Int? = 24,
        priceChange: Double? = nil
    ) -> Subscription {
        let sub = Subscription(
            canonicalName: name,
            displayName: name,
            status: status,
            cadence: cadence,
            priceAmount: Decimal(price),
            priceCurrency: "USD",
            normalizedMonthlyAmount: Decimal(price),
            lastChargeDate: .now,
            predictedNextChargeDate: Calendar.current.date(
                byAdding: .month,
                value: 1,
                to: .now
            ),
            confidenceScore: confidence,
            serviceCategory: category
        )
        sub.tenureMonths = tenure
        sub.priceChangePercent = priceChange
        return sub
    }
}
