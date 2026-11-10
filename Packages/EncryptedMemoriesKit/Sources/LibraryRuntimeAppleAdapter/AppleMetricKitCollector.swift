#if canImport(MetricKit)
    import Foundation
    import MetricKit
    import PhotosCore

    /// The MetricKit subscriber of both apps. It keeps what MetricKit delivers on the device only: it counts the payloads
    /// for the support export and stores a bounded summary of each diagnostic (`MetricKitDiagnosticLog`). It opens no
    /// network connection and forwards no payload; the support file leaves the device only when the person sends it.
    ///
    /// MetricKit deprecates `MXDiagnosticPayload`, its diagnostics, `MXCallStackTree` and `MXMetaData` at SDK 27.3 in favor
    /// of `DiagnosticReport` (iOS and macOS 27.0 and later). The deployment target is 26.0, so this file reads the older
    /// classes. This is the only file to move to `DiagnosticReport` behind `#available(iOS 27.0, macOS 27.0, *)` when the
    /// deployment target reaches 27.
    public final class AppleMetricKitCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
        public static let shared = AppleMetricKitCollector()

        private let lock = NSLock()
        private var installed = false
        private let diagnostics: PhotoDiagnostics
        private let log: MetricKitDiagnosticLog

        init(diagnostics: PhotoDiagnostics = .shared, log: MetricKitDiagnosticLog = .shared) {
            self.diagnostics = diagnostics
            self.log = log
            super.init()
        }

        public func install() {
            let shouldInstall = lock.withLock { () -> Bool in
                guard !installed else { return false }
                installed = true
                return true
            }
            guard shouldInstall else { return }
            MXMetricManager.shared.add(self)
        }

        public func didReceive(_ payloads: [MXMetricPayload]) {
            Self.countMetricPayloads(payloads.count, in: diagnostics)
        }

        public func didReceive(_ payloads: [MXDiagnosticPayload]) {
            Self.countDiagnosticPayloads(payloads.count, in: diagnostics)
            for payload in payloads {
                for input in Self.inputs(from: payload) { log.record(input) }
            }
        }

        static func countMetricPayloads(_ count: Int, in diagnostics: PhotoDiagnostics) {
            diagnostics.increment("metrickit.metricPayloads", by: count)
            diagnostics.emit("MetricKit", ["metricPayloads": "\(count)"])
        }

        static func countDiagnosticPayloads(_ count: Int, in diagnostics: PhotoDiagnostics) {
            diagnostics.increment("metrickit.diagnosticPayloads", by: count)
            diagnostics.emit("MetricKit", ["diagnosticPayloads": "\(count)"])
        }

        /// The executable name of the running app. The Mac app's is `Encrypted Memories`, with a space, which the frames
        /// of the summary accept only for this exact name.
        private static let executableName = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String

        /// Reads the values of every diagnostic of a payload. It reads only the values that the summary may use. The
        /// mapping from `MXDiagnosticPayload` has no automated test: a payload cannot be built outside MetricKit.
        static func inputs(from payload: MXDiagnosticPayload) -> [MetricKitDiagnosticInput] {
            func input(
                _ kind: MetricKitDiagnosticInput.Kind, _ diagnostic: MXDiagnostic, _ tree: MXCallStackTree
            ) -> MetricKitDiagnosticInput {
                MetricKitDiagnosticInput(
                    kind: kind, rangeStart: payload.timeStampBegin, rangeEnd: payload.timeStampEnd,
                    appVersion: diagnostic.applicationVersion, appBuild: diagnostic.metaData.applicationBuildVersion,
                    osVersion: diagnostic.metaData.osVersion, callStackTreeJSON: tree.jsonRepresentation(),
                    appExecutableName: executableName)
            }
            var inputs: [MetricKitDiagnosticInput] = []
            for crash in payload.crashDiagnostics ?? [] {
                var item = input(.crash, crash, crash.callStackTree)
                item.exceptionType = crash.exceptionType?.intValue
                item.signal = crash.signal?.intValue
                item.terminationReason = crash.terminationReason
                inputs.append(item)
            }
            for hang in payload.hangDiagnostics ?? [] {
                var item = input(.hang, hang, hang.callStackTree)
                item.hangSeconds = hang.hangDuration.converted(to: .seconds).value
                inputs.append(item)
            }
            for exception in payload.cpuExceptionDiagnostics ?? [] {
                var item = input(.cpuException, exception, exception.callStackTree)
                item.cpuSeconds = exception.totalCPUTime.converted(to: .seconds).value
                item.sampledSeconds = exception.totalSampledTime.converted(to: .seconds).value
                inputs.append(item)
            }
            for exception in payload.diskWriteExceptionDiagnostics ?? [] {
                var item = input(.diskWriteException, exception, exception.callStackTree)
                item.writtenMegabytes = exception.totalWritesCaused.converted(to: .megabytes).value
                inputs.append(item)
            }
            #if !os(macOS)
                // MXAppLaunchDiagnostic has no macOS availability.
                for launch in payload.appLaunchDiagnostics ?? [] {
                    var item = input(.appLaunch, launch, launch.callStackTree)
                    item.launchSeconds = launch.launchDuration.converted(to: .seconds).value
                    inputs.append(item)
                }
            #endif
            return inputs
        }
    }
#endif
