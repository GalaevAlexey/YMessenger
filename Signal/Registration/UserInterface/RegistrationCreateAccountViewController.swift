//
//  RegistrationCreateAccountViewController.swift
//  Signal
//
//  Created by Jazzblood on 08/09/25.
//  Copyright © 2025 Open Whisper Systems. All rights reserved.
//


import Foundation
import SignalServiceKit
import SignalUI

class RegistrationCreateAccountViewController: OWSViewController {
    private weak var presenter: RegistrationPhoneNumberPresenter?

    init(presenter: RegistrationPhoneNumberPresenter) {
        self.presenter = presenter
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        owsFail("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let button = OWSFlatButton.primaryButtonForRegistration(title: "CREATE ACCOUNT", target: self, selector: #selector(createAccount))
        let stack = UIStackView(arrangedSubviews: [button])
        stack.axis = .vertical
        stack.alignment = .center
        view.addSubview(stack)
        stack.autoPinEdgesToSuperviewMargins()
    }

    @objc
    private func createAccount() {
        let randomNumber = Self.randomE164()
        presenter?.goToNextStep(withE164: randomNumber)
    }

    private static func randomE164() -> E164 {
        let country = PhoneNumberCountry.defaultValue
        // Use country calling code and random 10-digit national number.
        var digits = String(Int.random(in: 2...9))
        for _ in 0..<9 {
            digits.append(String(Int.random(in: 0...9)))
        }
        let e164String = country.plusPrefixedCallingCode + digits
        guard let e164 = E164(e164String) else {
            owsFail("Failed to generate random E164")
        }
        return e164
    }
}