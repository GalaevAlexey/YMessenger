//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Lottie
import SignalServiceKit
import SignalUI
import StoreKit
import SwiftUI
import UIKit

class BackupSettingsViewController: HostingController<BackupSettingsView> {
    private let backupSubscriptionManager: BackupSubscriptionManager
    private let db: DB
    private let networkManager: NetworkManager

    private let viewModel: BackupSettingsViewModel

    init(
        backupSettingsStore: BackupSettingsStore,
        backupSubscriptionManager: BackupSubscriptionManager,
        dateProvider: @escaping DateProvider,
        db: DB,
        networkManager: NetworkManager
    ) {
        self.backupSubscriptionManager = backupSubscriptionManager
        self.db = db
        self.networkManager = networkManager

        self.viewModel = db.read { tx in
            let backupPlanViewModel = BackupPlanViewModel()

            let enabledState = BackupSettingsViewModel.EnabledState.load(
                backupSettingsStore: backupSettingsStore,
                dateProvider: dateProvider,
                db: db,
                tx: tx
            )

            return BackupSettingsViewModel(
                backupSettingsStore: backupSettingsStore,
                db: db,
                dateProvider: dateProvider,
                backupPlanViewModel: backupPlanViewModel,
                enabledState: enabledState
            )
        }

        super.init(wrappedView: BackupSettingsView(viewModel: viewModel))

        viewModel.backupPlanViewModel.actionBlocks = BackupPlanViewModel.ActionBlocks(
            loadBackupPlan: { [weak self] in
                guard let self else { throw OWSAssertionError("Loading backup plan, but lost self!") }
                return try await loadBackupPlan()
            },
            manageOrCancelPaidPlan: { [weak self] in
                guard let windowScene = self?.view.window?.windowScene else {
                    owsFailDebug("Missing window scene!")
                    return
                }

                Task {
                    try await AppStore.showManageSubscriptions(in: windowScene)
                }
            },
            resubscribeToPaidPlan: { [weak self] in
                self?.showChooseBackupPlan(initialPlanSelection: .free)
            },
            upgradeFromFreeToPaidPlan: { [weak self] in
                self?.showChooseBackupPlan(initialPlanSelection: .free)
            }
        )

        title = OWSLocalizedString(
            "BACKUPS_SETTINGS_TITLE",
            comment: "Title for the 'Backup' settings menu."
        )
    }

    required init?(coder: NSCoder) { owsFail("Not implemented!") }

    // MARK: -

    private func loadBackupPlan() async throws -> BackupPlanViewModel.BackupPlan {
        try await Task.sleep(nanoseconds: 2.clampedNanoseconds)

        let backupSubscriberID: Data? = db.read { tx in
            backupSubscriptionManager.getIAPSubscriberData(tx: tx)?.subscriberId
        }

        guard
            let backupSubscriberID,
            let backupSubscription = try await SubscriptionFetcher(networkManager: networkManager)
                .fetch(subscriberID: backupSubscriberID)
        else {
            return .free
        }

        let endOfCurrentPeriod = Date(timeIntervalSince1970: backupSubscription.endOfCurrentPeriod)

        switch backupSubscription.status {
        case .active, .pastDue:
            // `.pastDue` means that a renewal failed, but the payment
            // processor is automatically retrying. For now, assume it
            // may recover, and show it as paid. If it fails, it'll
            // become `.canceled` instead.
            if backupSubscription.cancelAtEndOfPeriod {
                return .paidButCanceled(expirationDate: endOfCurrentPeriod)
            }

            return .paid(
                price: backupSubscription.amount,
                renewalDate: endOfCurrentPeriod
            )
        case .canceled:
            // TODO: [Backups] Downgrade local state to the free plan, if necessary.
            // This might be the first place we learn, locally, that our
            // subscription has expired and we've been implicitly downgraded to
            // the free plan. Correspondingly, we should use this as a change to
            // set local state, if necessary. Make sure to log that state change
            // loudly!
            return .free
        case .incomplete, .unpaid, .unknown:
            // These are unexpected statuses, so we know that something
            // is wrong with the subscription. Consequently, we can show
            // it as free.
            owsFailDebug("Unexpected backup subscription status! \(backupSubscription.status)")
            return .free
        }
    }

