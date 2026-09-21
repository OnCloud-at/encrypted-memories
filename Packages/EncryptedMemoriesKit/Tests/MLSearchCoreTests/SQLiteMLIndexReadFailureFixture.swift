import Foundation
import SQLite3
import Testing

/// Injects a native sqlite3_step failure without adding a hook to the production row loop.
enum SQLiteMLIndexReadFailureFixture {
    static func install(at url: URL) throws {
        var handle: OpaquePointer?
        try #require(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        // SQLite documents abs(Int64.min) as an integer-overflow error. Earlier rows remain readable.
        try #require(
            sqlite3_exec(
                handle,
                """
                ALTER TABLE ml_embeddings RENAME TO fixture_embeddings;
                CREATE VIEW ml_embeddings AS
                SELECT volume_id, node_id, model_identifier, model_version,
                       embedding_dimension, embedding_precision,
                       CASE WHEN node_id='fail' THEN abs(-9223372036854775808) ELSE vector END AS vector,
                       capture_time, indexed_at
                FROM fixture_embeddings;
                """,
                nil, nil, nil
            ) == SQLITE_OK)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try #require(
            sqlite3_prepare_v2(
                handle, "SELECT vector FROM ml_embeddings WHERE node_id='fail';", -1, &statement, nil
            ) == SQLITE_OK)
        try #require(sqlite3_step(statement) == SQLITE_ERROR)
    }
}
