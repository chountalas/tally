import Foundation
import SwiftData

@Model
final class Subscription {
    var id: UUID = UUID()
    var canonicalName: String = ""
    var displayName: String = ""
    var statusRawValue: String = SubscriptionStatus.needsReview.rawValue
    var libraryStateRawValue: String = SubscriptionLibraryState.suggested.rawValue
    var creationPathRawValue: String = SubscriptionCreationPath.imported.rawValue
    var cadenceRawValue: String = SubscriptionCadence.unknown.rawValue
    var priceAmount: Decimal = 0
    var priceCurrency: String = "USD"
    var normalizedMonthlyAmount: Decimal = 0
    var lastChargeDate: Date?
    var predictedNextChargeDate: Date?
    var confidenceScore: Double = 0
    var isUserConfirmed: Bool = false
    var serviceCategory: String?
    var detectionReason: String?
    var notes: String?
    var createdAt: Date = Date.now
    var calendarEventIdentifier: String?
    var lastCalendarSyncAt: Date?
    var lastNotificationScheduledAt: Date?
    var firstChargeDate: Date?
    var priceChangePercent: Double?
    var tenureMonths: Int?
    var merchantProfileID: UUID?
    var serviceIdentifier: String?
    var paymentMethodName: String?
    var websiteURL: String?
    var reminderDaysBefore: Int?
    var replacementSubscriptionID: UUID?

    init(
        id: UUID = UUID(),
        canonicalName: String,
        displayName: String,
        status: SubscriptionStatus,
        libraryState: SubscriptionLibraryState? = nil,
        creationPath: SubscriptionCreationPath = .imported,
        cadence: SubscriptionCadence,
        priceAmount: Decimal,
        priceCurrency: String,
        normalizedMonthlyAmount: Decimal,
        lastChargeDate: Date?,
        predictedNextChargeDate: Date?,
        confidenceScore: Double,
        isUserConfirmed: Bool = false,
        serviceCategory: String? = nil,
        detectionReason: String? = nil,
        notes: String? = nil,
        createdAt: Date = Date.now,
        calendarEventIdentifier: String? = nil,
        lastCalendarSyncAt: Date? = nil,
        lastNotificationScheduledAt: Date? = nil,
        firstChargeDate: Date? = nil,
        priceChangePercent: Double? = nil,
        tenureMonths: Int? = nil,
        merchantProfileID: UUID? = nil,
        serviceIdentifier: String? = nil,
        paymentMethodName: String? = nil,
        websiteURL: String? = nil,
        reminderDaysBefore: Int? = nil,
        replacementSubscriptionID: UUID? = nil
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.displayName = displayName
        statusRawValue = status.rawValue
        libraryStateRawValue = (libraryState ?? Subscription.libraryState(for: status)).rawValue
        creationPathRawValue = creationPath.rawValue
        cadenceRawValue = cadence.rawValue
        self.priceAmount = priceAmount
        self.priceCurrency = priceCurrency
        self.normalizedMonthlyAmount = normalizedMonthlyAmount
        self.lastChargeDate = lastChargeDate
        self.predictedNextChargeDate = predictedNextChargeDate
        self.confidenceScore = confidenceScore
        self.isUserConfirmed = isUserConfirmed
        self.serviceCategory = serviceCategory
        self.detectionReason = detectionReason
        self.notes = notes
        self.createdAt = createdAt
        self.calendarEventIdentifier = calendarEventIdentifier
        self.lastCalendarSyncAt = lastCalendarSyncAt
        self.lastNotificationScheduledAt = lastNotificationScheduledAt
        self.firstChargeDate = firstChargeDate
        self.priceChangePercent = priceChangePercent
        self.tenureMonths = tenureMonths
        self.merchantProfileID = merchantProfileID
        self.serviceIdentifier = serviceIdentifier
        self.paymentMethodName = paymentMethodName
        self.websiteURL = websiteURL
        self.reminderDaysBefore = reminderDaysBefore
        self.replacementSubscriptionID = replacementSubscriptionID
    }

    var status: SubscriptionStatus {
        get {
            let fallback = SubscriptionStatus(rawValue: statusRawValue) ?? .needsReview
            switch libraryState {
            case .confirmed, .manual:
                return fallback == .former ? .former : .active
            case .inactive:
                return .former
            case .suggested, .ignored:
                return .needsReview
            }
        }
        set {
            statusRawValue = newValue.rawValue
            if creationPath == .manual, newValue == .active {
                libraryState = .manual
            } else {
                libraryState = Subscription.libraryState(for: newValue)
            }
        }
    }

    var cadence: SubscriptionCadence {
        get { SubscriptionCadence(rawValue: cadenceRawValue) ?? .unknown }
        set { cadenceRawValue = newValue.rawValue }
    }

