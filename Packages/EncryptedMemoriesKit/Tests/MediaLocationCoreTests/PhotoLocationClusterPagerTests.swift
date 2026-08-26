import PhotosCore
import Testing

@testable import MediaLocationCore

private func pagerUID(_ n: Int) -> PhotoUID {
    PhotoUID(volumeID: "volume", nodeID: "node-\(n)")
}

@Suite struct PhotoLocationClusterPagerTests {
    @Test func pagesPreserveOrderAndBoundMaterialization() throws {
        let uids = (0..<251).map(pagerUID)
        let pager = PhotoLocationClusterPager(uids: uids, pageSize: 120)

        #expect(pager.totalCount == 251)
        #expect(pager.pageCount == 3)
        let first = try #require(pager.page(at: 0))
        let second = try #require(pager.page(at: 1))
        let last = try #require(pager.page(at: 2))
        #expect(first.uids == Array(uids[0..<120]))
        #expect(second.uids == Array(uids[120..<240]))
        #expect(last.uids == Array(uids[240..<251]))
        #expect(first.hasPrevious == false)
        #expect(first.hasNext)
        #expect(last.hasPrevious)
        #expect(last.hasNext == false)
        #expect(pager.page(at: 3) == nil)
    }

    @Test func emptyClustersHaveOneEmptyPage() throws {
        let pager = PhotoLocationClusterPager(uids: [])
        let page = try #require(pager.page(at: 0))

        #expect(pager.pageCount == 1)
        #expect(page.uids.isEmpty)
        #expect(page.totalCount == 0)
        #expect(!page.hasPrevious)
        #expect(!page.hasNext)
    }
}
