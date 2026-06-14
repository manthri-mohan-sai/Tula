import Foundation
import LocalAuthentication
import SwiftUI

/// Manages app lock state using Face ID / Touch ID.
/// When enabled, the app requires biometric authentication on each
/// foreground return. Falls back to device passcode if biometrics fail.
enum AppLockManager {

    /// Whether biometric authentication is available on this device.
    static var isBiometricsAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Human-readable name for the biometric type ("Face ID" or "Touch ID").
    static var biometricTypeName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .none:      return "Passcode"
        case .faceID:    return "Face ID"
        case .touchID:   return "Touch ID"
        case .opticID:   return "Optic ID"
        @unknown default: return "Biometrics"
        }
    }

    /// SF Symbol name for the current biometric type.
    static var biometricIconName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .none:      return "lock.fill"
        case .faceID:    return "faceid"
        case .touchID:   return "touchid"
        case .opticID:   return "opticid"
        @unknown default: return "lock.fill"
        }
    }

    /// Attempts biometric authentication. Falls back to device passcode
    /// if biometrics are unavailable or fail.
    static func authenticate() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Enter Passcode"

        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock Tula to view your expenses"
            )
        } catch {
            return false
        }
    }
}

/// Overlay view shown when the app is locked. Displays a blurred
/// background with a lock icon and "Unlock" button.
struct AppLockView: View {
    let onUnlock: () -> Void

    @State private var isAuthenticating = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: Spacing.xl) {
                Spacer()

                Text("तुला")
                    .font(.system(size: 80, weight: .bold))
                    .foregroundStyle(Color.tulaBrandFallback.opacity(0.3))

                Image(systemName: AppLockManager.biometricIconName)
                    .font(.system(size: 48))
                    .foregroundStyle(Color.tulaBrandFallback)
                    .padding(.bottom, Spacing.sm)

                Text("Tula is Locked")
                    .font(.title3.weight(.semibold))

                Text("Use \(AppLockManager.biometricTypeName) to unlock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    unlock()
                } label: {
                    Text("Unlock")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 200)
                        .padding(.vertical, Spacing.md)
                        .background(Color.tulaBrandFallback, in: RoundedRectangle(cornerRadius: CornerRadius.medium))
                }
                .disabled(isAuthenticating)

                Spacer()
                Spacer()
            }
        }
        .onAppear { unlock() }
    }

    private func unlock() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        Task {
            let success = await AppLockManager.authenticate()
            await MainActor.run {
                isAuthenticating = false
                if success { onUnlock() }
            }
        }
    }
}
