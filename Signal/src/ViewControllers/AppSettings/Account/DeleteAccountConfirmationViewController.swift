//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

class DeleteAccountConfirmationViewController: OWSTableViewController2 {

    // Don't allow swipe to dismiss
    override var isModalInPresentation: Bool {
        get { true }
        set {}
    }

    private let appReadiness: AppReadinessSetter

    init(appReadiness: AppReadinessSetter) {
        self.appReadiness = appReadiness
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.leftBarButtonItem = .cancelButton(dismissingFrom: self)
        updateTableContents()
    }

    override func themeDidChange() {
        super.themeDidChange()
        updateTableContents()
    }

    func updateTableContents() {
        let contents = OWSTableContents()

        let headerSection = OWSTableSection()
        headerSection.hasBackground = false
        headerSection.add(.init(customCellBlock: { [weak self] in
            guard let self = self else { return UITableViewCell() }
            return self.buildHeaderCell()
        }))
        contents.add(headerSection)

        let deleteSection = OWSTableSection()
        deleteSection.hasBackground = false
        deleteSection.add(.init(customCellBlock: { [weak self] in
            guard let self = self else { return UITableViewCell() }
            let cell = OWSTableItem.newCell()
            cell.selectionStyle = .none
            let deleteButton = self.buildDeleteButton()
            cell.contentView.addSubview(deleteButton)
            deleteButton.autoPinEdgesToSuperviewMargins()
            return cell
        }))
        contents.add(deleteSection)

        self.contents = contents
    }

