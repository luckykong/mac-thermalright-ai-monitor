import Testing
@testable import MacTR

@Suite("Agent token accounting splits cache reads from fresh input")
struct AgentTokenSplitTests {

    /// A real Claude `message.usage` record. The three input fields are
    /// disjoint, so the fresh half is the two non-read fields.
    @Test("Claude usage separates cache reads from newly sent content")
    func claudeSplit() {
        let split = AgentTokenSplit.claude([
            "input_tokens": 105,
            "cache_creation_input_tokens": 294_556,
            "cache_read_input_tokens": 2_477_524,
            "output_tokens": 70_444,
        ])

        #expect(split.fresh == 294_661)          // 105 + cache writes
        #expect(split.cached == 2_477_524)
        #expect(split.output == 70_444)

        // Counting cache reads reproduces the pre-1.4.4 total exactly.
        #expect(split.input(countingCached: true) == 2_772_185)
        #expect(split.input(countingCached: false) == 294_661)
    }

    /// A real Codex `info.last_token_usage` record. Unlike Claude,
    /// `input_tokens` already CONTAINS `cached_input_tokens`.
    @Test("Codex usage subtracts the cached share already inside input_tokens")
    func codexSplit() {
        let split = AgentTokenSplit.codex([
            "input_tokens": 64_540,
            "cached_input_tokens": 61_312,
            "cache_write_input_tokens": 1_000,
            "output_tokens": 128,
        ])

        #expect(split.fresh == 4_228)            // 64540 - 61312 + 1000
        #expect(split.cached == 61_312)
        #expect(split.output == 128)

        // Counting cache reads reproduces the old input_tokens + cache_write sum.
        #expect(split.input(countingCached: true) == 65_540)
        #expect(split.input(countingCached: false) == 4_228)
    }

    /// Older Codex builds omit `cache_write_input_tokens` entirely.
    @Test("Missing fields read as zero rather than dropping the record")
    func missingFields() {
        let codex = AgentTokenSplit.codex([
            "input_tokens": 500,
            "cached_input_tokens": 200,
            "output_tokens": 40,
        ])
        #expect(codex.fresh == 300)
        #expect(codex.cached == 200)

        let claude = AgentTokenSplit.claude(["input_tokens": 500, "output_tokens": 40])
        #expect(claude.fresh == 500)
        #expect(claude.cached == 0)
        #expect(claude.input(countingCached: true) == claude.input(countingCached: false))
    }

    /// The subtraction runs on UInt64, where a malformed record claiming more
    /// cached tokens than total input would trap instead of merely being wrong.
    @Test("A cached count larger than input_tokens does not underflow")
    func codexUnderflowIsClamped() {
        let split = AgentTokenSplit.codex([
            "input_tokens": 100,
            "cached_input_tokens": 900,
        ])
        #expect(split.fresh == 0)
        #expect(split.cached == 100)
    }

    @Test("Accumulating usage keeps both halves independent")
    func accumulation() {
        var total = AgentTokenSplit.Usage()
        total += AgentTokenSplit.Usage(fresh: 10, cached: 100, output: 1)
        total += AgentTokenSplit.Usage(fresh: 5, cached: 50, output: 2)

        #expect(total == AgentTokenSplit.Usage(fresh: 15, cached: 150, output: 3))
        #expect(total.input(countingCached: true) == 165)
        #expect(total.input(countingCached: false) == 15)
    }
}