    var libraryState: SubscriptionLibraryState {
        get { SubscriptionLibraryState(rawValue: libraryStateRawValue) ?? .suggested }
        set {
            libraryStateRawValue = newValue.rawValue
            statusRawValue = Subscription.status(for: newValue).rawValue
        }
    }

    var creationPath: SubscriptionCreationPath {
        get { SubscriptionCreationPath(rawValue: creationPathRawValue) ?? .imported }
        set { creationPathRawValue = newValue.rawValue }
    }

    static func libraryState(for status: SubscriptionStatus) -> SubscriptionLibraryState {
        switch status {
        case .active:
            return .confirmed
        case .former:
            return .inactive
        case .needsReview:
            return .suggested
        }
    }

    private static func status(for libraryState: SubscriptionLibraryState) -> SubscriptionStatus {
        switch libraryState {
        case .confirmed, .manual:
            return .active
        case .inactive:
            return .former
        case .suggested, .ignored:
            return .needsReview
        }
    }
}

struct BillingCycleSnapshot: Equatable {
    enum Urgency: Equatable {
        case standard
        case approachingRenewal
        case overdue
    }

    let periodStart: Date
    let periodEnd: Date
    let elapsedDays: Int
    let remainingDays: Int
    let overdueDays: Int
    let totalDays: Int
    let fractionElapsed: Double
    let urgency: Urgency

    var compactProgressLabel: String {
        switch urgency {
        case .overdue:
            return "Renewal window passed"
        case .approachingRenewal:
            if remainingDays == 0 {
                return "Renews today"
            }
            if remainingDays == 1 {
                return "1 day left in cycle"
            }
            return "\(remainingDays)d left in cycle"
        case .standard:
            return "\(Int((fractionElapsed * 100).rounded()))% through cycle"
        }
    }

    var detailLabel: String {
        switch urgency {
        case .overdue:
            if overdueDays == 1 {
                return "Expected renewal was 1 day ago."
            }
            return "Expected renewal was \(overdueDays) days ago."
        case .approachingRenewal:
            if remainingDays == 0 {
                return "\(elapsedDays) of \(totalDays) days used - renewal is due today"
            }
            if remainingDays == 1 {
                return "\(elapsedDays) of \(totalDays) days used - 1 day left"
            }
            return "\(elapsedDays) of \(totalDays) days used - \(remainingDays)d left"
        case .standard:
            return "\(elapsedDays) of \(totalDays) days used - \(remainingDays)d left"
        }
    }
}

extension Subscription {
    func billingCycleSnapshot(
        asOf referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> BillingCycleSnapshot? {
        guard status != .former,
              cadence != .unknown else {
            return nil
        }

        let resolvedPeriodEnd: Date
        if let predictedNextChargeDate {
            resolvedPeriodEnd = predictedNextChargeDate
        } else if let lastChargeDate,
                  let derivedEnd = cadence.advance(lastChargeDate, using: calendar) {
            resolvedPeriodEnd = derivedEnd
        } else {
            return nil
        }

        let resolvedPeriodStart: Date
        if let lastChargeDate {
            resolvedPeriodStart = lastChargeDate
        } else if let cycleDays = cadence.cycleDays,
                  let derivedStart = calendar.date(
                    byAdding: .day,
                    value: -cycleDays,
                    to: resolvedPeriodEnd
                  ) {
            resolvedPeriodStart = derivedStart
        } else {
            return nil
        }

        let startOfPeriod = calendar.startOfDay(for: resolvedPeriodStart)
        let endOfPeriod = calendar.startOfDay(for: resolvedPeriodEnd)
        let today = calendar.startOfDay(for: referenceDate)
        let fallbackCycleDays = cadence.cycleDays ?? 30
        let totalDays = max(
            calendar.dateComponents([.day], from: startOfPeriod, to: endOfPeriod).day ?? fallbackCycleDays,
            1
        )
        let rawElapsedDays = calendar.dateComponents([.day], from: startOfPeriod, to: today).day ?? 0
        let rawRemainingDays = calendar.dateComponents([.day], from: today, to: endOfPeriod).day ?? 0
        let overdueDays = max(-rawRemainingDays, 0)
        let elapsedDays = min(max(rawElapsedDays, 0), totalDays)
        let remainingDays = max(rawRemainingDays, 0)
        let fractionElapsed = min(max(Double(elapsedDays) / Double(totalDays), 0), 1)

        let urgency: BillingCycleSnapshot.Urgency
        if overdueDays > 0 {
            urgency = .overdue
        } else if remainingDays <= 3 {
            urgency = .approachingRenewal
        } else {
            urgency = .standard
        }

        return BillingCycleSnapshot(
            periodStart: resolvedPeriodStart,
            periodEnd: resolvedPeriodEnd,
            elapsedDays: elapsedDays,
            remainingDays: remainingDays,
            overdueDays: overdueDays,
            totalDays: totalDays,
            fractionElapsed: fractionElapsed,
            urgency: urgency
        )
    }
}
