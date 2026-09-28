import DeviceRootCore
import Foundation
import ProtonDriveSDK

/// SDK 0.29.1 operations for the app-owned Computer or My files fallback.
/// Construct this only after the account Labs gate opens.
struct ProtonDriveDeviceRootTransport: DeviceRootSDKTransport {
    private let client: ProtonDriveClient
    private let stagingDirectory: URL
    private let ownerAddresses: Set<String>

    init(client: ProtonDriveClient, accountDataDirectory: URL, ownerAddresses: Set<String>) {
        self.client = client
        stagingDirectory = accountDataDirectory.appendingPathComponent("device-root-staging", isDirectory: true)
        self.ownerAddresses = Set(ownerAddresses.map { $0.lowercased() })
    }

    func devices() async throws -> [DeviceRootSDKListedDevice] {
        let collected = SDKEnumerationCollector<Device>()
        let devices: [Device]
        do {
            devices = try await SDKCancellableOperation.run { token in
                try await client.enumerateDevices(cancellationToken: token) { result in
                    collected.receive(result)
                }
                return try collected.collected()
            } cancel: { token in
                try? await client.cancelEnumerateDevices(cancellationToken: token)
            }
        } catch {
            let partial = collected.snapshot()
            if partial.elements.isEmpty, partial.failure == nil,
                let sdkError = error as? ProtonDriveSDKError,
                let httpCode = sdkError.asAPINetworkError?.httpCode,
                [404, 410, 501].contains(httpCode)
            {
                throw DeviceRootOperationError.unsupported
            }
            throw error
        }
        return devices.map { device in
            DeviceRootSDKListedDevice(
                deviceUID: device.uid.sdkCompatibleIdentifier,
                rootFolderUID: device.rootFolderUid.sdkCompatibleIdentifier,
                name: try? device.name.get())
        }
    }

    func createDevice(name: String) async throws -> DeviceRootSDKListedDevice {
        let device = try await SDKCancellableOperation.run { token in
            try await client.createDevice(
                name: name, type: .macOS, cancellationToken: token)
        } cancel: { token in
            try? await client.cancelCreateDevice(cancellationToken: token)
        }
        return DeviceRootSDKListedDevice(
            deviceUID: device.uid.sdkCompatibleIdentifier,
            rootFolderUID: device.rootFolderUid.sdkCompatibleIdentifier,
            name: try? device.name.get())
    }

    func myFilesFolders() async throws -> [DeviceRootSDKListedDevice] {
        let root = try await verifiedMyFilesRoot()
        var folders: [DeviceRootSDKListedDevice] = []
        for uid in try await folderChildren(root.uid) {
            guard let node = try await node(uid)
            else { throw DeviceRootOperationError.unknownOutcome }
            guard case .folder(let folder) = node else { continue }
            guard folder.parentUid?.sdkCompatibleIdentifier == root.uid.sdkCompatibleIdentifier
            else { throw DeviceRootOperationError.verificationFailed }
            folders.append(
                DeviceRootSDKListedDevice(
                    deviceUID: root.uid.sdkCompatibleIdentifier,
                    rootFolderUID: folder.uid.sdkCompatibleIdentifier,
                    name: try? folder.name.get(), location: .myFiles))
        }
        return folders
    }

    func createMyFilesFolder(name: String) async throws -> DeviceRootSDKListedDevice {
        let (root, folder) = try await DeviceRootCheckedMutation.afterLookup(
            lookup: { try await verifiedMyFilesRoot() },
            mutate: { root in
                let folder = try await SDKCancellableOperation.run { token in
                    try await client.createFolder(
                        parentFolderUid: root.uid, folderName: name,
                        lastModificationTime: Date(), cancellationToken: token)
                } cancel: { token in
                    try? await client.cancelCreateFolder(cancellationToken: token)
                }
                return (root, folder)
            })
        guard folder.parentUid?.sdkCompatibleIdentifier == root.uid.sdkCompatibleIdentifier,
            (try? folder.name.get()) == name,
            folder.trashTime == nil, folder.errors.isEmpty,
            DeviceRootClaimAuthorPolicy.accepts(folder.nameAuthor, ownerAddresses: ownerAddresses),
            DeviceRootClaimAuthorPolicy.accepts(folder.keyAuthor, ownerAddresses: ownerAddresses)
        else { throw DeviceRootOperationError.verificationFailed }
        return DeviceRootSDKListedDevice(
            deviceUID: root.uid.sdkCompatibleIdentifier,
            rootFolderUID: folder.uid.sdkCompatibleIdentifier,
            name: name, location: .myFiles)
    }

