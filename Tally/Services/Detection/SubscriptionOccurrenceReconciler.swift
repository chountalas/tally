import Foundation
import SwiftData

extension SubscriptionDetectionService {
    func reconcileOccurrences(
        for subscriptions: [Subscription],
        transactions: [NormalizedTransaction],
        detectionRun: DetectionRun,
        in context: ModelContext
    ) throws {
        let existingExpectations = try context.fetch(FetchDescriptor<SubscriptionScheduleExpectation>())
        let existingOccurrences = try context.fetch(FetchDescriptor<SubscriptionOccurrence>())
        var expectationsBySubscription = Dictionary(
            uniqueKeysWithValues: existingExpectations.map { ($0.subscriptionID, $0) }
        )
        let transactionsBySubscription = Dictionary(grouping: transactions.compactMap { transaction -> NormalizedTransaction? in
            transaction.subscriptionID == nil ? nil : transaction
        }, by: { $0.subscriptionID ?? UUID() })

        let coverage = AccountObservationCoverage(transactions: transactions)
        let existingEvidence = try context.fetch(FetchDescriptor<SubscriptionDetectionEvidence>())
        let evidenceByID = Dictionary(uniqueKeysWithValues: existingEvidence.map { ($0.id, $0) })
        let occurrencesBySubscription = Dictionary(grouping: existingOccurrences, by: \.subscriptionID)
        for subscription in subscriptions {
            let subscriptionOccurrences = occurrencesBySubscription[subscription.id] ?? []
            let linkedTransactions = (transactionsBySubscription[subscription.id] ?? [])
                .sorted { $0.transactionDate < $1.transactionDate }
            let expectation = expectationsBySubscription[subscription.id] ?? makeScheduleExpectation(
                for: subscription,
                linkedTransactions: linkedTransactions,
                context: context
            )
            expectationsBySubscription[subscription.id] = expectation
            updateScheduleExpectation(
                expectation,
                subscription: subscription,
                linkedTransactions: linkedTransactions
            )
            let previouslyMissedDates = Set(
                subscriptionOccurrences
                    .filter { $0.status == .missed }
                    .map { Calendar.current.startOfDay(for: $0.expectedDate) }
            )

            let oldEvidenceIDs = Set(subscriptionOccurrences.compactMap(\.evidenceID))
            for id in oldEvidenceIDs {
                if let evidence = evidenceByID[id] { context.delete(evidence) }
            }
            for occurrence in subscriptionOccurrences { context.delete(occurrence) }

            let occurrences = projectedOccurrences(
                for: subscription,
                expectation: expectation,
                linkedTransactions: linkedTransactions,
                coverage: coverage,
                detectionRun: detectionRun,
                in: context
            )
            let missedCount = occurrences.filter {
                $0.status == .missed &&
                    previouslyMissedDates.contains(Calendar.current.startOfDay(for: $0.expectedDate)) == false
            }.count
            if missedCount > 0 {
                subscription.confidenceScore = max(
                    0,
                    subscription.confidenceScore - min(0.3, Double(missedCount) * 0.08)
                )
            }
        }
    }
}

private extension SubscriptionDetectionService {
    func makeScheduleExpectation(
        for subscription: Subscription,
        linkedTransactions: [NormalizedTransaction],
        context: ModelContext
    ) -> SubscriptionScheduleExpectation {
        let expectation = SubscriptionScheduleExpectation(
            subscriptionID: subscription.id,
            cadence: subscription.cadence,
            interval: 1,
            anchorPolicy: anchorPolicy(for: subscription, linkedTransactions: linkedTransactions),
            dateToleranceBeforeDays: dateTolerance(for: subscription.cadence),
            dateToleranceAfterDays: dateTolerance(for: subscription.cadence),
            gracePeriodDays: graceWindow(for: subscription.cadence),
            confidence: subscription.confidenceScore,
            source: subscription.isUserConfirmed ? .confirmedSubscription : .detectedCandidate
        )
        context.insert(expectation)
        return expectation
    }

    func updateScheduleExpectation(
        _ expectation: SubscriptionScheduleExpectation,
        subscription: Subscription,
        linkedTransactions: [NormalizedTransaction]
    ) {
        expectation.cadence = subscription.cadence
        expectation.interval = 1
        expectation.anchorPolicy = anchorPolicy(for: subscription, linkedTransactions: linkedTransactions)
        expectation.anchorDay = anchorDay(for: subscription, linkedTransactions: linkedTransactions)
        expectation.anchorWeekday = anchorWeekday(for: subscription, linkedTransactions: linkedTransactions)
        expectation.dateToleranceBeforeDays = dateTolerance(for: subscription.cadence)
        expectation.dateToleranceAfterDays = dateTolerance(for: subscription.cadence)
        expectation.gracePeriodDays = graceWindow(for: subscription.cadence)
        expectation.confidence = subscription.confidenceScore
        expectation.updatedAt = .now
    }

