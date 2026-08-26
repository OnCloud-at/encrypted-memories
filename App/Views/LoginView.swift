import DesignSystem
import DesignSystemCore
import PhotosCore
import SwiftUI

struct LoginView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            brand
                .padding(.bottom, 36)
            content
                .frame(maxWidth: 320)
            Spacer()
            footer
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var brand: some View {
        VStack(spacing: 14) {
            MemoriesBrandMark(height: 84)
            Text(ProductBrand.displayName)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(ProtonColor.textNorm)
            Text("login.tagline")
                .font(.system(size: 13))
                .foregroundStyle(ProtonColor.textWeak)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.auth {
        case .authenticating(let status):
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text(status)
                    .font(.system(size: 13))
                    .foregroundStyle(ProtonColor.textWeak)
                    .multilineTextAlignment(.center)
                Button(L10n.string("action.cancel")) { model.cancelSignIn() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProtonColor.textHint)
            }
        default:
            VStack(spacing: 14) {
                Button {
                    model.signIn()
                } label: {
                    Text(L10n.string("login.sign_in_button"))
                }
                .protonProminentGlassButton()

                if case .signedOut(let error?) = model.auth {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(ProtonColor.danger)
                        .multilineTextAlignment(.center)
                }

                Text("login.help_text")
                    .font(.system(size: 11))
                    .foregroundStyle(ProtonColor.textHint)
                    .multilineTextAlignment(.center)
                Text(L10n.string("login.account_requirement"))
                    .font(.system(size: 11))
                    .foregroundStyle(ProtonColor.textHint)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var footer: some View {
        Text(L10n.string("brand.independence_notice"))
            .font(.system(size: 11))
            .foregroundStyle(ProtonColor.textHint)
    }
}
