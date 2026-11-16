/// A recording's samples in fixed-size blocks, so a recording that runs for
/// hours (a meeting) grows without ever copying what it holds: a growing
/// array doubles and copies, which at 70 minutes is ~800 MB in flight per
/// stream. Each block is allocated at full size once and only appended to.
struct SampleBlocks {
    /// 2^18 samples: 1 MB, ~16 s at 16 kHz.
    static let defaultBlockSize = 1 << 18

    private let blockSize: Int
    private var blocks: [[Float]] = []
    private(set) var count = 0

    init(blockSize: Int = SampleBlocks.defaultBlockSize) {
        precondition(blockSize > 0)
        self.blockSize = blockSize
    }

    var blockCount: Int { blocks.count }

    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        var rest = samples[...]
        while !rest.isEmpty {
            let take = min(rest.count, room())
            blocks[blocks.count - 1].append(contentsOf: rest.prefix(take))
            rest = rest.dropFirst(take)
            count += take
        }
    }

    mutating func appendSilence(_ samples: Int) {
        var rest = samples
        while rest > 0 {
            let take = min(rest, room())
            blocks[blocks.count - 1].append(contentsOf: repeatElement(0, count: take))
            rest -= take
            count += take
        }
    }

    /// All the samples as one array, oldest first; leaves this empty. Frees
    /// each block as it's copied, so the peak is the samples plus one block.
    mutating func take() -> [Float] {
        var all: [Float] = []
        all.reserveCapacity(count)
        blocks.reverse()
        while let block = blocks.popLast() { all.append(contentsOf: block) }
        count = 0
        return all
    }

    /// Where a block's samples live, for tests: it never changes as the
    /// recording grows.
    func storageAddress(ofBlock index: Int) -> UnsafeRawPointer? {
        blocks[index].withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
    }

    /// Free space in the last block, starting a new one when it's full.
    private mutating func room() -> Int {
        if let last = blocks.last, last.count < blockSize { return blockSize - last.count }
        var block: [Float] = []
        block.reserveCapacity(blockSize)
        blocks.append(block)
        return blockSize
    }
}