    func projectedOccurrences(
        for subscription: Subscription,
        expectation: SubscriptionScheduleExpectation,
        linkedTransactions: [NormalizedTransaction],
        coverage: AccountObservationCoverage,
        detectionRun: DetectionRun,
        in context: ModelContext
    ) -> [SubscriptionOccurrence] {
        let expectedDates = projectedExpectedDates(
            for: subscription,
            expectation: expectation,
            linkedTransactions: linkedTransactions
        )
        var unmatchedTransactions = linkedTransactions
        var occurrences: [SubscriptionOccurrence] = []
        let schedule = BillingSchedule(cadence: subscription.cadence, dates: linkedTransactions.map(\.transactionDate))
        var previousAmount = linkedTransactions.first.map { abs($0.transactionAmount) } ?? subscription.priceAmount
        if linkedTransactions.count == 1 { previousAmount = subscription.priceAmount }

        for expectedDate in expectedDates {
            let expectedDay = Calendar.current.startOfDay(for: expectedDate)
            let windowStart = Calendar.current.date(
                byAdding: .day,
                value: -expectation.dateToleranceBeforeDays,
                to: expectedDay
            ) ?? expectedDay
            let windowEnd = Calendar.current.date(
                byAdding: .day,
                value: expectation.dateToleranceAfterDays,
                to: expectedDay
            ) ?? expectedDay
            let matchIndex = unmatchedTransactions.firstIndex { transaction in
                let transactionDay = Calendar.current.startOfDay(for: transaction.transactionDate)
                return (windowStart...windowEnd).contains(transactionDay)
            }
            let matchedTransaction = matchIndex.map { unmatchedTransactions.remove(at: $0) }
            let status = occurrenceStatus(
                windowEnd: windowEnd,
                matchedTransaction: matchedTransaction,
                subscription: subscription,
                expectation: expectation,
                expectedAmount: previousAmount,
                observedMissing: coverage.observesMissingPayment(expected: expectedDate, schedule: schedule, charges: linkedTransactions)
            )
            let evidence = occurrenceEvidence(
                status: status,
                subscription: subscription,
                transaction: matchedTransaction,
                expectedDate: expectedDate,
                detectionRun: detectionRun,
                context: context
            )
            let dateDelta = matchedTransaction.map {
                Calendar.current.dateComponents([.day], from: expectedDate, to: $0.transactionDate).day ?? 0
            }
            let amountDelta = matchedTransaction.flatMap {
                amountDeltaPercent(expected: previousAmount, actual: abs($0.transactionAmount))
            }
            let occurrence = SubscriptionOccurrence(
                subscriptionID: subscription.id,
                scheduleExpectationID: expectation.id,
                expectedDate: expectedDate,
                windowStartDate: windowStart,
                windowEndDate: windowEnd,
                matchedTransactionID: matchedTransaction?.id,
                status: status,
                observedDate: matchedTransaction?.transactionDate,
                observedAmount: matchedTransaction.map { abs($0.transactionAmount) },
                expectedAmount: previousAmount,
                dateDeltaDays: dateDelta,
                amountDeltaPercent: amountDelta,
                matchConfidence: matchedTransaction == nil ? 0 : 0.92,
                evidenceID: evidence?.id,
                createdByDetectionRunID: detectionRun.id
            )
            context.insert(occurrence)
            occurrences.append(occurrence)
            if let matchedTransaction { previousAmount = abs(matchedTransaction.transactionAmount) }
        }

        return occurrences
    }

    func projectedExpectedDates(
        for subscription: Subscription,
        expectation: SubscriptionScheduleExpectation,
        linkedTransactions: [NormalizedTransaction]
    ) -> [Date] {
        guard expectation.cadence != .unknown else {
            return []
        }

        let dates = linkedTransactions.map(\.transactionDate)
        guard let first = dates.min() ?? subscription.firstChargeDate ?? subscription.lastChargeDate else { return [] }
        let schedule = BillingSchedule(cadence: expectation.cadence, dates: dates.isEmpty ? [first] : dates)
        let cutoff = max(Calendar.current.startOfDay(for: .now), subscription.predictedNextChargeDate ?? first)
        return schedule.dates(from: Calendar.current.startOfDay(for: first), through: cutoff)
    }

