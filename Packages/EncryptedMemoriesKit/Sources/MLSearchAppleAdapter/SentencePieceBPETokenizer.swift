import Foundation
import MLSearchCore

public enum SentencePieceBPETokenizerError: Error, Equatable {
    case invalidVocabulary
    case unsupportedType(String)
}

/// SentencePiece BPE tokenizer driven by the verified artifact vocabulary and flags.
///
/// Supports optional lowercasing, space escaping, score-based merges, byte fallback,
/// and fixed-length special-token padding.
public final class SentencePieceBPETokenizer: MLTextTokenizer, @unchecked Sendable {
    private struct Document: Decodable {
        struct Piece: Decodable {
            let piece: String
            let score: Float
        }

        let type: String
        let contextLength: Int
        let padID: Int32
        let bosID: Int32?
        let eosID: Int32?
        let unkID: Int32
        let addBOS: Bool
        let addEOS: Bool
        /// SigLIP-family canonical preprocessing lowercases text before segmentation.
        let lowercase: Bool?
        let pieces: [Piece]

        private enum CodingKeys: String, CodingKey {
            case type
            case contextLength = "context_length"
            case padID = "pad_id"
            case bosID = "bos_id"
            case eosID = "eos_id"
            case unkID = "unk_id"
            case addBOS = "add_bos"
            case addEOS = "add_eos"
            case lowercase
            case pieces
        }
    }

    private struct Candidate {
        let id: Int32
        let score: Float
    }

    public let contextLength: Int

    private let piecesByText: [String: Candidate]
    private let byteFallbackIDs: [Int32]  // 256 entries, or empty when unavailable
    private let padID: Int32
    private let bosID: Int32?
    private let eosID: Int32?
    private let unkID: Int32
    private let addBOS: Bool
    private let addEOS: Bool
    private let lowercases: Bool

    public init(data: Data) throws {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw SentencePieceBPETokenizerError.invalidVocabulary
        }
        guard document.type == "sentencepiece-bpe" else {
            throw SentencePieceBPETokenizerError.unsupportedType(document.type)
        }
        guard document.contextLength > 0, !document.pieces.isEmpty else {
            throw SentencePieceBPETokenizerError.invalidVocabulary
        }

        var byText: [String: Candidate] = [:]
        byText.reserveCapacity(document.pieces.count)
        var byteIDs = [Int32](repeating: -1, count: 256)
        for (index, piece) in document.pieces.enumerated() {
            let id = Int32(index)
            // Byte-fallback pieces are control tokens, never direct matches.
            if piece.piece.count == 6, piece.piece.hasPrefix("<0x"), piece.piece.hasSuffix(">"),
                let byte = UInt8(piece.piece.dropFirst(3).dropLast(), radix: 16)
            {
                byteIDs[Int(byte)] = id
                continue
            }
            // First writer wins on duplicate surface forms (matches sentencepiece).
            if byText[piece.piece] == nil {
                byText[piece.piece] = Candidate(id: id, score: piece.score)
            }
        }

        self.contextLength = document.contextLength
        self.piecesByText = byText
        self.byteFallbackIDs = byteIDs.contains(-1) ? [] : byteIDs
        self.padID = document.padID
        self.bosID = document.bosID
        self.eosID = document.eosID
        self.unkID = document.unkID
        self.addBOS = document.addBOS
        self.addEOS = document.addEOS
        self.lowercases = document.lowercase ?? false
    }

    public convenience init(fileURL: URL) throws {
        try self.init(data: Data(contentsOf: fileURL, options: .mappedIfSafe))
    }

    public func tokenize(_ text: String) throws -> MLTokenizedText {
        var ids: [Int32] = []
        ids.reserveCapacity(contextLength)
        if addBOS, let bosID { ids.append(bosID) }
        ids.append(contentsOf: segment(normalize(text)))

        // Truncate, keeping room for EOS (HF semantics: specials count toward max_length).
        let bodyLimit = contextLength - (addEOS && eosID != nil ? 1 : 0)
        if ids.count > bodyLimit {
            ids.removeSubrange(bodyLimit..<ids.count)
        }
        if addEOS, let eosID { ids.append(eosID) }
        let endIndex = max(0, ids.count - 1)
        if ids.count < contextLength {
            ids.append(contentsOf: repeatElement(padID, count: contextLength - ids.count))
        }
        return MLTokenizedText(inputIDs: ContiguousArray(ids), endTokenIndex: endIndex)
    }

    /// Identity normalizer plus the two Gemma/SigLIP specifics: optional lowercase
    /// (data-driven) and spaces escaped as ▁. No dummy prefix, no NFKC.
    private func normalize(_ text: String) -> String {
        let cased = lowercases ? text.lowercased() : text
        return String(cased.map { $0 == " " ? "\u{2581}" : $0 })
    }

    /// SentencePiece BPE: start from single code points, repeatedly merge the adjacent pair
    /// whose concatenation is a vocabulary piece with the highest score (scores are negative
    /// merge ranks, so the earliest-learned merge wins; leftmost wins score ties).
    private func segment(_ text: String) -> [Int32] {
        var symbols = text.unicodeScalars.map(String.init)
        guard !symbols.isEmpty else { return [] }

        while symbols.count > 1 {
            var bestIndex = -1
            var bestScore = -Float.infinity
            for index in 0..<(symbols.count - 1) {
                guard let candidate = piecesByText[symbols[index] + symbols[index + 1]] else { continue }
                if candidate.score > bestScore {
                    bestScore = candidate.score
                    bestIndex = index
                }
            }
            guard bestIndex >= 0 else { break }
            symbols[bestIndex] += symbols[bestIndex + 1]
            symbols.remove(at: bestIndex + 1)
        }

        var ids: [Int32] = []
        ids.reserveCapacity(symbols.count)
        for symbol in symbols {
            if let candidate = piecesByText[symbol] {
                ids.append(candidate.id)
            } else {
                // Single code point not in the vocabulary: byte fallback (or UNK).
                ids.append(contentsOf: fallbackIDs(for: symbol))
            }
        }
        return ids
    }

    private func fallbackIDs(for symbol: String) -> [Int32] {
        guard !byteFallbackIDs.isEmpty else { return [unkID] }
        return symbol.utf8.map { byteFallbackIDs[Int($0)] }
    }
}
