// SystemMetricsCollector.swift — Native macOS system metrics collection
//
// Replaces Python psutil calls with native Mach/IOKit/sysctl APIs.
// All metrics are collected synchronously — caller should run off main thread.

import CThermalSensor
import Darwin
import Foundation
import IOKit
import IOKit.ps

// MARK: - Data Structures

struct CPUSnapshot: Sendable {
    let perCore: [Double]  // percentage per core
    let total: Double      // average percentage
    let loadAvg: (Double, Double, Double)
    let pCoreCount: Int    // performance cores (rest are efficiency)
}

struct MemorySnapshot: Sendable {
    let total: UInt64      // bytes
    let active: UInt64
    let wired: UInt64
    let compressed: UInt64
    let available: UInt64
    let swapUsed: UInt64
    let swapTotal: UInt64
    let swapInPerSec: Double        // bytes/sec — pages read FROM swap (disk→memory)
    let swapOutPerSec: Double       // bytes/sec — pages written TO swap (memory→disk)
    let swapAvailable: Bool         // false = 수집 실패(장애). idle(0)와 구분용
    let pressure: Int               // kern.memorystatus_vm_pressure_level: 1=normal 2=warn 4=critical
    var percent: Double { Double(total - available) / Double(total) * 100 }
}

struct GPUSnapshot: Sendable {
    let available: Bool
    let name: String
    let cores: Int
    let deviceUtil: Int    // percentage
    let rendererUtil: Int
    let tilerUtil: Int
    let memUsedMB: Int
    let memAllocMB: Int
}

struct DiskSnapshot: Sendable {
    let totalGB: Double
    let usedGB: Double
    let freeGB: Double
    var percent: Double { usedGB / totalGB * 100 }
}

struct NetworkSnapshot: Sendable {
    let available: Bool
    let rxBytesPerSec: Double
    let txBytesPerSec: Double
}

struct NetworkInterfaceBytes: Equatable, Sendable {
    let rx: UInt64
    let tx: UInt64
}

enum NetworkRateCalculator {
    /// Only interfaces present in both samples contribute. Counter rollback is
    /// treated as a new baseline instead of an unsigned underflow/traffic spike.
    static func byteDelta(
        current: [Int: NetworkInterfaceBytes],
        previous: [Int: NetworkInterfaceBytes]
    ) -> (rx: UInt64, tx: UInt64) {
        var deltaRx: UInt64 = 0
        var deltaTx: UInt64 = 0
        for (index, bytes) in current {
            guard let old = previous[index] else { continue }
            if bytes.rx >= old.rx { deltaRx += bytes.rx - old.rx }
            if bytes.tx >= old.tx { deltaTx += bytes.tx - old.tx }
        }
        return (deltaRx, deltaTx)
    }
}

enum SMCNumberDecoder {
    static func fourCC(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func decode(
        dataType: UInt32,
        bytes: [UInt8],
        floatLittleEndian: Bool
    ) -> Double? {
        func u16() -> UInt16? {
            guard bytes.count >= 2 else { return nil }
            return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        }
        func u32() -> UInt32? {
            guard bytes.count >= 4 else { return nil }
            return UInt32(bytes[0]) << 24
                | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8
                | UInt32(bytes[3])
        }
        func littleEndianU32() -> UInt32? {
            guard bytes.count >= 4 else { return nil }
            return UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
        }

        if dataType == fourCC("flt ") {
            guard let raw = floatLittleEndian ? littleEndianU32() : u32() else {
                return nil
            }
            return Double(Float(bitPattern: raw))
        }
        if dataType == fourCC("fpe2") {
            return u16().map { Double($0) / 4.0 }
        }
        if dataType == fourCC("sp78") {
            return u16().map { Double(Int16(bitPattern: $0)) / 256.0 }
        }
        if dataType == fourCC("sp87") {
            return u16().map { Double(Int16(bitPattern: $0)) / 128.0 }
        }
        if dataType == fourCC("ui8 ") {
            return bytes.first.map(Double.init)
        }
        if dataType == fourCC("ui16") {
            return u16().map(Double.init)
        }
        if dataType == fourCC("ui32") {
            return u32().map(Double.init)
        }
        if dataType == fourCC("si8 ") {
            return bytes.first.map { Double(Int8(bitPattern: $0)) }
        }
        if dataType == fourCC("si16") {
            return u16().map { Double(Int16(bitPattern: $0)) }
        }
        return nil
    }
}

struct FanReading: Sendable {
    let name: String
    let currentRPM: Double
    let minRPM: Double?
    let maxRPM: Double?