    func occurrenceStatus(
        windowEnd: Date,
        matchedTransaction: NormalizedTransaction?,
        subscription: Subscription,
        expectation: SubscriptionScheduleExpectation,
        expectedAmount: Decimal,
        observedMissing: Bool
    ) -> SubscriptionOccurrenceStatus {
        if let matchedTransaction {
            if let delta = amountDeltaPercent(expected: expectedAmount, actual: abs(matchedTransaction.transactionAmount)),
               abs(delta) > max(0.12, expectation.confidence < 0.7 ? 0.2 : 0.12) {
                return .priceChanged
            }
            return .matched
        }

        let graceEnd = Calendar.current.date(
            byAdding: .day,
            value: expectation.gracePeriodDays,
            to: windowEnd
        ) ?? windowEnd
        return graceEnd < Date.now && observedMissing ? .missed : .pending
    }

    func occurrenceEvidence(
        status: SubscriptionOccurrenceStatus,
        subscription: Subscription,
        transaction: NormalizedTransaction?,
        expectedDate: Date,
        detectionRun: DetectionRun,
        context: ModelContext
    ) -> SubscriptionDetectionEvidence? {
        let decision: SubscriptionEvidenceDecision
        let factorKey: String
        let reason: String
        switch status {
        case .matched:
            decision = .occurrenceMatched
            factorKey = "occurrence_coverage"
            reason = "Expected payment matched an observed transaction."
        case .missed:
            decision = .occurrenceMissed
            factorKey = "missed_occurrence_penalty"
            reason = "No matching transaction appeared inside the expected payment window."
        case .priceChanged:
            decision = .priceChanged
            factorKey = "price_change_signal"
            reason = "A matched occurrence moved outside the learned amount tolerance."
        case .pending, .late, .early, .duplicateInCycle, .manualConfirmed, .manualRejected:
            return nil
        }

        let evidence = SubscriptionDetectionEvidence(
            detectionRunID: detectionRun.id,
            subscriptionID: subscription.id,
            candidateKey: "\(subscription.canonicalName):\(expectedDate.ISO8601Format())",
            decision: decision,
            confidence: transaction == nil ? 0.45 : 0.92,
            deterministicScore: transaction == nil ? 0.45 : 0.92,
            evidenceFactorsJSON: SubscriptionEvidenceJSON.encodeFactors([
                SubscriptionEvidenceFactor(
                    key: factorKey,
                    weight: 1,
                    score: transaction == nil ? 0.45 : 0.92,
                    source: "occurrence_reconciliation",
                    description: reason
                )
            ]),
            matchedTransactionIDsJSON: SubscriptionEvidenceJSON.encodeUUIDs(transaction.map { [$0.id] } ?? []),
            reason: reason
        )
        context.insert(evidence)
        return evidence
    }

    func dateTolerance(for cadence: SubscriptionCadence) -> Int {
        switch cadence {
        case .annual:
            return 14
        case .quarterly, .semiannual:
            return 7
        case .monthly:
            return 3
        case .biweekly:
            return 2
        case .weekly:
            return 1
        case .unknown:
            return 0
        }
    }

    func anchorPolicy(
        for subscription: Subscription,
        linkedTransactions: [NormalizedTransaction]
    ) -> SubscriptionAnchorPolicy {
        switch subscription.cadence {
        case .monthly, .quarterly, .semiannual:
            if linkedTransactions.count >= 2,
               BillingSchedule(cadence: subscription.cadence, dates: linkedTransactions.map(\.transactionDate)).isMonthEnd {
                return .endOfMonth
            }
            return .exactDayOfMonth
        case .annual:
            return .sameCalendarDate
        case .weekly, .biweekly:
            return .rollingInterval
        case .unknown:
            return .unknown
        }
    }

    func anchorDay(
        for subscription: Subscription,
        linkedTransactions: [NormalizedTransaction]
    ) -> Int? {
        let dates = linkedTransactions.map(\.transactionDate)
        return BillingSchedule(cadence: subscription.cadence,
                               dates: dates.isEmpty ? [subscription.lastChargeDate ?? .now] : dates).anchorDay
    }

    func anchorWeekday(
        for subscription: Subscription,
        linkedTransactions: [NormalizedTransaction]
    ) -> Int? {
        let date = linkedTransactions.last?.transactionDate ?? subscription.lastChargeDate
        return date.map { Calendar.current.component(.weekday, from: $0) }
    }

    internal func amountDeltaPercent(expected: Decimal, actual: Decimal) -> Double? {
        let expectedDouble = abs((expected as NSDecimalNumber).doubleValue)
        guard expectedDouble > 0 else {
            return nil
        }
        let actualDouble = abs((actual as NSDecimalNumber).doubleValue)
        return (actualDouble - expectedDouble) / expectedDouble
    }
}