    private func verifiedMyFilesRoot() async throws -> FolderNode {
        let root = try await SDKCancellableOperation.run { token in
            try await client.getMyFilesRootFolder(cancellationToken: token)
        } cancel: { token in
            try? await client.cancelGetMyFilesRootFolder(cancellationToken: token)
        }
        guard root.trashTime == nil, root.errors.isEmpty else {
            throw DeviceRootOperationError.verificationFailed
        }
        return root
    }

    private func node(_ uid: SDKNodeUid) async throws -> DriveNode? {
        try await SDKCancellableOperation.run { token in
            try await client.getNode(nodeUid: uid, cancellationToken: token)
        } cancel: { token in
            try? await client.cancelGetNode(cancellationToken: token)
        }
    }

    private func folderChildren(_ folderUID: SDKNodeUid) async throws -> [SDKNodeUid] {
        let collected = SDKEnumerationCollector<SDKNodeUid>()
        return try await SDKCancellableOperation.run { token in
            try await client.enumerateFolderChildrenNodeUids(
                folderUid: folderUID, cancellationToken: token
            ) { result in
                collected.receive(result)
            }
            return try collected.collected()
        } cancel: { token in
            try? await client.cancelEnumerateFolderChildren(cancellationToken: token)
        }
    }

    func claim(for device: DeviceRootSDKListedDevice) async throws -> DeviceRootSDKClaimStatus {
        guard let folderUID = SDKNodeUid(sdkCompatibleIdentifier: device.rootFolderUID),
            case .folder(let folder) = try await node(folderUID),
            folder.trashTime == nil, folder.errors.isEmpty,
            device.location == .computer
                || folder.parentUid?.sdkCompatibleIdentifier == device.deviceUID
        else { return .unverified }

        var claimFile: FileNode?
        for uid in try await folderChildren(folderUID) {
            guard let node = try await node(uid) else {
                return .unverified
            }
            let name: String
            switch node {
            case .file(let file):
                guard let verifiedName = try? file.name.get() else { return .unverified }
                name = verifiedName
                if name.hasPrefix(SDKDeviceRootEnrollmentBackend.claimPrefix) {
                    guard claimFile == nil else { return .unverified }
                    claimFile = file
                }
            case .folder(let child):
                guard let verifiedName = try? child.name.get() else { return .unverified }
                name = verifiedName
                if name.hasPrefix(SDKDeviceRootEnrollmentBackend.claimPrefix) { return .unverified }
            case .album(let child):
                guard let verifiedName = try? child.name.get() else { return .unverified }
                name = verifiedName
                if name.hasPrefix(SDKDeviceRootEnrollmentBackend.claimPrefix) { return .unverified }
            case .photo(let child):
                guard let verifiedName = try? child.name.get() else { return .unverified }
                name = verifiedName
                if name.hasPrefix(SDKDeviceRootEnrollmentBackend.claimPrefix) { return .unverified }
            }
        }
        switch DeviceRootClaimFolderPolicy.disposition(
            hasClaim: claimFile != nil,
            nameAuthor: folder.nameAuthor,
            keyAuthor: folder.keyAuthor,
            ownerAddresses: ownerAddresses)
        {
        case .missing: return .missing
        case .unverified: return .unverified
        case .eligible: break
        }
        guard let claimFile else { return .unverified }
        guard claimFile.parentUid?.sdkCompatibleIdentifier == folderUID.sdkCompatibleIdentifier,
            claimFile.trashTime == nil, claimFile.errors.isEmpty,
            DeviceRootClaimAuthorPolicy.accepts(claimFile.nameAuthor, ownerAddresses: ownerAddresses),
            DeviceRootClaimAuthorPolicy.accepts(claimFile.keyAuthor, ownerAddresses: ownerAddresses),
            let contentAuthor = claimFile.activeRevision.contentAuthor,
            DeviceRootClaimAuthorPolicy.accepts(contentAuthor, ownerAddresses: ownerAddresses),
            let claimedSize = claimFile.activeRevision.claimedSize,
            claimedSize >= 0,
            claimedSize <= SDKDeviceRootEnrollmentBackend.maxClaimBytes,
            claimFile.activeRevision.storageSize >= 0,
            claimFile.activeRevision.storageSize <= 65_536,
            let filename = try? claimFile.name.get()
        else { return .unverified }

        let stream = DeviceRootClaimDownloadStream(
            limit: SDKDeviceRootEnrollmentBackend.maxClaimBytes)
        let result = try await SDKCancellableOperation.run { token in
            let operation = try await client.downloadToStreamOperation(
                revisionUid: claimFile.activeRevision.uid,
                outputStream: stream,
                cancellationToken: token,
                progressCallback: { _ in })
            return await operation.awaitDownloadCompletion()
        } cancel: { token in
            try? await client.cancelDownload(cancellationToken: token)
        }
        switch result {
        case .succeeded: break
        case .completedWithVerificationError: return .unverified
        case .pausedOnError(let error), .failed(let error): throw error
        }
        let bytes = stream.bytes()
        return .verified(filename: filename, bytes: bytes)
    }

