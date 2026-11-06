import Foundation
import MGDomain
import WhoopProtocol

/// WhoopProtocol decodes → MGDomain strap records (ARCHITECTURE §4.3 "MGBLE maps; MGStore stores").
/// Pure functions with no actor isolation, so a history chunk is decoded off the main actor (as noop's
/// Backfiller does, Backfiller.swift L603-640) while store → ack ordering stays on the link.
enum RecordMapper {
    /// v26 records carry one 25-sample PPG window per second: an absolute base code plus 24 i16 deltas
    /// (noop Interpreter `decodeWhoop5HistoricalV26`, #2019). MGDomain's `PPGBlock` is "value = base + sample", so
    /// the deltas are integrated first (WhoopProtocol `ppgWaveformAbsolute`) and stored as offsets from the base:
    /// 25 samples, the first 0. Raw ADC counts, no unit.
    /// Wave 4 (2026-10-11): the RATE is the record's own flags byte (frame byte 10 = inner[2]) bit 7: set = 25 Hz,
    /// clear = 50 Hz (OpenStrap protocol `gen5_records.dart` L65-104 @6e8c570, `ppgSampleRateHz`; noop's fixed 24 Hz is
    /// ~4 % off). `ppgWindowHz` is only the fallback when a window's frame is not found.
    static let ppgWindowHz = 25.0

    static func ppgRateHz(_ frame: [UInt8]) -> Double { (frame[10] & 0x80) != 0 ? 25 : 50 }

    /// The full chunk for one HISTORY_END. `frames` are the offload frames between START and END, in arrival order.
    /// `metaFrames` = the METADATA frames (types 49 / 56: START, END and any others) that bracketed the chunk; they are
    /// kept raw too (T9746) but are not counted in `frameCount`.
    static func historyChunk(frames: [[UInt8]], token: HistoryEndToken, strapId: StrapID, receivedAt: Date,
                             wallNow: Int, metaFrames: [[UInt8]] = []) -> HistoryChunk {
        var batch = historyBatch(frames: frames, strapId: strapId, receivedAt: receivedAt, wallNow: wallNow)
        batch.rawFrames += metaFrames.map {
            RawFrame(receivedAt: receivedAt, packetType: $0.count > 8 ? Int($0[8]) : 0, bytes: Data($0))
        }
        var stamps: [Int64] = []
        stamps += batch.hr.map(\.ts)
        stamps += batch.rr.map(\.ts)
        stamps += batch.seconds.map(\.ts)
        stamps += batch.ppg.map(\.ts)
        stamps += batch.events.map(\.ts)
        stamps += batch.r20.map(\.ts)
        stamps += batch.motion.map(\.ts)
        let endToken = Data(token.bytes)
        return HistoryChunk(chunkId: HistoryChunk.makeID(strapId: strapId, endToken: endToken), strapId: strapId,
                            endToken: endToken,
                            trim: token.trim, firstTs: stamps.min(), lastTs: stamps.max(), records: batch,
                            frameCount: frames.count)
    }

