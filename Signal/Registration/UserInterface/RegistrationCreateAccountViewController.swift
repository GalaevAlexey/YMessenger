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

        view.backgroundColor = Theme.backgroundColor

        let logoImageView = UIImageView(image: UIImage(named: "signal-logo-128"))
        logoImageView.contentMode = .scaleAspectFit
        view.addSubview(logoImageView)
        logoImageView.autoCenterInSuperview()
        logoImageView.autoSetDimensions(to: .square(128))

        let button = OWSFlatButton.primaryButtonForRegistration(title: "CREATE ACCOUNT", target: self, selector: #selector(createAccount))
        button.autoSetDimension(.height, toSize: 50)
        view.addSubview(button)
        button.autoPinEdge(toSuperviewSafeArea: .leading, withInset: 20)
        button.autoPinEdge(toSuperviewSafeArea: .trailing, withInset: 20)
        button.autoPinEdge(toSuperviewSafeArea: .bottom, withInset: 20)
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
