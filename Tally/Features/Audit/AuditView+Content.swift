import EventKit
import SwiftData
import SwiftUI

extension AuditView {
    var setupSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(currentMonthly, format: .currency(code: "USD"))
                    .font(Theme.Typography.displayLarge)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text("per month across \(activeSubscriptions.count) active subscriptions")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            if activeSubscriptions.isEmpty {
                VStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "target")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.Colors.textTertiary)
                    Text("Import transactions to detect subscriptions first.")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.section)
            } else {
                EditorialDivider()

                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    Text("Set your monthly target")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.textPrimary)

                    Text(targetMonthly, format: .currency(code: "USD"))
                        .font(Theme.Typography.displayMedium)
                        .foregroundStyle(Theme.Colors.accent)

                    Slider(value: $targetMonthly, in: 0...max(currentMonthly.doubleValue, 1), step: 5)
                        .tint(Theme.Colors.accent)
                }

                Button {
                    startAudit()
                } label: {
                    Text("Start audit")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.Colors.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    var auditContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Text(projectedMonthly, format: .currency(code: "USD"))
                        .font(Theme.Typography.displayLarge)
                        .foregroundStyle(
                            projectedMonthly <= Decimal(targetMonthly)
                                ? Theme.Colors.positive
                                : Theme.Colors.textPrimary
                        )
                        .contentTransition(.numericText())
                    Text("/ \(Decimal(targetMonthly).currencyString())")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }

                if !cancelledIDs.isEmpty {
                    Text("\(projectedAnnualSavings.currencyString()) annual savings")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.Colors.positive)
                }
            }
            .padding(.bottom, Theme.Spacing.xxl)
            .animation(Theme.Animation.smooth, value: cancelledIDs.count)

            EditorialDivider()
                .padding(.bottom, Theme.Spacing.xxl)

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("Your subscriptions")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.textPrimary)

                VStack(spacing: 0) {
                    ForEach(scores) { score in
                        HStack(spacing: Theme.Spacing.md) {
                            Button {
                                withAnimation(Theme.Animation.smooth) {
                                    if cancelledIDs.contains(score.subscriptionID) {
                                        cancelledIDs.remove(score.subscriptionID)
                                    } else {
                                        cancelledIDs.insert(score.subscriptionID)
                                    }
                                }
                            } label: {
                                Image(
                                    systemName: cancelledIDs.contains(score.subscriptionID)
                                        ? "xmark.circle.fill"
                                        : "circle"
                                )
                                .font(.title3)
                                .foregroundStyle(
                                    cancelledIDs.contains(score.subscriptionID)
                                        ? Theme.Colors.destructive
                                        : Theme.Colors.textTertiary
                                )
                            }
                            .buttonStyle(.plain)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(score.subscriptionName)
                                        .font(Theme.Typography.subheadline)
                                        .strikethrough(cancelledIDs.contains(score.subscriptionID))
                                        .foregroundStyle(
                                            cancelledIDs.contains(score.subscriptionID)
                                                ? Theme.Colors.textTertiary
                                                : Theme.Colors.textPrimary
                                        )
                                    Spacer()
                                    Text(score.monthlyAmount.currencyString())
                                        .font(Theme.Typography.price)
                                        .foregroundStyle(
                                            cancelledIDs.contains(score.subscriptionID)
                                                ? Theme.Colors.textTertiary
                                                : Theme.Colors.textPrimary
                                        )
                                }
                                Text(oneLiners[score.subscriptionID] ?? score.reasons.first ?? "")
                                    .font(Theme.Typography.footnote)
                                    .foregroundStyle(Theme.Colors.textTertiary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, Theme.Spacing.sm)

                        if score.id != scores.last?.id {
                            HairlineDivider()
                        }
                    }
                }
                .featureCard()
            }
            .padding(.bottom, Theme.Spacing.section)

            if !cancelledIDs.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    Text("Action plan")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.textPrimary)

                    VStack(spacing: 0) {
                        ForEach(cancelledSubscriptions) { sub in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Cancel \(sub.displayName)")
                                        .font(Theme.Typography.subheadline)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                    if let renewalDate = sub.predictedNextChargeDate {
                                        Text("Cancel by \(optimalCancelDate(before: renewalDate).shortDateString)")
                                            .font(Theme.Typography.footnote)
                                            .foregroundStyle(Theme.Colors.accent)
                                    }
                                }
                                Spacer()
                                Text(sub.normalizedMonthlyAmount.currencyString())
                                    .font(Theme.Typography.price)
                                    .foregroundStyle(Theme.Colors.destructive)
                            }
                            .padding(.vertical, Theme.Spacing.sm)

                            if sub.id != cancelledSubscriptions.last?.id {
                                HairlineDivider()
                            }
                        }
                    }
                    .featureCard()

                    Button {
                        Task { await createCancellationReminders() }
                    } label: {
                        Text("Add calendar reminders")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.Colors.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task { refreshCalendarStatus() }
        .alert(
            "Calendar Reminders",
            isPresented: Binding(
                get: { reminderInfo != nil || reminderError != nil },
                set: { newValue in
                    if !newValue {
                        reminderInfo = nil
                        reminderError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                reminderInfo = nil
                reminderError = nil
            }
        } message: {
            Text(reminderError ?? reminderInfo ?? "")
        }
    }

    private func startAudit() {
        let active = activeSubscriptions
        let rankedScores = AuditEngine.rankAll(subscriptions: subscriptions, transactions: transactions)
        let defaultOneLiners: [UUID: String] = Dictionary(uniqueKeysWithValues: rankedScores.compactMap { score in
            guard let subscription = active.first(where: { $0.id == score.subscriptionID }) else {
                return nil
            }

            return (
                score.subscriptionID,
                intelligenceService.fallbackOneLiner(
                    subscription: subscription,
                    score: score
                )
            )
        })

        scores = rankedScores
        withAnimation(Theme.Animation.smooth) {
            isAuditing = true
            oneLiners = defaultOneLiners
        }
    }

    private func optimalCancelDate(before renewalDate: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -1, to: renewalDate) ?? renewalDate
    }

    private func createCancellationReminders() async {
        refreshCalendarStatus()

        switch calendarStatus {
        case .notDetermined:
            do {
                _ = try await calendarService.requestAccess()
                refreshCalendarStatus()
            } catch {
                reminderError = error.localizedDescription
                return
            }

            guard calendarStatus == .fullAccess || calendarStatus == .writeOnly else {
                reminderError = RenewalCalendarError.accessDenied.localizedDescription
                return
            }
        case .fullAccess, .writeOnly:
            break
        case .denied, .restricted:
            reminderError = RenewalCalendarError.accessDenied.localizedDescription
            return
        @unknown default:
            reminderError = RenewalCalendarError.accessDenied.localizedDescription
            return
        }

        var created = 0
        for sub in cancelledSubscriptions {
            guard let renewalDate = sub.predictedNextChargeDate else { continue }
            let cancelDate = optimalCancelDate(before: renewalDate)
            do {
                try calendarService.createCancellationReminder(
                    for: sub,
                    cancelBy: cancelDate,
                    context: modelContext
                )
                created += 1
            } catch {
                reminderError = error.localizedDescription
                return
            }
        }

        if created > 0 {
            reminderInfo = "Added \(created) cancellation reminder\(created == 1 ? "" : "s") to Apple Calendar."
        }
    }

    private func refreshCalendarStatus() {
        calendarStatus = calendarService.authorizationStatus()
    }
}
