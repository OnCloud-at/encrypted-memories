/// The share and link identities contained in one volume trash group.
struct VolumeTrashGroup: Decodable {
    let shareID: String
    let linkIDs: [String]

    enum CodingKeys: String, CodingKey {
        case shareID = "ShareID"
        case linkIDs = "LinkIDs"
    }
}