    func buildHeaderCell() -> UITableViewCell {
        let imageView = UIImageView(image: Theme.isDarkThemeEnabled ? #imageLiteral(resourceName: "delete-account-dark") : #imageLiteral(resourceName: "delete-account-light"))
        imageView.autoSetDimensions(to: CGSize(square: 112))
        let imageContainer = UIView()
        imageContainer.addSubview(imageView)
        imageView.autoPinEdge(toSuperviewEdge: .top)
        imageView.autoPinEdge(toSuperviewEdge: .bottom, withInset: 12)
        imageView.autoHCenterInSuperview()

        let titleLabel = UILabel()
        titleLabel.font = UIFont.dynamicTypeTitle2.semibold()
        titleLabel.textColor = Theme.primaryTextColor
        titleLabel.textAlignment = .center
        titleLabel.text = OWSLocalizedString(
            "DELETE_ACCOUNT_CONFIRMATION_TITLE",
            comment: "Title for the 'delete account' confirmation view."
        )

        let descriptionLabel = UILabel()
        descriptionLabel.numberOfLines = 0
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.font = .dynamicTypeSubheadline
        descriptionLabel.textColor = Theme.secondaryTextAndIconColor
        descriptionLabel.textAlignment = .center
        descriptionLabel.text = OWSLocalizedString(
            "DELETE_ACCOUNT_CONFIRMATION_DESCRIPTION",
            comment: "Description for the 'delete account' confirmation view."
        )

        let headerView = UIStackView(arrangedSubviews: [
            imageContainer,
            titleLabel,
            descriptionLabel
        ])
        headerView.axis = .vertical
        headerView.spacing = 12

        let cell = OWSTableItem.newCell()
        cell.contentView.addSubview(headerView)
        headerView.autoPinEdgesToSuperviewMargins()
        return cell
    }

    private func buildDeleteButton() -> UIView {
        let button = OWSButton(title: CommonStrings.deleteButton) { [weak self] in
            self?.didTapDelete()
        }
        button.dimsWhenHighlighted = true
        button.layer.cornerRadius = 8
        button.backgroundColor = .ows_accentRed
        button.setTitleColor(.white, for: .normal)
        button.setTitleColor(UIColor.white.withAlphaComponent(0.7), for: .highlighted)
        button.titleLabel?.font = UIFont.dynamicTypeBody.semibold()
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.autoSetDimension(.height, toSize: 48)
        return button
    }

    @objc
    private func didTapDelete() {
        guard SSKEnvironment.shared.reachabilityManagerRef.isReachable else {
            OWSActionSheets.showActionSheet(
                title: OWSLocalizedString(
                    "DELETE_ACCOUNT_CONFIRMATION_NO_INTERNET",
                    comment: "Title for the action sheet when you have no internet on the 'delete account confirmation' view controller."
                )
            )
            return
        }
        showDeletionConfirmUI_checkPayments()
    }

    private func showDeletionConfirmUI_checkPayments() {
        if SSKEnvironment.shared.paymentsHelperRef.arePaymentsEnabled,
           let paymentBalance = SUIEnvironment.shared.paymentsSwiftRef.currentPaymentBalance,
           !paymentBalance.amount.isZero {
            showDeleteAccountPaymentsConfirmationUI(paymentBalance: paymentBalance.amount)
        } else {
            showDeletionConfirmUI()
        }
    }

    private func showDeleteAccountPaymentsConfirmationUI(paymentBalance: TSPaymentAmount) {
        let title = OWSLocalizedString(
            "SETTINGS_DELETE_ACCOUNT_PAYMENTS_BALANCE_ALERT_TITLE",
            comment: "Title for the alert confirming whether the user wants transfer their payments balance before deleting their account.")

        let formattedBalance = PaymentsFormat.format(paymentAmount: paymentBalance,
                                                     isShortForm: false,
                                                     withCurrencyCode: true,
                                                     withSpace: true)
        let messageFormat = OWSLocalizedString(
            "SETTINGS_DELETE_ACCOUNT_PAYMENTS_BALANCE_ALERT_MESSAGE_FORMAT",
            comment: "Body for the alert confirming whether the user wants transfer their payments balance before deleting their account. Embeds: {{ the current payment balance }}.")
        let message = String(format: messageFormat, formattedBalance)

        let actionSheet = ActionSheetController( title: title, message: message)

        actionSheet.addAction(ActionSheetAction(title: OWSLocalizedString(
                                                    "SETTINGS_DELETE_ACCOUNT_PAYMENTS_BALANCE_ALERT_TRANSFER",
                                                    comment: "Button for transferring the user's payments balance before deleting their account."),
                                                style: .default
        ) { [weak self] _ in
            self?.transferPaymentsButton()
        })

        actionSheet.addAction(ActionSheetAction(title: OWSLocalizedString(
                                                    "SETTINGS_DELETE_ACCOUNT_PAYMENTS_BALANCE_ALERT_DONT_TRANSFER",
                                                    comment: "Button for to _not_ transfer the user's payments balance before deleting their account."),
                                                style: .destructive
        ) { [weak self] _ in
            self?.showDeletionConfirmUI()
        })

        actionSheet.addAction(OWSActionSheets.cancelAction)
        presentActionSheet(actionSheet)
    }

    private func transferPaymentsButton() {
        dismiss(animated: true) { [appReadiness] in
            guard let frontmostViewController = UIApplication.shared.frontmostViewController else {
                owsFailDebug("Could not identify frontmostViewController")
                return
            }
            guard let navigationController = frontmostViewController.navigationController else {
                owsFailDebug("Missing navigationController.")
                return
            }
            var viewControllers = navigationController.viewControllers
            _ = viewControllers.removeLast()
            viewControllers.append(PaymentsSettingsViewController(mode: .inAppSettings, appReadiness: appReadiness))
            viewControllers.append(PaymentsTransferOutViewController(transferAmount: nil))
            navigationController.setViewControllers(viewControllers, animated: true)
        }
    }

    private func showDeletionConfirmUI() {

        OWSActionSheets.showConfirmationAlert(
            title: OWSLocalizedString(
                "DELETE_ACCOUNT_CONFIRMATION_ACTION_SHEEET_TITLE",
                comment: "Title for the action sheet confirmation title of the 'delete account confirmation' view controller."
            ),
            message: OWSLocalizedString(
                "DELETE_ACCOUNT_CONFIRMATION_ACTION_SHEEET_MESSAGE",
                comment: "Title for the action sheet message of the 'delete account confirmation' view controller."
            ),
            proceedTitle: OWSLocalizedString(
                "DELETE_ACCOUNT_CONFIRMATION_ACTION_SHEEET_ACTION",
                comment: "Title for the action sheet 'delete' action of the 'delete account confirmation' view controller."
            ),
            proceedStyle: .destructive,
            proceedAction: { [weak self] _ in self?.deleteAccount() }
        )
    }

    private func deleteAccount() {
        Task {
            let overlayView = UIView()
            overlayView.backgroundColor = self.tableBackgroundColor.withAlphaComponent(0.9)
            overlayView.alpha = 0
            self.navigationController?.view.addSubview(overlayView)
            overlayView.autoPinEdgesToSuperviewEdges()

            let progressView = AnimatedProgressView(
                loadingText: OWSLocalizedString(
                    "DELETE_ACCOUNT_CONFIRMATION_IN_PROGRESS",
                    comment: "Indicates the work we are doing while deleting the account"
                )
            )
            self.navigationController?.view.addSubview(progressView)
            progressView.autoCenterInSuperview()

            progressView.startAnimating { overlayView.alpha = 1 }

            do {
                try await self.deleteDonationSubscriptionIfNecessary()
                try await self.unregisterAccount()
            } catch {
                owsFailDebug("Failed to unregister \(error)")

                progressView.stopAnimating(success: false) {
                    overlayView.alpha = 0
                } completion: {
                    overlayView.removeFromSuperview()
                    progressView.removeFromSuperview()

                    OWSActionSheets.showActionSheet(
                        title: OWSLocalizedString(
                            "DELETE_ACCOUNT_CONFIRMATION_DELETE_FAILED",
                            comment: "Title for the action sheet when delete failed on the 'delete account confirmation' view controller."
                        )
                    )
                }
            }
        }
    }

    private func deleteDonationSubscriptionIfNecessary() async throws {
        let activeSubscriptionId = SSKEnvironment.shared.databaseStorageRef.read {
            DonationSubscriptionManager.getSubscriberID(transaction: $0)
        }
        guard let activeSubscriptionId else {
            return
        }
        Logger.info("Found subscriber ID. Canceling subscription...")
        return try await DonationSubscriptionManager.cancelSubscription(for: activeSubscriptionId)
    }

    private func unregisterAccount() async throws -> Never {
        Logger.info("Unregistering...")
        try await DependenciesBridge.shared.registrationStateChangeManager.unregisterFromService()
    }

}
