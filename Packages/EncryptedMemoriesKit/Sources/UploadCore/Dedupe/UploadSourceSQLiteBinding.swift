import PhotosCore

extension SQLiteStoreConnection {
    /// Binds kind, identifier and resource from `first`, in that order. Call inside `withLock`.
    /// A failed bind records its own error and returns false without binding later fields or stepping the statement.
    func bindUploadSource(_ source: UploadSourceIdentity, to statement: OpaquePointer?, from first: Int32) -> Bool {
        do {
            try bindText(statement, first, source.kind.rawValue)
            try bindText(statement, first + 1, source.identifier)
            try bindText(statement, first + 2, source.resource.rawValue)
        } catch {
            return false
        }
        return true
    }
}