    /// Decode one chunk's frames. Records with an implausible own timestamp (before 2023-11 or more than a day
    /// ahead of `wallNow`) are dropped by the same gate noop uses (`isPlausibleHistoricalUnix`, #547). Frames
    /// nothing below maps — unmapped layouts, v20/v21 optical blocks, CRC failures, console logs — are kept as
    /// `rawFrames` so acking the chunk never loses bytes (noop `rejectedHistoricalRecords`, #77/#91;
    /// ARCHITECTURE §4.4.4). T9746 (2026-10-14, Mo: "archive everything"): EVERY frame of the chunk is kept raw, decoded
    /// or not — normal R18 and R26 records, events, console text, metadata, short frames — so a field nobody decodes
    /// yet (R18 bytes 106-109, byte 81 beyond the nibble, R22) can still be read from the PC's raw archive later.
    /// Cost: about 124 bytes per strap second for R18 (about 10 MB a day before compression).
    static func historyBatch(frames: [[UInt8]], strapId: StrapID, receivedAt: Date, wallNow: Int) -> StrapRecordBatch {
        let parsed = frames.map { parseFrame($0, family: .whoop5) }
        let streams = extractHistoricalStreams(parsed, deviceClockRef: wallNow, wallClockRef: wallNow,
                                               family: .whoop5, wallNow: wallNow)

        let hr = streams.hr.filter { $0.bpm > 0 }.map {
            HRPoint(ts: Int64($0.ts), bpm: Double($0.bpm), source: .history)
        }
        var ords = RROrdinals()
        let rr = streams.rr.map { beat -> RRPoint in
            let ts = Int64(beat.ts)
            return RRPoint(ts: ts, ord: ords.next(for: ts), rrMs: Double(beat.rrMs), source: .history)
        }
        var ppgRate: [Int: Double] = [:]          // v26 strap unix → its own rate (flags bit 7)
        for f in frames where f.count > 18 && f[8] == 47 && f[9] == 26 {
            ppgRate[Int(f[15]) | Int(f[16]) << 8 | Int(f[17]) << 16 | Int(f[18]) << 24] = ppgRateHz(f)
        }
        let ppg: [PPGBlock] = streams.ppgWaveform.compactMap { (w: PpgWaveformSample) -> PPGBlock? in
            // No base code → the window has no recoverable level; the frame itself is not kept raw either (v26
            // is a mapped layout), matching noop, which stores such a window with a nil base.
            guard let baseCode = w.baseCode, let base = Int32(exactly: baseCode),
                  let absolute = ppgWaveformAbsolute(baseCode: baseCode, deltas: w.samples) else { return nil }
            let offsets = absolute.compactMap { Int32(exactly: $0 - baseCode) }
            guard offsets.count == absolute.count else { return nil }
            return PPGBlock(ts: Int64(w.ts), rateHz: ppgRate[w.ts] ?? ppgWindowHz, base: base, samples: offsets)
        }
        let battery: [BatteryReading] = streams.battery.compactMap { (b: BatterySample) -> BatteryReading? in
            guard let soc = b.soc else { return nil }
            return BatteryReading(ts: Int64(b.ts), percent: soc, charging: b.charging)
        }

        var seconds: [R18Second] = []
        var events: [StrapEvent] = []
        var r20: [R20Record] = []
        var motion: [MotionSecond] = []
        var raw: [RawFrame] = []
        for (frame, p) in zip(frames, parsed) {
            // T9746: a frame too short to carry a type / version is still raw (type 0 = none readable)
            guard frame.count > 9 else {
                raw.append(RawFrame(receivedAt: receivedAt, packetType: frame.count > 8 ? Int(frame[8]) : 0,
                                    bytes: Data(frame)))
                continue
            }
            let type = frame[8]
            let intact = p.ok && p.crcOK != false
            if type == 47, intact, p.parsed["hist_version"]?.intValue == 18, let s = r18Second(p, wallNow: wallNow) {
                seconds.append(s)
            }
            // v20 (R20 optical, banked by 107): decoded into `r20` AND kept raw below (v20 is not 18/26), so the chunk
            // is stored and acked like any other — the offload cursor always advances (noop #1992: undecoded v20
            // records looped the offload). Implausible timestamps are dropped from `r20` only.
            if type == 47, version20(frame), let rec = r20Record(frame, source: "history"),
               isPlausibleHistoricalUnix(Int(rec.ts), wallNow: wallNow) {
                r20.append(rec)
            }
            // Wave W8: banked R21 (raw motion, layout 21) → `motion` too; it stays raw below (v21 is not 18/26).
            if type == 47, let m = RawMotionDecode.motionSecond(frame, source: "history"),
               isPlausibleHistoricalUnix(Int(m.ts), wallNow: wallNow) {
                motion.append(m)
            }
            if type == 48, intact, let e = strapEvent(frame: frame, parsed: p),
               isPlausibleHistoricalUnix(Int(e.ts), wallNow: wallNow) {
                events.append(e)
            }
            // Before T9746 only rejected / unmapped / CRC-failed frames, console text, other layouts and the v18 SpO₂
            // windows (byte 82 nonzero, wave 4 #25) were kept; now every frame is.
            raw.append(RawFrame(receivedAt: receivedAt, packetType: Int(type), bytes: Data(frame)))
        }
        return StrapRecordBatch(strapId: strapId, hr: hr, rr: rr, seconds: seconds, ppg: ppg, events: events,
                                battery: battery, rawFrames: raw, r20: r20, motion: motion)
    }

    static func version20(_ frame: [UInt8]) -> Bool {
        frame.count == Whoop5RawOptical.bufferLength && frame[9] == Whoop5RawOptical.layoutVersion
    }

    /// One R20 record (WhoopProtocol `Whoop5RawOptical`: CRC-gated, nil on any mismatch). `source` "history" decodes
    /// the banked type-47 form, "live" the type-43 form 108 streams. Blocks are kept by index with their 21 raw head
    /// bytes — no wavelength label (none is established on fw 50.42).
    static func r20Record(_ frame: [UInt8], source: String) -> R20Record? {
        let decoded = source == "live" ? Whoop5RawOptical.decodeRealtime(frame) : Whoop5RawOptical.decode(frame)
        guard let d = decoded else { return nil }
        return R20Record(ts: Int64(d.baseTs), recordIndex: Int64(d.recordIndex), source: source,
                         blocks: d.blocks.map { R20Block(index: $0.index, head: $0.rawHeader, slotA: $0.readingsA,
                                                         slotB: $0.readingsB) })
    }