    var percentOfMax: Double? {
        guard let maxRPM, maxRPM > 0 else { return nil }
        return min(max(currentRPM / maxRPM * 100, 0), 100)
    }
}

struct FanSnapshot: Sendable {
    /// `available == true && fans.isEmpty` means a genuinely fanless Mac.
    /// `available == false` means AppleSMC could not be queried.
    let available: Bool
    let fans: [FanReading]

    func displayReadings(limit: Int = 3) -> [FanReading] {
        Array(fans.prefix(max(limit, 0)))
    }

    func overflowCount(limit: Int = 3) -> Int {
        max(fans.count - max(limit, 0), 0)
    }
}

struct DiskIOSnapshot: Sendable {
    let readBytesPerSec: Double
    let writeBytesPerSec: Double
}

struct TemperatureSnapshot: Sendable {
    let cpuTemp: Double?       // °C, nil if unavailable
    let gpuTemp: Double?       // °C, nil if unavailable
    let thermalState: Int      // 0=nominal, 1=fair, 2=serious, 3=critical
}

struct BatterySnapshot: Sendable {
    let percent: Int
    let isCharging: Bool
    let isPresent: Bool
}

struct SystemSnapshot: Sendable {
    let uptimeSeconds: Int
    let processCount: Int
}

// MARK: - Collector

final class SystemMetricsCollector: @unchecked Sendable {

    // Previous CPU ticks for delta calculation
    private var prevTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []

    // Previous per-interface network bytes for delta calculation. Tracking each
    // interface independently prevents a newly appearing VPN/interface from
    // producing a huge one-frame throughput spike.
    private var prevNetInterfaces: [Int: NetworkInterfaceBytes] = [:]
    private var prevNetTime: Date?

    // Previous disk IO bytes for delta calculation
    private var prevDiskRead: UInt64 = 0
    private var prevDiskWrite: UInt64 = 0
    private var prevDiskTime: Date?

    // Previous swap counters for activity rate calculation
    private var prevSwapIns: UInt64 = 0
    private var prevSwapOuts: UInt64 = 0
    private var prevSwapTime: Date?

    // SMC connection for temperature
    private var smcConn: io_connect_t = 0
    private var smcOpened = false
    private var smcLogOnce = true
    private var lastSMCOpenAttempt: Date?
    /// Temperature keys discovered by enumerating the SMC, split by prefix.
    /// nil until the first (one-time) scan runs. Empty arrays are a valid,
    /// remembered result — they mean "scanned, found none", not "not scanned".
    ///
    /// The key's size/type is captured during the scan so steady-state reads
    /// skip the kSMCGetKeyInfo round trip entirely. That descriptor is fixed
    /// for the life of the connection, and re-fetching it per key per tick
    /// doubled the syscall count for no new information.
    private var smcCPUKeys: [SMCTempKey]?
    private var smcGPUKeys: [SMCTempKey]?
    /// Last die-temperature reading, reused between refreshes. Sweeping every
    /// discovered sensor costs ~24 ms, and a die's temperature does not move
    /// meaningfully inside one metrics tick, so the sweep runs on its own
    /// slower cadence instead of on every collect.
    ///
    /// Ages are measured against `systemUptime`, which is monotonic. Wall-clock
    /// deltas go negative when NTP or the user moves the clock back, and a
    /// negative age reads as "young" — the cache would then never expire.
    private var cachedDieTemps: (cpu: Double?, gpu: Double?)?
    private var lastDieTempUptime: TimeInterval = -.greatestFiniteMagnitude
    private static let dieTempInterval: TimeInterval = 4

    // MARK: - CPU

    func collectCPU() -> CPUSnapshot {
        var numCPU: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPU, &cpuInfo, &numCPUInfo)

