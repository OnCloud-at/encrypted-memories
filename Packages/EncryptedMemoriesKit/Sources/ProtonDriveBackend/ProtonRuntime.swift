import ProtonCoreCryptoPatchedGoImplementation

/// Process-wide setup that the Proton crypto layer needs before its first use.
public enum ProtonRuntime {
    /// Wires ProtonCore's CryptoGo to the patched GopenPGP implementation. A host calls this once at launch, before any
    /// crypto runs.
    public static func prepareProcess() {
        injectDefaultCryptoImplementation()
    }
}
