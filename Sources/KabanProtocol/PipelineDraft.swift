import Foundation

/// Exact UTF-8 YAML; no whitespace or newline normalization. nil base means no pipeline
/// existed when editing began, rather than permission to overwrite any current version.
public struct PipelineDraft: Codable, Hashable, Sendable {
    public var projectId: ProjectID
    public var baseVersionHash: String?
    public var contentHash: String
    public var content: String
    public init(projectId: ProjectID, baseVersionHash: String?, content: String) {
        self.projectId = projectId; self.baseVersionHash = baseVersionHash
        self.content = content; self.contentHash = PipelineContentHash.sha256(content)
    }
    private enum CodingKeys: String, CodingKey { case projectId, baseVersionHash, contentHash, content }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try c.decode(ProjectID.self, forKey: .projectId)
        // Unlike a legacy command without draft, a new draft must bind an explicit base,
        // including explicit null when the project has no committed pipeline yet.
        baseVersionHash = try c.decode(String?.self, forKey: .baseVersionHash)
        contentHash = try c.decode(String.self, forKey: .contentHash)
        content = try c.decode(String.self, forKey: .content)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(projectId, forKey: .projectId); try c.encode(baseVersionHash, forKey: .baseVersionHash)
        try c.encode(contentHash, forKey: .contentHash); try c.encode(content, forKey: .content)
    }

    /// Call inside the same transaction that accepts the version. YAML validation and the
    /// filesystem effect are separate checks; this method grants neither permission nor validity.
    public func checkBinding(projectId: ProjectID, currentVersionHash: String?, requestedHash: String) throws {
        guard self.projectId == projectId, baseVersionHash == currentVersionHash else {
            throw CommandError(code: CommandError.stalePipelineDraftCode, message: "Черновик относится к другому проекту или версии пайплайна.")
        }
        guard content.utf8.count <= DaemonWire.maxPipelineBytes else {
            throw CommandError(code: "invalid_request", message: "Черновик пайплайна превышает лимит размера.")
        }
        guard contentHash == requestedHash, contentHash == PipelineContentHash.sha256(content) else {
            throw CommandError(code: CommandError.pipelineHashMismatchCode, message: "Содержимое черновика не соответствует hash.")
        }
    }
}

/// Portable SHA-256 for content identity, FIPS 180-4 §6.2. No signing/authentication use.
/// https://csrc.nist.gov/pubs/fips/180-4/upd1/final
public enum PipelineContentHash {
    public static func sha256(_ content: String) -> String {
        var bytes = Array(content.utf8)
        let bits = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        bytes += (0..<8).reversed().map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for start in stride(from: 0, to: bytes.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let p = start + i * 4
                w[i] = UInt32(bytes[p]) << 24 | UInt32(bytes[p + 1]) << 16 | UInt32(bytes[p + 2]) << 8 | UInt32(bytes[p + 3])
            }
            for i in 16..<64 {
                let x = w[i - 15], y = w[i - 2]
                w[i] = w[i - 16] &+ (rotate(x, 7) ^ rotate(x, 18) ^ (x >> 3)) &+ w[i - 7] &+ (rotate(y, 17) ^ rotate(y, 19) ^ (y >> 10))
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], v = h[7]
            for i in 0..<64 {
                let t1 = v &+ (rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)) &+ ((e & f) ^ (~e & g)) &+ constants[i] &+ w[i]
                let t2 = (rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)) &+ ((a & b) ^ (a & c) ^ (b & c))
                v = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            for (i, x) in [a, b, c, d, e, f, g, v].enumerated() { h[i] = h[i] &+ x }
        }
        return "sha256:" + h.map { String(format: "%08x", $0) }.joined()
    }
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]
}
