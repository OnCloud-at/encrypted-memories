import PhotosCore
import SwiftUI

extension View {
    /// Keeps `pressure` equal to the device storage level that the runtime state publishes. Settings on every
    /// platform use it for the "almost full" notice.
    public func observesStoragePressure(_ pressure: Binding<LibraryStoragePressure>) -> some View {
        task {
            for await snapshot in LibraryRuntimeState.shared.updates()
            where snapshot.storagePressure != pressure.wrappedValue {
                pressure.wrappedValue = snapshot.storagePressure
            }
        }
    }
}