    private func showChooseBackupPlan(
        initialPlanSelection: ChooseBackupPlanViewController.PlanSelection
    ) {
        guard let navigationController else {
            owsFailDebug("Missing nav controller!")
            return
        }

        ModalActivityIndicatorViewController.present(
            fromViewController: self
        ) { modal async -> Void in
            guard
                let paidPlanDisplayPrice = try? await self.backupSubscriptionManager
                    .subscriptionDisplayPrice()
            else {
                modal.dismiss()
                return
            }

            modal.dismiss {
                navigationController.pushViewController(
                    ChooseBackupPlanViewController(
                        initialPlanSelection: initialPlanSelection,
                        paidPlanDisplayPrice: paidPlanDisplayPrice
                    ),
                    animated: true
                )
            }
        }
    }
}

// MARK: -

private class BackupSettingsViewModel: ObservableObject {
    enum EnabledState {
        case enabled(BackupEnabledViewModel)
        case disabled

        static func load(
            backupSettingsStore: BackupSettingsStore,
            dateProvider: @escaping DateProvider,
            db: DB,
            tx: DBReadTransaction
        ) -> Self {
            let areBackupsEnabled = backupSettingsStore.areBackupsEnabled(tx: tx)

            if areBackupsEnabled == true {
                let lastBackupDate = backupSettingsStore.lastBackupDate(tx: tx)
                let lastBackupSizeBytes: UInt64? = backupSettingsStore.lastBackupSizeBytes(tx: tx)
                let backupFrequency = backupSettingsStore.backupFrequency(tx: tx)
                let shouldBackUpOnCellular = backupSettingsStore.shouldBackUpOnCellular(tx: tx)

                return .enabled(BackupEnabledViewModel(
                    backupSettingsStore: backupSettingsStore,
                    dateProvider: dateProvider,
                    db: db,
                    lastBackupDate: lastBackupDate,
                    lastBackupSizeBytes: lastBackupSizeBytes,
                    backupFrequency: backupFrequency,
                    shouldBackUpOnCellular: shouldBackUpOnCellular
                ))
            } else {
                return .disabled
            }
        }
    }

    private let backupSettingsStore: BackupSettingsStore
    private let dateProvider: DateProvider
    private let db: DB

    let backupPlanViewModel: BackupPlanViewModel
    @Published var enabledState: EnabledState

    init(
        backupSettingsStore: BackupSettingsStore,
        db: DB,
        dateProvider: @escaping DateProvider,
        backupPlanViewModel: BackupPlanViewModel,
        enabledState: EnabledState
    ) {
        self.backupSettingsStore = backupSettingsStore
        self.dateProvider = dateProvider
        self.db = db
        self.backupPlanViewModel = backupPlanViewModel
        self.enabledState = enabledState
    }

    func enableBackups() {
        guard case .disabled = enabledState else {
            owsFail("Attempting to enable backups, but they're already enabled!")
        }

        // TODO: Present "enable backups" flow
        db.write { tx in
            backupSettingsStore.setAreBackupsEnabled(true, tx: tx)
        }

        reloadState()
    }

    func disableBackups() {
        guard case .enabled = enabledState else {
            owsFail("Attempting to disabl backups, but they're already disabled!")
        }

        // TODO: Present "disable backups" flow
        db.write { tx in
            backupSettingsStore.setAreBackupsEnabled(false, tx: tx)
        }

        reloadState()
    }

    private func reloadState() {
        backupPlanViewModel.loadBackupPlan()
        enabledState = db.read { tx in
            return .load(
                backupSettingsStore: backupSettingsStore,
                dateProvider: dateProvider,
                db: db,
                tx: tx
            )
        }
    }
}

struct BackupSettingsView: View {
    @ObservedObject private var viewModel: BackupSettingsViewModel

