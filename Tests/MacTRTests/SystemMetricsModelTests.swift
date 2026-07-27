import Testing
@testable import MacTR

struct SystemMetricsModelTests {
    @Test("Network counters calculate idle and burst traffic")
    func networkIdleAndBurst() {
        let previous = [
            4: NetworkInterfaceBytes(rx: 1_000, tx: 2_000),
            7: NetworkInterfaceBytes(rx: 500, tx: 800),
        ]
        let idle = NetworkRateCalculator.byteDelta(
            current: previous,
            previous: previous)
        #expect(idle.rx == 0)
        #expect(idle.tx == 0)

        let burst = NetworkRateCalculator.byteDelta(
            current: [
                4: NetworkInterfaceBytes(rx: 9_000, tx: 3_000),
                7: NetworkInterfaceBytes(rx: 1_500, tx: 4_800),
            ],
            previous: previous)
        #expect(burst.rx == 9_000)
        #expect(burst.tx == 5_000)
    }

    @Test("New interfaces and reset counters cannot create spikes")
    func networkInterfaceChanges() {
        let previous = [
            4: NetworkInterfaceBytes(rx: 10_000, tx: 20_000),
            7: NetworkInterfaceBytes(rx: 1_000, tx: 2_000),
        ]
        let delta = NetworkRateCalculator.byteDelta(
            current: [
                // Interface 4 reset both counters.
                4: NetworkInterfaceBytes(rx: 100, tx: 200),
                // Interface 7 continued normally.
                7: NetworkInterfaceBytes(rx: 1_250, tx: 2_500),
                // Interface 9 is new and establishes a baseline.
                9: NetworkInterfaceBytes(rx: 9_000_000, tx: 8_000_000),
            ],
            previous: previous)
        #expect(delta.rx == 250)
        #expect(delta.tx == 500)
    }

    @Test("Network display changes band above 5 and 10 MB per second")
    func networkRateBands() {
        #expect(Color.networkRateBand(0) == .normal)
        #expect(Color.networkRateBand(5_000_000) == .normal)
        #expect(Color.networkRateBand(5_000_001) == .elevated)
        #expect(Color.networkRateBand(10_000_000) == .elevated)
        #expect(Color.networkRateBand(10_000_001) == .high)
    }

    @Test("Fan percentage clamps and tolerates a missing maximum")
    func fanPercentage() {
        #expect(FanReading(
            name: "Left", currentRPM: 2_000, minRPM: 1_000, maxRPM: 4_000
        ).percentOfMax == 50)
        #expect(FanReading(
            name: "Fast", currentRPM: 5_000, minRPM: nil, maxRPM: 4_000
        ).percentOfMax == 100)
        #expect(FanReading(
            name: "Unknown", currentRPM: 2_000, minRPM: nil, maxRPM: nil
        ).percentOfMax == nil)
    }

    @Test("SMC float, fixed-point, unsigned, and signed encodings decode")
    func smcNumberEncodings() {
        let floatRaw = Float(2_180.5).bitPattern
        let littleEndianFloat = [
            UInt8(floatRaw & 0xff),
            UInt8((floatRaw >> 8) & 0xff),
            UInt8((floatRaw >> 16) & 0xff),
            UInt8((floatRaw >> 24) & 0xff),
        ]
        let decodedFloat = SMCNumberDecoder.decode(
            dataType: SMCNumberDecoder.fourCC("flt "),
            bytes: littleEndianFloat,
            floatLittleEndian: true)
        #expect(abs((decodedFloat ?? 0) - 2_180.5) < 0.01)

        #expect(SMCNumberDecoder.decode(
            dataType: SMCNumberDecoder.fourCC("fpe2"),
            bytes: [0x1f, 0x40],
            floatLittleEndian: true) == 2_000)
        #expect(SMCNumberDecoder.decode(
            dataType: SMCNumberDecoder.fourCC("sp78"),
            bytes: [0x34, 0x80],
            floatLittleEndian: true) == 52.5)
        #expect(SMCNumberDecoder.decode(
            dataType: SMCNumberDecoder.fourCC("ui16"),
            bytes: [0x00, 0x02],
            floatLittleEndian: true) == 2)
        #expect(SMCNumberDecoder.decode(
            dataType: SMCNumberDecoder.fourCC("si16"),
            bytes: [0xff, 0xfe],
            floatLittleEndian: true) == -2)
    }

    @Test("Fanless and unavailable states remain distinct")
    func fanAvailability() {
        let fanless = FanSnapshot(available: true, fans: [])
        let unavailable = FanSnapshot(available: false, fans: [])
        #expect(fanless.available)
        #expect(fanless.fans.isEmpty)
        #expect(!unavailable.available)
        #expect(unavailable.fans.isEmpty)
    }

    @Test("One, two, and many fans use a compact three-row presentation")
    func fanPresentationLimit() {
        let allFans = (1...5).map {
            FanReading(
                name: "Fan \($0)",
                currentRPM: Double(1_000 + $0 * 100),
                minRPM: 800,
                maxRPM: 4_000)
        }

        #expect(FanSnapshot(
            available: true, fans: Array(allFans.prefix(1))
        ).displayReadings().count == 1)
        #expect(FanSnapshot(
            available: true, fans: Array(allFans.prefix(2))
        ).displayReadings().count == 2)

        let many = FanSnapshot(available: true, fans: allFans)
        #expect(many.displayReadings().map(\.name) == ["Fan 1", "Fan 2", "Fan 3"])
        #expect(many.overflowCount() == 2)
    }
}