    func uploadClaim(
        for device: DeviceRootSDKListedDevice, filename: String, bytes: Data,
        overrideExistingDraft: Bool
    ) async throws {
        guard let folderUID = SDKNodeUid(sdkCompatibleIdentifier: device.rootFolderUID),
            bytes.count <= SDKDeviceRootEnrollmentBackend.maxClaimBytes,
            filename.hasPrefix(SDKDeviceRootEnrollmentBackend.claimPrefix)
        else { throw DeviceRootOperationError.verificationFailed }
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let source = stagingDirectory.appendingPathComponent("upload-\(DeviceRootDigest.hex(bytes)).bin")
        try bytes.write(to: source, options: .atomic)
        _ = try await SDKCancellableOperation.run { token in
            try await client.uploadFile(
                parentFolderUid: folderUID,
                name: filename,
                url: source,
                fileSize: Int64(bytes.count),
                modificationDate: nil,
                mediaType: "application/json",
                thumbnails: [],
                overrideExistingDraft: overrideExistingDraft,
                cancellationToken: token,
                progressCallback: { _ in },
                onRetriableErrorReceived: { _ in })
        } cancel: { token in
            try? await client.cancelUpload(cancellationToken: token)
        }
    }
}

enum DeviceRootCheckedMutation {
    static func afterLookup<Root, Value>(
        lookup: () async throws -> Root,
        mutate: (Root) async throws -> Value
    ) async throws -> Value {
        let root = try await lookup()
        try Task.checkCancellation()
        return try await mutate(root)
    }
}

enum DeviceRootClaimAuthorPolicy {
    static func accepts(_ author: Author, ownerAddresses: Set<String>) -> Bool {
        guard author.signatureVerificationError == nil,
            let email = author.emailAddress
        else { return false }
        return ownerAddresses.contains(email.lowercased())
    }
}

enum DeviceRootClaimFolderPolicy {
    enum Disposition: Equatable {
        case missing
        case eligible
        case unverified
    }

    static func disposition(
        hasClaim: Bool, nameAuthor: Author, keyAuthor: Author,
        ownerAddresses: Set<String>
    ) -> Disposition {
        guard hasClaim else { return .missing }
        guard DeviceRootClaimAuthorPolicy.accepts(nameAuthor, ownerAddresses: ownerAddresses),
            DeviceRootClaimAuthorPolicy.accepts(keyAuthor, ownerAddresses: ownerAddresses)
        else { return .unverified }
        return .eligible
    }
}
