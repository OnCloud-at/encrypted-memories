import Metal

/// One shared hardware floor for every Apple-platform Metal renderer.
public enum Metal3RuntimeCapability {
    public static func supports(device: MTLDevice) -> Bool {
        device.supportsFamily(.metal3)
    }

    public static func supportsDefaultDevice() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return supports(device: device)
    }
}
