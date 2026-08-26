import Foundation
import Testing

// S3 - Vertex direct-write. The steady `render(...)` path writes each quad into the pooled ring buffer
// without an intermediate array or copy. The offscreen dissolve path keeps per-group arrays.
// Source checks cover the private buffer contract; runtime checks cover draw, instance, and texture counts.
@Suite struct MetalGridVertexDirectWriteTests {
    private func repoRoot() -> URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }

    private func renderer() -> String {
        let rel = "Packages/EncryptedMemoriesKit/Sources/MetalRenderingCore/MetalGridRenderer.swift"
        return (try? String(contentsOf: repoRoot().appendingPathComponent(rel), encoding: .utf8)) ?? ""
    }

    // The pooled path writes vertices directly into the ring buffer without a per-group array or memcpy.
    @Test func steadyPathDirectWritesIntoPooledRingWithoutPerGroupArrays() {
        let r = renderer()
        #expect(!r.isEmpty)
        #expect(r.contains("private func writeQuad(_ q: MetalGridQuad, into ptr: UnsafeMutablePointer<Vertex>)"))
        #expect(r.contains("assumingMemoryBound(to: Vertex.self)"))
        #expect(r.contains("writeQuad(q, into: cursor)"))
        // The pooled branch writes directly to the ring buffer without an intermediate vertex array.
        #expect(!r.contains("memcpy("), "the pooled path must write vertices directly, not memcpy a built array")
    }

    // The vertex layout is single-sourced (`quadVertices`), so the direct-write and transient paths can never
    // diverge, and the transient offscreen path still exists.
    @Test func vertexLayoutIsSingleSourcedAcrossBothPaths() {
        let r = renderer()
        #expect(
            r.contains(
                "private func quadVertices(_ q: MetalGridQuad) -> (Vertex, Vertex, Vertex, Vertex, Vertex, Vertex)"))
        #expect(r.contains("private func appendQuad(into verts: inout [Vertex], _ q: MetalGridQuad)"))
        // Both the pointer-writer and the array-appender delegate to the one layout function.
        let quadVerticesUses = r.components(separatedBy: "quadVertices(q)").count - 1
        #expect(quadVerticesUses >= 2, "writeQuad and appendQuad must both build vertices via quadVertices")
    }

    // Draw accounting is preserved: one draw call + one bind per group/quad, instances counted from quad count.
    @Test func drawInstanceAndBindCountsAreDerivedFromQuadCount() {
        let r = renderer()
        #expect(r.contains("vertexCount: quadCount * 6"), "shared-texture group draws quadCount*6 vertices")
        #expect(r.contains("instances += quadCount"))
        #expect(r.contains("instances += 1"))
        #expect(r.contains("vertexStart: i * 6, vertexCount: 6"), "per-quad draws six vertices at the quad offset")
        #expect(r.contains("drawCalls += 1"))
        #expect(r.contains("textureBinds += 1"))
    }
}