        guard result == KERN_SUCCESS, let info = cpuInfo else {
            return CPUSnapshot(perCore: [], total: 0, loadAvg: (0, 0, 0), pCoreCount: 0)
        }

        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<Int32>.stride))
        }

        var perCore: [Double] = []
        var newTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []

        for i in 0..<Int(numCPU) {
            let base = Int(CPU_STATE_MAX) * i
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])

            newTicks.append((user, system, idle, nice))

            if i < prevTicks.count {
                let du = user - prevTicks[i].user
                let ds = system - prevTicks[i].system
                let di = idle - prevTicks[i].idle
                let dn = nice - prevTicks[i].nice
                let total = du + ds + di + dn
                let pct = total > 0 ? Double(du + ds + dn) / Double(total) * 100 : 0
                perCore.append(pct)
            } else {
                perCore.append(0)
            }
        }

        prevTicks = newTicks

        let total = perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count)

        var loadavg: [Double] = [0, 0, 0]
        getloadavg(&loadavg, 3)

        // P-core count via sysctl (Apple Silicon)
        var pCores: Int32 = 0
        var pSize = MemoryLayout<Int32>.size
        sysctlbyname("hw.perflevel0.logicalcpu", &pCores, &pSize, nil, 0)
        // If sysctl fails (Intel), assume all cores are P-cores
        let pCount = pCores > 0 ? Int(pCores) : perCore.count

        return CPUSnapshot(
            perCore: perCore, total: total,
            loadAvg: (loadavg[0], loadavg[1], loadavg[2]),
            pCoreCount: pCount)
    }

    // MARK: - Memory

    func collectMemory() -> MemorySnapshot {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        let pageSize = UInt64(getpagesize())

        guard result == KERN_SUCCESS else {
            return MemorySnapshot(total: 0, active: 0, wired: 0, compressed: 0,
                                  available: 0, swapUsed: 0, swapTotal: 0,
                                  swapInPerSec: 0, swapOutPerSec: 0, swapAvailable: false,
                                  pressure: 1)
        }

        // Total RAM via sysctl
        var totalRAM: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalRAM, &size, nil, 0)

        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let free = UInt64(stats.free_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let available = free + inactive

        // Swap size via sysctl (xsu_total is dynamic on macOS — grows on demand).
        // ret == 0 means the read succeeded even when swap is 0 (genuine idle);
        // a non-zero return means monitoring is unavailable (distinct from idle).
        var swapUsage = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapRet = sysctlbyname("vm.swapusage", &swapUsage, &swapSize, nil, 0)

        // Swap activity — swapins/swapouts are cumulative page counts in the same
        // vm_statistics64 already read above (no extra syscall). Delta × pageSize = bytes/sec.
        // Tracked separately for the in/out mirror chart. Performance signal is the RATE:
        // large-but-idle swap is fine, active swapping hurts.
        let now = Date()
        var swapIn: Double = 0
        var swapOut: Double = 0
        let curIns = stats.swapins
        let curOuts = stats.swapouts
        if let prevTime = prevSwapTime {
            let elapsed = now.timeIntervalSince(prevTime)
            if elapsed > 0 && (prevSwapIns > 0 || prevSwapOuts > 0) {
                let dIns = curIns >= prevSwapIns ? curIns - prevSwapIns : 0
                let dOuts = curOuts >= prevSwapOuts ? curOuts - prevSwapOuts : 0
                swapIn = Double(dIns) * Double(pageSize) / elapsed
                swapOut = Double(dOuts) * Double(pageSize) / elapsed
            }
        }
        prevSwapIns = curIns
        prevSwapOuts = curOuts
        prevSwapTime = now

        // Memory pressure — macOS' authoritative signal (same source as Activity Monitor's
        // pressure graph). 1=normal 2=warn 4=critical. This is severity; used% is just the gauge.
        var pressureLevel: Int32 = 1
        var pressureSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &pressureSize, nil, 0)

        return MemorySnapshot(
            total: totalRAM, active: active, wired: wired,
            compressed: compressed, available: available,
            swapUsed: UInt64(swapUsage.xsu_used),
            swapTotal: UInt64(swapUsage.xsu_total),
            swapInPerSec: swapIn, swapOutPerSec: swapOut,
            swapAvailable: swapRet == 0,
            pressure: Int(pressureLevel))
    }

    // MARK: - GPU (via ioreg)

    func collectGPU() -> GPUSnapshot {
        var result = GPUSnapshot(
            available: false, name: "GPU", cores: 0, deviceUtil: 0, rendererUtil: 0,
            tilerUtil: 0, memUsedMB: 0, memAllocMB: 0)

        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return result }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
                    == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any]
            else { continue }

            // GPU stats are inside "PerformanceStatistics" sub-dictionary
            let perfStats = dict["PerformanceStatistics"] as? [String: Any] ?? dict

            let cores = dict["gpu-core-count"] as? Int ?? 0
            let device = perfStats["Device Utilization %"] as? Int ?? 0
            let renderer = perfStats["Renderer Utilization %"] as? Int ?? 0
            let tiler = perfStats["Tiler Utilization %"] as? Int ?? 0
            let memUsed = (perfStats["In use system memory"] as? Int ?? 0) / (1024 * 1024)
            let memAlloc = (perfStats["Alloc system memory"] as? Int ?? 0) / (1024 * 1024)

            let gen = dict["gpu_gen"] as? Int ?? 0
            let name = (gen > 0 && cores > 0)
                ? "Apple M-series (G\(gen), \(cores) cores)"
                : "GPU"

            result = GPUSnapshot(
                available: true, name: name, cores: cores, deviceUtil: device,
                rendererUtil: renderer, tilerUtil: tiler,
                memUsedMB: memUsed, memAllocMB: memAlloc)

            break  // Use first accelerator
        }

        return result
    }

    // MARK: - Disk (URLResourceValues — Apple's documented volume capacity API)

    /// Disk capacity via URLResourceValues. Uses `volumeAvailableCapacityForImportantUsage`,
    /// which is the value Finder shows: it INCLUDES purgeable space (caches, local snapshots,
    /// evictable cloud files) that macOS reclaims on demand. Counting only non-purgeable free
    /// space falsely reports a nearly-full disk — the same "ignore what the OS can reclaim"
    /// mistake as judging memory by used% instead of pressure.
    /// Units are decimal GB (1e9) to match Finder/Apple conventions.
    /// No subprocess: replaces the old `diskutil apfs list` shell-out entirely.
    func collectDisk() -> DiskSnapshot {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        if let v = try? url.resourceValues(forKeys: keys),
           let total = v.volumeTotalCapacity,
           let important = v.volumeAvailableCapacityForImportantUsage {
            let totalGB = Double(total) / 1e9
            let freeGB = Double(important) / 1e9
            return DiskSnapshot(totalGB: totalGB,
                                usedGB: max(totalGB - freeGB, 0),
                                freeGB: freeGB)
        }

        // Fallback: statvfs (excludes purgeable, so it under-reports free space)
        var stat = statvfs()
        guard statvfs("/", &stat) == 0 else {
            return DiskSnapshot(totalGB: 0, usedGB: 0, freeGB: 0)
        }
        let total = Double(stat.f_blocks) * Double(stat.f_frsize) / 1e9
        let free = Double(stat.f_bavail) * Double(stat.f_frsize) / 1e9
        return DiskSnapshot(totalGB: total, usedGB: total - free, freeGB: free)
    }

    // MARK: - Battery

    func collectBattery() -> BatterySnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [Any],
              let first = list.first
        else {
            return BatterySnapshot(percent: 0, isCharging: false, isPresent: false)
        }

        let desc = IOPSGetPowerSourceDescription(info, first as CFTypeRef)?
            .takeUnretainedValue() as? [String: Any] ?? [:]

        let percent = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let charging = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

        return BatterySnapshot(percent: percent, isCharging: charging, isPresent: true)
    }

    // MARK: - System

    func collectSystem() -> SystemSnapshot {
        // Uptime via sysctl kern.boottime
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boottime, &size, nil, 0)
        let uptime = Int(Date().timeIntervalSince1970) - Int(boottime.tv_sec)

        // Process count
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var procSize: Int = 0
        sysctl(&mib, 3, nil, &procSize, nil, 0)
        let count = procSize / MemoryLayout<kinfo_proc>.size

        return SystemSnapshot(uptimeSeconds: uptime, processCount: count)
    }

    // MARK: - Network Traffic (sysctl — no subprocess, 64-bit counters)

    func collectNetwork() -> NetworkSnapshot {
        let now = Date()
        guard let current = sysctlNetworkBytesByInterface() else {
            return NetworkSnapshot(available: false, rxBytesPerSec: 0, txBytesPerSec: 0)
        }

        var rxPerSec: Double = 0
        var txPerSec: Double = 0

        if let prevTime = prevNetTime {
            let elapsed = now.timeIntervalSince(prevTime)
            if elapsed > 0 {
                let delta = NetworkRateCalculator.byteDelta(
                    current: current, previous: prevNetInterfaces)
                rxPerSec = Double(delta.rx) / elapsed
                txPerSec = Double(delta.tx) / elapsed
            }
        }

        prevNetInterfaces = current
        prevNetTime = now

        return NetworkSnapshot(
            available: true,
            rxBytesPerSec: rxPerSec,
            txBytesPerSec: txPerSec)
    }

    /// Read 64-bit counters for every non-loopback interface via NET_RT_IFLIST2.
    private func sysctlNetworkBytesByInterface() -> [Int: NetworkInterfaceBytes]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len: Int = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }

        var buf = [UInt8](repeating: 0, count: len)
        let readResult = buf.withUnsafeMutableBytes { rawBuffer in
            sysctl(&mib, 6, rawBuffer.baseAddress, &len, nil, 0)
        }
        guard readResult == 0 else { return nil }

        var result: [Int: NetworkInterfaceBytes] = [:]
        var offset = 0

        while offset + MemoryLayout<if_msghdr>.size <= len {
            let (msgLen, msgType) = buf.withUnsafeBufferPointer { ptr in
                let p = (ptr.baseAddress! + offset).withMemoryRebound(to: if_msghdr.self, capacity: 1) { $0.pointee }
                return (Int(p.ifm_msglen), Int32(p.ifm_type))
            }
            guard msgLen > 0, offset + msgLen <= len else { break }

            if msgType == RTM_IFINFO2, msgLen >= MemoryLayout<if_msghdr2>.size {
                let header = buf.withUnsafeBufferPointer { ptr in
                    (ptr.baseAddress! + offset).withMemoryRebound(to: if_msghdr2.self, capacity: 1) {
                        $0.pointee
                    }
                }
                let data = header.ifm_data
                let isUp = (header.ifm_flags & IFF_UP) != 0
                if data.ifi_type != 24 && isUp {  // IFT_LOOP
                    result[Int(header.ifm_index)] = NetworkInterfaceBytes(
                        rx: data.ifi_ibytes,
                        tx: data.ifi_obytes)
                }
            }

            offset += msgLen
        }
        return result
    }

    // MARK: - Disk I/O (IOKit disk stats)

    func collectDiskIO() -> DiskIOSnapshot {
        let now = Date()
        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0

        // Use IOKit to get disk statistics
        let matching = IOServiceMatching("IOBlockStorageDriver")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return DiskIOSnapshot(readBytesPerSec: 0, writeBytesPerSec: 0) }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
                    == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["Statistics"] as? [String: Any]
            else { continue }

            if let rb = stats["Bytes (Read)"] as? UInt64 { totalRead += rb }
            if let wb = stats["Bytes (Write)"] as? UInt64 { totalWrite += wb }
        }

        var readPerSec: Double = 0
        var writePerSec: Double = 0

        if let prevTime = prevDiskTime {
            let elapsed = now.timeIntervalSince(prevTime)
            if elapsed > 0 && prevDiskRead > 0 {
                if totalRead >= prevDiskRead {
                    readPerSec = Double(totalRead - prevDiskRead) / elapsed
                }
                if totalWrite >= prevDiskWrite {
                    writePerSec = Double(totalWrite - prevDiskWrite) / elapsed
                }
            }
        }

        prevDiskRead = totalRead
        prevDiskWrite = totalWrite
        prevDiskTime = now

        return DiskIOSnapshot(readBytesPerSec: readPerSec, writeBytesPerSec: writePerSec)
    }

    // MARK: - Fans (AppleSMC)

    func collectFans() -> FanSnapshot {
        guard openSMC() else {
            return FanSnapshot(available: false, fans: [])
        }

        let countValue = readSMCNumber("FNum")
        let indexes: [Int]
        if let countValue {
            let count = min(max(Int(countValue.rounded()), 0), 16)
            if count == 0 {
                return FanSnapshot(available: true, fans: [])
            }
            indexes = Array(0..<count)
        } else {
            // FNum is standard, but probing keeps fan telemetry useful on models
            // whose SMC exposes speed keys without the count key.
            indexes = (0..<10).filter { readSMCNumber("F\($0)Ac") != nil }
            if indexes.isEmpty {
                return FanSnapshot(available: false, fans: [])
            }
        }

        var fans: [FanReading] = []
        for index in indexes {
            guard let current = readSMCNumber("F\(index)Ac"),
                  current.isFinite, current >= 0
            else { continue }

            let minValue = readSMCNumber("F\(index)Mn")
                .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let maxValue = readSMCNumber("F\(index)Mx")
                .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let smcName = readSMCString("F\(index)ID")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = if let smcName, !smcName.isEmpty {
                smcName
            } else {
                "Fan \(index + 1)"
            }

            fans.append(FanReading(
                name: name,
                currentRPM: current,
                minRPM: minValue,
                maxRPM: maxValue))
        }

        // A positive FNum with no readable speed keys is a collection failure,
        // not a fanless machine.
        if !indexes.isEmpty && fans.isEmpty {
            return FanSnapshot(available: false, fans: [])
        }
        return FanSnapshot(available: true, fans: fans)
    }

    // MARK: - Temperature (SMC)

    func collectTemperature() -> TemperatureSnapshot {
        // Cheap and genuinely live, so it is never cached.
        let thermalState = ProcessInfo.processInfo.thermalState.rawValue

        let now = ProcessInfo.processInfo.systemUptime
        if let cached = cachedDieTemps, now - lastDieTempUptime < Self.dieTempInterval {
            return TemperatureSnapshot(cpuTemp: cached.cpu, gpuTemp: cached.gpu,
                                       thermalState: thermalState)
        }

        var cpuTemp: Double? = nil
        var gpuTemp: Double? = nil

        // Primary: SMC, because it exposes the per-core die sensors.
        //
        // The IOHID path used to come first, but its `PMU tdie*` sensors are
        // not the hot spot. Measured on this machine, idle vs eight busy
        // threads: SMC `Tp*` 65.2 -> 111.8 °C while HID reported 54.1 -> 74.4.
        // Reporting the cooler sensor as "the CPU temperature" understated the
        // peak by up to 37 °C, which defeats the point of a thermal readout.
        if !smcOpened { openSMC() }
        if smcOpened {
            discoverSMCTemperatureKeysIfNeeded()
            cpuTemp = hottestSMCTemp(smcCPUKeys ?? [], label: "CPU")
            gpuTemp = hottestSMCTemp(smcGPUKeys ?? [], label: "GPU")
        }

        // Fallback: IOHIDEventSystemClient, for a machine where the SMC is
        // unreachable or publishes none of these keys.
        if cpuTemp == nil || gpuTemp == nil {
            var hidCpu: Double = -1
            var hidGpu: Double = -1
            readThermalSensors(&hidCpu, &hidGpu)
            if cpuTemp == nil, hidCpu > 0 { cpuTemp = hidCpu }
            if gpuTemp == nil, hidGpu > 0 { gpuTemp = hidGpu }
            if smcLogOnce {
                log("[Temp] HID fallback: CPU=\(hidCpu > 0 ? String(format: "%.1f°C", hidCpu) : "N/A"), GPU=\(hidGpu > 0 ? String(format: "%.1f°C", hidGpu) : "N/A")")
            }
        }
        smcLogOnce = false

        cachedDieTemps = (cpuTemp, gpuTemp)
        lastDieTempUptime = ProcessInfo.processInfo.systemUptime
        return TemperatureSnapshot(cpuTemp: cpuTemp, gpuTemp: gpuTemp, thermalState: thermalState)
    }

    // MARK: - SMC temperature discovery

    /// Plausible range for a die temperature in °C. The lower bound also drops
    /// the readings a power-gated core reports while it is parked — an idle
    /// performance cluster returns a fixed placeholder, not a measurement.
    private static let plausibleTempRange = 10.0...120.0

    /// SMC types that carry a temperature: `flt ` on Apple Silicon, the sp
    /// fixed-point pair on Intel. Every Tp/Te/Tg key on this machine is `flt `.
    private static let temperatureDataTypes: Set<UInt32> = [
        SMCNumberDecoder.fourCC("flt "),
        SMCNumberDecoder.fourCC("sp78"),
        SMCNumberDecoder.fourCC("sp87"),
    ]

    /// A discovered temperature key plus the descriptor needed to read it,
    /// so the steady-state path is one IOConnectCall per key instead of two.
    private struct SMCTempKey {
        let name: String
        let fourCC: UInt32
        let dataSize: UInt32
        let dataType: UInt32
    }

    /// Enumerate the SMC's key table once and keep the temperature keys that
    /// belong to the CPU and GPU.
    ///
    /// This replaces a hardcoded list of guessed key names. That list was wrong
    /// in both directions on this machine: `Tp01`, `Tp05`, `Tp0D`, `Tp1h`,
    /// `Tp0V`, `Te0L`, `Tg0U` and `Tg0g` do not exist, while real sensors —
    /// `Te04`, `Te06`, `Te0R`, `Tex0…3`, `Tg04`, `Tg0R`, `Tg0y`, `Tg1l` and
    /// others — were never read. Which names a chip publishes varies per model,
    /// so enumerating is the only approach that does not need a new hardcoded
    /// list for every future SoC.
    ///
    /// Prefixes: `Tp`/`Te` are CPU performance/efficiency cores, `Tg` is GPU.
    private func discoverSMCTemperatureKeysIfNeeded() {
        guard smcCPUKeys == nil, smcOpened else { return }
        // Read the table size BEFORE arming the memo. Failing here means the
        // scan never ran, which is not the same as running and finding nothing:
        // memoizing that would strand the process on the HID fallback until
        // restart over one transient error.
        guard let count = readSMCKeyCount() else { return }

        var cpu: [SMCTempKey] = []
        var gpu: [SMCTempKey] = []
        defer {
            // Assigned even when empty so a genuinely sensorless machine does
            // not rescan the whole key table on every tick.
            smcCPUKeys = cpu
            smcGPUKeys = gpu
            log("[SMC] Discovered \(cpu.count) CPU and \(gpu.count) GPU"
                + " temperature keys")
        }

        for index in 0..<count {
            guard let key = readSMCKey(at: index) else { continue }
            let isCPU = key.hasPrefix("Tp") || key.hasPrefix("Te")
            let isGPU = key.hasPrefix("Tg")
            guard isCPU || isGPU else { continue }
            // Filter on DATA TYPE, never on the value read right now. A parked
            // core reports a placeholder until it wakes, so screening by value
            // at scan time would permanently discard whichever cores happened
            // to be idle during startup — on this machine that was 103 keys
            // kept out of 134. The type check still excludes a same-prefix key
            // holding something that is not a temperature.
            guard let info = readSMCKeyInfo(key),
                  Self.temperatureDataTypes.contains(info.dataType)
            else { continue }
            let entry = SMCTempKey(name: key, fourCC: fourCC(key),
                                   dataSize: info.dataSize,
                                   dataType: info.dataType)
            if isCPU { cpu.append(entry) } else { gpu.append(entry) }
        }
    }

    /// Hottest of the given keys — the reading that matters for thermal
    /// headroom. Averaging instead would fold in every parked core sitting at
    /// its placeholder value and drag the number well below the real peak.
    private func hottestSMCTemp(_ keys: [SMCTempKey], label: String) -> Double? {
        var hottest: (name: String, value: Double)?
        var readable = 0
        for key in keys {
            guard let t = readDiscoveredSMCTemp(key),
                  Self.plausibleTempRange.contains(t)
            else { continue }
            readable += 1
            if hottest == nil || t > hottest!.value { hottest = (key.name, t) }
        }
        guard let hottest else { return nil }
        if smcLogOnce {
            log("[SMC] \(label) hottest \(hottest.name)="
                + String(format: "%.1f°C", hottest.value)
                + " — \(readable) of \(keys.count) sensors readable")
        }
        return hottest.value
    }

    /// Read a key whose descriptor is already known: one call, no key-info
    /// round trip. A parked core simply fails to answer and is skipped.
    private func readDiscoveredSMCTemp(_ key: SMCTempKey) -> Double? {
        guard smcOpened else { return nil }
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        input.key = key.fourCC
        input.keyInfo.dataSize = key.dataSize
        input.data8 = 5  // kSMCReadKey
        guard smcCall(&input, &output) == KERN_SUCCESS else { return nil }
        var tuple = output.bytes
        let size = min(Int(key.dataSize), 32)
        let bytes = withUnsafeBytes(of: &tuple) { Array($0.prefix(size)) }
        #if arch(arm64)
        let floatLittleEndian = true
        #else
        let floatLittleEndian = false
        #endif
        return SMCNumberDecoder.decode(
            dataType: key.dataType, bytes: bytes,
            floatLittleEndian: floatLittleEndian)
    }

    /// The size/type descriptor for a key, without reading its value.
    private func readSMCKeyInfo(_ key: String) -> (dataSize: UInt32, dataType: UInt32)? {
        guard smcOpened else { return nil }
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        input.key = fourCC(key)
        input.data8 = 9  // kSMCGetKeyInfo
        guard smcCall(&input, &output) == KERN_SUCCESS else { return nil }
        return (output.keyInfo.dataSize, output.keyInfo.dataType)
    }

    /// Number of keys in the SMC's table, from the `#KEY` pseudo-key.
    private func readSMCKeyCount() -> Int? {
        guard let value = readSMCValue("#KEY"), value.bytes.count >= 4 else {
            return nil
        }
        let b = value.bytes
        return Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16
            | UInt32(b[2]) << 8 | UInt32(b[3]))
    }

    /// The key name at `index` in the SMC's table.
    private func readSMCKey(at index: Int) -> String? {
        guard smcOpened else { return nil }
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        input.data8 = 8  // kSMCGetKeyFromIndex
        input.data32 = UInt32(index)
        guard smcCall(&input, &output) == KERN_SUCCESS, output.key != 0 else {
            return nil
        }
        let k = output.key
        let chars = [UInt8((k >> 24) & 0xff), UInt8((k >> 16) & 0xff),
                     UInt8((k >> 8) & 0xff), UInt8(k & 0xff)]
        guard chars.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
        return String(bytes: chars, encoding: .ascii)
    }

    // MARK: - SMC Helpers

    @discardableResult
    private func openSMC() -> Bool {
        if smcOpened { return true }
        let diagnostics = CommandLine.arguments.contains("--smc-test")
        if let lastSMCOpenAttempt,
           Date().timeIntervalSince(lastSMCOpenAttempt) < 60 {
            return false
        }
        lastSMCOpenAttempt = Date()

        // Apple Silicon exposes AppleSMCKeysEndpoint; Intel commonly exposes
        // AppleSMC directly. Try both without repeatedly walking IOKit on failure.
        for serviceClass in ["AppleSMC", "AppleSMCKeysEndpoint"] {
            let service = IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOServiceMatching(serviceClass))
            guard service != 0 else {
                if diagnostics { print("[SMC] \(serviceClass): service not found") }
                continue
            }
            let result = IOServiceOpen(service, mach_task_self_, 0, &smcConn)
            IOObjectRelease(service)
            if diagnostics {
                print(String(
                    format: "[SMC] %@: IOServiceOpen=0x%08x",
                    serviceClass, result))
            }
            if result == KERN_SUCCESS {
                smcOpened = true
                break
            }
        }
        return smcOpened
    }

    // SMCKeyData_t matches the Stats app's struct layout (github.com/exelban/stats)
    private struct SMCKeyData_t {
        struct vers_t {
            var major: UInt8 = 0
            var minor: UInt8 = 0
            var build: UInt8 = 0
            var reserved: UInt8 = 0
            var release: UInt16 = 0
        }
        struct LimitData_t {
            var version: UInt16 = 0
            var length: UInt16 = 0
            var cpuPLimit: UInt32 = 0
            var gpuPLimit: UInt32 = 0
            var memPLimit: UInt32 = 0
        }
        struct keyInfo_t {
            var dataSize: UInt32 = 0
            var dataType: UInt32 = 0
            var dataAttributes: UInt8 = 0
            // Swift may reuse a nested struct's tail padding when laying out
            // the parent. Keep these bytes explicit so result/status/data8
            // land at the offsets required by the AppleSMC C ABI.
            var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
        }

        var key: UInt32 = 0
        var vers = vers_t()
        var pLimitData = LimitData_t()
        var keyInfo = keyInfo_t()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    private func fourCC(_ s: String) -> UInt32 {
        SMCNumberDecoder.fourCC(s)
    }

    private func smcCall(_ input: inout SMCKeyData_t, _ output: inout SMCKeyData_t) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData_t>.stride
        var outputSize = MemoryLayout<SMCKeyData_t>.stride
        return IOConnectCallStructMethod(smcConn, 2, &input, inputSize, &output, &outputSize)
    }

    private struct SMCValue {
        let dataType: UInt32
        let bytes: [UInt8]
    }

    private func readSMCValue(_ key: String) -> SMCValue? {
        guard smcOpened else { return nil }
        let diagnostics = CommandLine.arguments.contains("--smc-test")

        // Step 1: Get key info
        var ki = SMCKeyData_t()
        var ko = SMCKeyData_t()
        ki.key = fourCC(key)
        ki.data8 = 9  // kSMCGetKeyInfo
        let keyInfoResult = smcCall(&ki, &ko)
        guard keyInfoResult == KERN_SUCCESS else {
            if diagnostics {
                print(String(
                    format: "[SMC] %@ keyInfo=0x%08x stride=%d",
                    key, keyInfoResult, MemoryLayout<SMCKeyData_t>.stride))
            }
            return nil
        }

        // Step 2: Read value
        var ri = SMCKeyData_t()
        var ro = SMCKeyData_t()
        ri.key = fourCC(key)
        ri.keyInfo.dataSize = ko.keyInfo.dataSize
        ri.data8 = 5  // kSMCReadKey
        let readResult = smcCall(&ri, &ro)
        guard readResult == KERN_SUCCESS else {
            if diagnostics {
                print(String(
                    format: "[SMC] %@ read=0x%08x size=%d type=0x%08x",
                    key, readResult, ko.keyInfo.dataSize, ko.keyInfo.dataType))
            }
            return nil
        }

        var tuple = ro.bytes
        let size = min(Int(ko.keyInfo.dataSize), 32)
        let bytes = withUnsafeBytes(of: &tuple) { raw in
            Array(raw.prefix(size))
        }
        if diagnostics {
            print(String(
                format: "[SMC] %@ size=%d type=0x%08x result=%d status=%d",
                key, size, ko.keyInfo.dataType, ro.result, ro.status))
        }
        return SMCValue(dataType: ko.keyInfo.dataType, bytes: bytes)
    }

    private func readSMCNumber(_ key: String) -> Double? {
        guard let value = readSMCValue(key) else { return nil }
        #if arch(arm64)
        let floatLittleEndian = true
        #else
        let floatLittleEndian = false
        #endif
        return SMCNumberDecoder.decode(
            dataType: value.dataType,
            bytes: value.bytes,
            floatLittleEndian: floatLittleEndian)
    }

    private func readSMCString(_ key: String) -> String? {
        guard let value = readSMCValue(key) else { return nil }
        let bytes = value.bytes.prefix { $0 != 0 }
        guard !bytes.isEmpty else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    private func readSMCTemp(_ key: String) -> Double? {
        readSMCNumber(key)
    }

    deinit {
        if smcOpened {
            IOServiceClose(smcConn)
        }
    }
}