    fileprivate init(viewModel: BackupSettingsViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        SignalList {
            SignalSection {
                BackupPlanView(viewModel: viewModel.backupPlanViewModel)
            }

            switch viewModel.enabledState {
            case .enabled(let backupEnabledViewModel):
                SignalSection {
                    Button {
                        backupEnabledViewModel.performManualBackup()
                    } label: {
                        Label {
                            Text(OWSLocalizedString(
                                "BACKUP_SETTINGS_MANUAL_BACKUP_BUTTON_TITLE",
                                comment: "Title for a button allowing users to trigger a manual backup."
                            ))
                        } icon: {
                            Image(uiImage: Theme.iconImage(.backup))
                                .resizable()
                                .frame(width: 24, height: 24)
                        }
                    }
                    .foregroundStyle(Color.Signal.label)
                } header: {
                    Text(OWSLocalizedString(
                        "BACKUP_SETTINGS_BACKUPS_ENABLED_SECTION_HEADER",
                        comment: "Header for a menu section related to settings for when Backups are enabled."
                    ))
                }

                SignalSection {
                    BackupEnabledView(viewModel: backupEnabledViewModel)
                }

                SignalSection {
                    Button {
                        viewModel.disableBackups()
                    } label: {
                        Text(OWSLocalizedString(
                            "BACKUP_SETTINGS_DISABLE_BACKUPS_BUTTON_TITLE",
                            comment: "Title for a button allowing users to turn off Backups."
                        ))
                        .foregroundStyle(Color.Signal.red)
                    }
                } footer: {
                    Text(OWSLocalizedString(
                        "BACKUP_SETTINGS_DISABLE_BACKUPS_BUTTON_FOOTER",
                        comment: "Footer for a menu section allowing users to turn off Backups."
                    ))
                    .foregroundStyle(Color.Signal.secondaryLabel)
                }
            case .disabled:
                SignalSection {
                    Button {
                        viewModel.enableBackups()
                    } label: {
                        Text(OWSLocalizedString(
                            "BACKUP_SETTINGS_REENABLE_BACKUPS_BUTTON_TITLE",
                            comment: "Title for a button allowing users to re-enable Backups, after it had been previously disabled."
                        ))
                    }
                } header: {
                    Text(OWSLocalizedString(
                        "BACKUP_SETTINGS_BACKUPS_DISABLED_SECTION_FOOTER",
                        comment: "Footer for a menu section related to settings for when Backups are disabled."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(Color.Signal.secondaryLabel)
                }
            }
        }
        .onAppear {
            viewModel.backupPlanViewModel.loadBackupPlan()
        }
    }
}

// MARK: -

private class BackupPlanViewModel: ObservableObject {
    enum BackupPlan {
        case free
        case paid(price: FiatMoney, renewalDate: Date)
        case paidButCanceled(expirationDate: Date)
    }

    enum BackupPlanLoadingState {
        case loading
        case loaded(BackupPlan)
        case networkError
        case genericError
    }

    struct ActionBlocks {
        let loadBackupPlan: () async throws -> BackupPlan
        let manageOrCancelPaidPlan: () -> Void
        let resubscribeToPaidPlan: () -> Void
        let upgradeFromFreeToPaidPlan: () -> Void
    }

    @Published var loadingState: BackupPlanLoadingState

    var actionBlocks: ActionBlocks! { willSet { owsPrecondition(actionBlocks == nil) } }
    private let loadingQueue: SerialTaskQueue

    init() {
        self.loadingState = .loading
        self.loadingQueue = SerialTaskQueue()
    }

    func loadBackupPlan() {
        loadingQueue.enqueue { @MainActor [self] in
            withAnimation {
                loadingState = .loading
            }

            let newLoadingState: BackupPlanLoadingState
            do {
                let backupPlan = try await actionBlocks.loadBackupPlan()
                newLoadingState = .loaded(backupPlan)
            } catch let error where error.isNetworkFailureOrTimeout {
                newLoadingState = .networkError
            } catch {
                newLoadingState = .genericError
            }

            withAnimation {
                loadingState = newLoadingState
            }
        }
    }

    func upgradeFromFreeToPaidPlan() {
        guard case .loaded(.free) = loadingState else {
            owsFail("Attempting to upgrade from free plan, but not on free plan!")
        }

        actionBlocks.upgradeFromFreeToPaidPlan()
    }

    func manageOrCancelPaidPlan() {
        guard case .loaded(.paid) = loadingState else {
            owsFail("Attempting to manage/cancel paid plan, but not on paid plan!")
        }

        actionBlocks.manageOrCancelPaidPlan()
    }

    func resubscribeToPaidPlan() {
        guard case .loaded(.paidButCanceled) = loadingState else {
            owsFail("Attempting to restart paid plan, but not on paid-but-canceled plan!")
        }

        actionBlocks.resubscribeToPaidPlan()
    }
}

private struct BackupPlanView: View {
    @ObservedObject var viewModel: BackupPlanViewModel

    var body: some View {
        switch viewModel.loadingState {
        case .loading:
            VStack(alignment: .center) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(1.5)
                    // Force SwiftUI to redraw this if it re-appears (e.g.,
                    // because the user retried loading) instead of reusing one
                    // that will have stopped animating.
                    .id(UUID())
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
        case .loaded(let backupPlan):
            LoadedView(
                viewModel: viewModel,
                backupPlan: backupPlan
            )
        case .networkError:
            VStack(alignment: .center) {
                Text(OWSLocalizedString(
                    "BACKUP_SETTINGS_BACKUP_PLAN_NETWORK_ERROR_TITLE",
                    comment: "Title for a view indicating we failed to fetch someone's Backup plan due to a network error."
                ))
                .font(.subheadline)
                .bold()
                .foregroundStyle(Color.Signal.secondaryLabel)

                Text(OWSLocalizedString(
                    "BACKUP_SETTINGS_BACKUP_PLAN_NETWORK_ERROR_MESSAGE",
                    comment: "Message for a view indicating we failed to fetch someone's Backup plan due to a network error."
                ))
                .font(.subheadline)
                .foregroundStyle(Color.Signal.secondaryLabel)

                Spacer().frame(height: 16)

                Button {
                    viewModel.loadBackupPlan()
                } label: {
                    Text(CommonStrings.retryButton)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background {
                    Capsule().fill(Color.Signal.secondaryFill)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 140)
        case .genericError:
            VStack(alignment: .center) {
                Text(OWSLocalizedString(
                    "BACKUP_SETTINGS_BACKUP_PLAN_GENERIC_ERROR_TITLE",
                    comment: "Title for a view indicating we failed to fetch someone's Backup plan due to an unexpected error."
                ))
                .font(.subheadline)
                .bold()
                .foregroundStyle(Color.Signal.secondaryLabel)

                Text(OWSLocalizedString(
                    "BACKUP_SETTINGS_BACKUP_PLAN_GENERIC_ERROR_MESSAGE",
                    comment: "Message for a view indicating we failed to fetch someone's Backup plan due to an unexpected error."
                ))
                .font(.subheadline)
                .foregroundStyle(Color.Signal.secondaryLabel)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 140)
        }
    }

    private struct LoadedView: View {
        let viewModel: BackupPlanViewModel
        let backupPlan: BackupPlanViewModel.BackupPlan

        var body: some View {
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Group {
                        switch backupPlan {
                        case .free:
                            Text(OWSLocalizedString(
                                "BACKUP_SETTINGS_BACKUP_PLAN_FREE_HEADER",
                                comment: "Header describing what the free backup plan includes."
                            ))
                        case .paid, .paidButCanceled:
                            Text(OWSLocalizedString(
                                "BACKUP_SETTINGS_BACKUP_PLAN_PAID_HEADER",
                                comment: "Header describing what the paid backup plan includes."
                            ))
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.Signal.secondaryLabel)

                    Spacer().frame(height: 8)

                    switch backupPlan {
                    case .free:
                        Text(OWSLocalizedString(
                            "BACKUP_SETTINGS_BACKUP_PLAN_FREE_DESCRIPTION",
                            comment: "Text describing the user's free backup plan."
                        ))
                    case .paid(let price, let renewalDate):
                        let renewalStringFormat = OWSLocalizedString(
                            "BACKUP_SETTINGS_BACKUP_PLAN_PAID_RENEWAL_FORMAT",
                            comment: "Text explaining when the user's paid backup plan renews. Embeds {{ the formatted renewal date }}."
                        )
                        let priceStringFormat = OWSLocalizedString(
                            "BACKUP_SETTINGS_BACKUP_PLAN_PAID_PRICE_FORMAT",
                            comment: "Text explaining the price of the user's paid backup plan. Embeds {{ the formatted price }}."
                        )

                        Text(String(
                            format: priceStringFormat,
                            CurrencyFormatter.format(money: price)
                        ))
                        Text(String(
                            format: renewalStringFormat,
                            DateFormatter.localizedString(from: renewalDate, dateStyle: .medium, timeStyle: .none)
                        ))
                    case .paidButCanceled(let expirationDate):
                        let expirationDateFutureString = OWSLocalizedString(
                            "BACKUP_SETTINGS_BACKUP_PLAN_PAID_BUT_CANCELED_FUTURE_EXPIRATION_FORMAT",
                            comment: "Text explaining that a user's paid plan, which has been canceled, will expire on a future date. Embeds {{ the formatted expiration date }}."
                        )

                        Text(OWSLocalizedString(
                            "BACKUP_SETTINGS_BACKUP_PLAN_PAID_BUT_CANCELED_DESCRIPTION",
                            comment: "Text describing that the user's paid backup plan has been canceled."
                        ))
                        .foregroundStyle(Color.Signal.red)
                        Text(String(
                            format: expirationDateFutureString,
                            DateFormatter.localizedString(from: expirationDate, dateStyle: .medium, timeStyle: .none)
                        ))
                    }

                    Spacer().frame(height: 16)

                    Button {
                        switch backupPlan {
                        case .free:
                            viewModel.upgradeFromFreeToPaidPlan()
                        case .paid:
                            viewModel.manageOrCancelPaidPlan()
                        case .paidButCanceled:
                            viewModel.resubscribeToPaidPlan()
                        }
                    } label: {
                        switch backupPlan {
                        case .free:
                            Text(OWSLocalizedString(
                                "BACKUP_SETTINGS_BACKUP_PLAN_FREE_ACTION_BUTTON_TITLE",
                                comment: "Title for a button allowing users to upgrade from a free to paid backup plan."
                            ))
                        case .paid:
                            Text(OWSLocalizedString(
                                "BACKUP_SETTINGS_BACKUP_PLAN_PAID_ACTION_BUTTON_TITLE",
                                comment: "Title for a button allowing users to manage or cancel their paid backup plan."
                            ))
                        case .paidButCanceled:
                            Text(OWSLocalizedString(
                                "BACKUP_SETTINGS_BACKUP_PLAN_PAID_BUT_CANCELED_ACTION_BUTTON_TITLE",
                                comment: "Title for a button allowing users to reenable a paid backup plan that has been canceled."
                            ))
                        }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .foregroundStyle(Color.Signal.label)
                    .padding(.top, 8)
                }

                Spacer()

                Image("backups-subscribed")
                    .frame(width: 56, height: 56)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
    }
}

// MARK: -

private class BackupEnabledViewModel: ObservableObject {
    private let backupSettingsStore: BackupSettingsStore
    private let dateProvider: DateProvider
    private let db: DB

    @Published private(set) var lastBackupDate: Date?
    @Published private(set) var lastBackupSizeBytes: UInt64?
    @Published private(set) var backupFrequency: BackupFrequency
    @Published private(set) var shouldBackUpOnCellular: Bool

    init(
        backupSettingsStore: BackupSettingsStore,
        dateProvider: @escaping DateProvider,
        db: DB,
        lastBackupDate: Date?,
        lastBackupSizeBytes: UInt64?,
        backupFrequency: BackupFrequency,
        shouldBackUpOnCellular: Bool
    ) {
        self.backupSettingsStore = backupSettingsStore
        self.dateProvider = dateProvider
        self.db = db

        self.lastBackupDate = lastBackupDate
        self.lastBackupSizeBytes = lastBackupSizeBytes
        self.backupFrequency = backupFrequency
        self.shouldBackUpOnCellular = shouldBackUpOnCellular
    }

    @MainActor
    func performManualBackup() {
        let newBackupDate = dateProvider()

        db.write { tx in
            backupSettingsStore.setLastBackupDate(newBackupDate, tx: tx)
        }
        lastBackupDate = newBackupDate
    }

    @MainActor
    func updateBackupFrequency(_ newBackupFrequency: BackupFrequency) {
        db.write { tx in
            backupSettingsStore.setBackupFrequency(newBackupFrequency, tx: tx)
        }
        backupFrequency = newBackupFrequency
    }

    @MainActor
    func updateShouldBackUpOnCellular(_ newShouldBackUpOnCellular: Bool) {
        db.write { tx in
            backupSettingsStore.setShouldBackUpOnCellular(newShouldBackUpOnCellular, tx: tx)
        }
        shouldBackUpOnCellular = newShouldBackUpOnCellular
    }
}

private struct BackupEnabledView: View {
    @ObservedObject var viewModel: BackupEnabledViewModel

    var body: some View {
        HStack {
            let lastBackupMessage: String? = {
                guard let lastBackupDate = viewModel.lastBackupDate else {
                    return nil
                }

                let lastBackupDateString = DateFormatter.localizedString(from: lastBackupDate, dateStyle: .medium, timeStyle: .none)
                let lastBackupTimeString = DateFormatter.localizedString(from: lastBackupDate, dateStyle: .none, timeStyle: .short)

                if Calendar.current.isDateInToday(lastBackupDate) {
                    let todayFormatString = OWSLocalizedString(
                        "BACKUP_SETTINGS_ENABLED_LAST_BACKUP_TODAY_FORMAT",
                        comment: "Text explaining that the user's last backup was today. Embeds {{ the time of the backup }}."
                    )

                    return String(format: todayFormatString, lastBackupTimeString)
                } else if Calendar.current.isDateInYesterday(lastBackupDate) {
                    let yesterdayFormatString = OWSLocalizedString(
                        "BACKUP_SETTINGS_ENABLED_LAST_BACKUP_YESTERDAY_FORMAT",
                        comment: "Text explaining that the user's last backup was yesterday. Embeds {{ the time of the backup }}."
                    )

                    return String(format: yesterdayFormatString, lastBackupTimeString)
                } else {
                    let pastFormatString = OWSLocalizedString(
                        "BACKUP_SETTINGS_ENABLED_LAST_BACKUP_PAST_FORMAT",
                        comment: "Text explaining that the user's last backup was in the past. Embeds 1:{{ the date of the backup }} and 2:{{ the time of the backup }}."
                    )

                    return String(format: pastFormatString, lastBackupDateString, lastBackupTimeString)
                }
            }()

            Text(OWSLocalizedString(
                "BACKUP_SETTINGS_ENABLED_LAST_BACKUP_LABEL",
                comment: "Label for a menu item explaining when the user's last backup occurred."
            ))
            Spacer()
            if let lastBackupMessage {
                Text(lastBackupMessage)
                    .foregroundStyle(Color.Signal.secondaryLabel)
            }
        }

        HStack {
            Text(OWSLocalizedString(
                "BACKUP_SETTINGS_ENABLED_BACKUP_SIZE_LABEL",
                comment: "Label for a menu item explaining the size of the user's backup."
            ))
            Spacer()
            if let lastBackupSizeBytes = viewModel.lastBackupSizeBytes {
                Text(lastBackupSizeBytes.formatted(.byteCount(style: .decimal)))
                    .foregroundStyle(Color.Signal.secondaryLabel)
            }
        }

        Picker(
            OWSLocalizedString(
                "BACKUP_SETTINGS_ENABLED_BACKUP_FREQUENCY_LABEL",
                comment: "Label for a menu item explaining the frequency of automatic backups."
            ),
            selection: Binding(
                get: { viewModel.backupFrequency },
                set: { viewModel.updateBackupFrequency($0) }
            )
        ) {
            ForEach(BackupFrequency.allCases) { frequency in
                let localizedString: String = switch frequency {
                case .daily: OWSLocalizedString(
                    "BACKUP_SETTINGS_ENABLED_BACKUP_FREQUENCY_DAILY",
                    comment: "Text describing that a user's backup will be automatically performed daily."
                )
                case .weekly: OWSLocalizedString(
                    "BACKUP_SETTINGS_ENABLED_BACKUP_FREQUENCY_WEEKLY",
                    comment: "Text describing that a user's backup will be automatically performed weekly."
                )
                case .monthly: OWSLocalizedString(
                    "BACKUP_SETTINGS_ENABLED_BACKUP_FREQUENCY_MONTHLY",
                    comment: "Text describing that a user's backup will be automatically performed monthly."
                )
                case .manually: OWSLocalizedString(
                    "BACKUP_SETTINGS_ENABLED_BACKUP_FREQUENCY_MANUALLY",
                    comment: "Text describing that a user's backup will only be performed manually."
                )
                }

                Text(localizedString).tag(frequency)
            }
        }

        HStack {
            Toggle(
                OWSLocalizedString(
                    "BACKUP_SETTINGS_ENABLED_BACKUP_ON_CELLULAR_LABEL",
                    comment: "Label for a toggleable menu item describing whether to make backups on cellular data."
                ),
                isOn: Binding(
                    get: { viewModel.shouldBackUpOnCellular },
                    set: { viewModel.updateShouldBackUpOnCellular($0) }
                )
            )
        }

        NavigationLink {
            Text(LocalizationNotNeeded("Coming soon!"))
        } label: {
            Text(OWSLocalizedString(
                "BACKUP_SETTINGS_ENABLED_VIEW_BACKUP_KEY_LABEL",
                comment: "Label for a menu item offering to show the user their backup key."
            ))
        }
    }
}

// MARK: -

#if DEBUG

private extension BackupSettingsViewModel {
    static func forPreview(
        backupPlanLoadResult: Result<BackupPlanViewModel.BackupPlan, Error>
    ) -> BackupSettingsViewModel {
        let backupSettingsStore = BackupSettingsStore()
        let dateProvider = { Date() }
        let db = InMemoryDB()

        let enabledState = db.write { tx in
            backupSettingsStore.setAreBackupsEnabled(true, tx: tx)
            backupSettingsStore.setLastBackupDate(Date().addingTimeInterval(-1 * .day), tx: tx)
            backupSettingsStore.setLastBackupSizeBytes(2_400_000_000, tx: tx)

            return BackupSettingsViewModel.EnabledState.load(
                backupSettingsStore: backupSettingsStore,
                dateProvider: dateProvider,
                db: db,
                tx: tx
            )
        }

        let backupPlanViewModel = BackupPlanViewModel()
        backupPlanViewModel.actionBlocks = BackupPlanViewModel.ActionBlocks(
            loadBackupPlan: {
                try! await Task.sleep(nanoseconds: 2.clampedNanoseconds)
                return try backupPlanLoadResult.get()
            },
            manageOrCancelPaidPlan: { print("Managing!") },
            resubscribeToPaidPlan: { print("Resubscribing!") },
            upgradeFromFreeToPaidPlan: { print("Upgrading!") }
        )

        return BackupSettingsViewModel(
            backupSettingsStore: backupSettingsStore,
            db: db,
            dateProvider: dateProvider,
            backupPlanViewModel: backupPlanViewModel,
            enabledState: enabledState
        )
    }
}

#Preview("Paid") {
    NavigationView {
        BackupSettingsView(viewModel: .forPreview(
            backupPlanLoadResult: .success(.paid(
                price: FiatMoney(currencyCode: "USD", value: 2.99),
                renewalDate: Date().addingTimeInterval(.week)
            ))
        ))
    }
}

#Preview("Free") {
    NavigationView {
        BackupSettingsView(viewModel: .forPreview(
            backupPlanLoadResult: .success(.free)
        ))
    }
}

#Preview("Expiring") {
    NavigationView {
        BackupSettingsView(viewModel: .forPreview(
            backupPlanLoadResult: .success(.paidButCanceled(
                expirationDate: Date().addingTimeInterval(.week)
            ))
        ))
    }
}

#Preview("Network Error") {
    NavigationView {
        BackupSettingsView(viewModel: .forPreview(
            backupPlanLoadResult: .failure(OWSHTTPError.networkFailure(.genericTimeout))
        ))
    }
}

#Preview("Generic Error") {
    NavigationView {
        BackupSettingsView(viewModel: .forPreview(
            backupPlanLoadResult: .failure(OWSGenericError(""))
        ))
    }
}

#endif