    /// One v18 per-second record (noop Interpreter `decodeWhoop5Historical` field names). `spo2Byte` is the raw
    /// @82 byte (`aux_byte_82`, the tri-mode byte ALG-021 interprets) — never a percentage here. `optical50Hz`
    /// has no decoded source yet, so it stays nil.
    static func r18Second(_ p: ParsedFrame, wallNow: Int) -> R18Second? {
        guard let ts = p.parsed["unix"]?.intValue, isPlausibleHistoricalUnix(ts, wallNow: wallNow) else { return nil }
        let hr = p.parsed["heart_rate"]?.intValue.flatMap { $0 > 0 ? Double($0) : nil }
        let rrCount = p.parsed["rr_count"]?.intValue ?? (p.parsed["rr_intervals"]?.intArrayValue?.count ?? 0)
        return R18Second(ts: Int64(ts), hr: hr, rrCount: rrCount,
                         gx: p.parsed["gravity_x"]?.doubleValue, gy: p.parsed["gravity_y"]?.doubleValue,
                         gz: p.parsed["gravity_z"]?.doubleValue,
                         steps: p.parsed["step_motion_counter"]?.intValue,
                         activityClass: p.parsed["activity_class"]?.intValue,
                         skinTempRaw: p.parsed["skin_temp_raw"]?.intValue,
                         sleepState: p.parsed["sleep_state"]?.intValue,
                         spo2Byte: p.parsed["aux_byte_82"]?.intValue,
                         optical50Hz: nil,
                         // wave 4: optical signal-quality fields (frame 108 = psnrB, 109 = psnrA; OpenStrap L388-430)
                         quality: R18Quality.decode(words: ["status_word", "status_word_1", "status_word_2"]
                                                        .map { p.parsed[$0]?.intValue },
                                                    ampA: p.parsed["optical_amp_a"]?.intValue,
                                                    ampB: p.parsed["optical_amp_b"]?.intValue,
                                                    f32: p.parsed["unknown_f32_113"]?.doubleValue),
                         dynAccel: p.parsed["dynamic_acceleration"]?.doubleValue,
                         tempAux1Raw: p.parsed["temp_aux_1_raw"]?.intValue,
                         tempAux2Raw: p.parsed["temp_aux_2_raw"]?.intValue)
    }

    /// EVENT (type 48): number @10, real-unix timestamp @12 (whoop_protocol.json EVENT fields at the 5/MG +4
    /// shift). `payloadHex` is the frame body after the event number, up to the CRC32 trailer.
    static func strapEvent(frame: [UInt8], parsed p: ParsedFrame) -> StrapEvent? {
        guard frame.count > 10 + 4, let ts = p.parsed["event_timestamp"]?.intValue else { return nil }
        let number = Int(frame[10])
        let name = eventName(p.parsed["event"]?.stringValue) ?? "EVENT_\(number)"
        let body = frame.count - 4 > 11 ? Array(frame[11..<(frame.count - 4)]) : []
        return StrapEvent(ts: Int64(ts), number: number, name: name, payloadHex: body.hexLower)
    }

    /// "DOUBLE_TAP(14)" → "DOUBLE_TAP" (Schema.enumName appends the raw value). An unnamed number renders
    /// as "0x7B(123)" upstream; that is not a name, so nil.
    static func eventName(_ rendered: String?) -> String? {
        guard let rendered, let paren = rendered.firstIndex(of: "(") else { return nil }
        let name = String(rendered[..<paren])
        guard !name.isEmpty, !name.hasPrefix("0x") else { return nil }
        return name
    }
}

/// Emission order of R-R beats inside one second — the first sort key after `ts` (MGDomain RRPoint.ord;
/// noop #823). Survives across batches for live data so two frames landing in the same second never reuse an ord.
struct RROrdinals {
    private var counts: [Int64: Int] = [:]

    mutating func next(for ts: Int64) -> Int {
        let ord = counts[ts, default: 0]
        counts[ts] = ord + 1
        if counts.count > 4096, let newest = counts.keys.max() {   // bound memory on an all-night live stream
            counts = counts.filter { $0.key >= newest - 600 }
        }
        return ord
    }
}
