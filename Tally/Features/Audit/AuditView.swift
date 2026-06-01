import EventKit
import SwiftData
import SwiftUI

struct AuditView: View {
    @Query(sort: \Subscription.displayName) var subscriptions: [Subscription]
    @Query(sort: \NormalizedTransaction.transactionDate) var transactions: [NormalizedTransaction]
    @Environment(\.modelContext) var modelContext

    @State var targetMonthly: Double = 100
    @State var isAuditing = false
    @State var scores: [AuditScore] = []
    @State var cancelledIDs: Set<UUID> = []
    @State var oneLiners: [UUID: String] = [:]
    @State var isShowingCopilot = false
    @State var calendarService = RenewalCalendarService()
    @State var calendarStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @State var reminderInfo: String?
    @State var reminderError: String?

    let intelligenceService = AuditIntelligenceService()

    var activeSubscriptions: [Subscription] {
        subscriptions.filter { $0.status == .active }
    }

    var currentMonthly: Decimal {
        activeSubscriptions.reduce(.zero) { $0 + $1.normalizedMonthlyAmount }
    }

    var projectedMonthly: Decimal {
        activeSubscriptions
            .filter { !cancelledIDs.contains($0.id) }
            .reduce(.zero) { $0 + $1.normalizedMonthlyAmount }
    }

    var projectedAnnualSavings: Decimal {
        (currentMonthly - projectedMonthly) * 12
    }

    var cancelledSubscriptions: [Subscription] {
        subscriptions.filter { cancelledIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    EditorialPageHeader(
                        eyebrow: "Savings pass",
                        title: "Audit",
                        subtitle: "Compare the subscription roster against a target monthly spend and turn the result into cancellation reminders."
                    ) {
                        HStack(spacing: Theme.Spacing.lg) {
                            EditorialActionButton(title: "Ask", systemImage: "sparkle.magnifyingglass") {
                            isShowingCopilot = true
                            }

                            if isAuditing {
                                EditorialActionButton(title: "Reset", systemImage: "arrow.uturn.backward") {
                                    withAnimation(Theme.Animation.smooth) {
                                        isAuditing = false
                                        scores = []
                                        cancelledIDs = []
                                        oneLiners = [:]
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, Theme.Spacing.section)

                    if !isAuditing {
                        setupSection
                    } else {
                        auditContent
                    }
                }
                .editorialPage()
            }
            .background(Theme.Colors.bg)
            .sheet(isPresented: $isShowingCopilot) {
                SubscriptionCopilotSheet(
                    title: "Ask the Audit Copilot",
                    seedQuery: IntelligenceQuery(kind: .savingsReview, prompt: "What can I cancel?")
                )
            }
        }
    }
}
