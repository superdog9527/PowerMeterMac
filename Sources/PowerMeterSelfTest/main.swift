import Foundation
import PowerMeterCore
import CUSB

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}
func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }

check(rejects { try SafetyPolicy.validate(millivolts: 599) }, "reject 599 mV")
check((try? SafetyPolicy.millivolts(from: "4.000")) == 4000, "accept 4.000 V")
check((try? SafetyPolicy.millivolts(from: "5.000")) == 5000, "accept documented 5.000 V maximum")
check(rejects { _ = try SafetyPolicy.millivolts(from: "5.001") }, "reject above 5 V")
var cBoundaryExact = true
for value in 0...65535 {
    let payload = [UInt8(value & 255), UInt8(value >> 8)]
    let accepted = payload.withUnsafeBufferPointer { pm_validate_command(3, $0.baseAddress, 2, 0) == 0 }
    if accepted != (600...5000).contains(value) { cBoundaryExact = false; break }
}
check(cBoundaryExact, "C USB gate accepts exactly 600 through 5000 mV")
check(EngineeringFormat.current(nanoamps: 1_500) == "1.500 µA" &&
      EngineeringFormat.current(nanoamps: -2_500_000, signed: true) == "-2.500 mA",
      "current values select engineering units")
check(EngineeringFormat.time(seconds: 0.000_02, signed: true) == "+20.000 µs" &&
      EngineeringFormat.time(seconds: 1.5) == "1.500 s" &&
      EngineeringFormat.time(seconds: 0) == "0.000 s",
      "marker times and deltas select engineering units")
var one: UInt8 = 1
check(pm_validate_command(5, &one, 1, 0) < 0 && pm_validate_command(5, &one, 1, 1) == 0,
      "C USB gate requires confirmed voltage before output enable")

let a: [UInt8] = [0xed,0xde,0,0,9,0,0,1,0]
let b: [UInt8] = [0xed,0xde,0,0,9,0,31,2,0]
var parser = FrameParser()
check(parser.feed(Array(a.prefix(4))).isEmpty, "retain fragmented header")
check(parser.feed(Array(a.dropFirst(4)) + b).count == 2, "parse joined frames")
var corrupt = FrameParser()
check(corrupt.feed([0xed,0xde,0,0,9,0,2,1,0]).isEmpty && corrupt.discardedBytes == 9, "reject invalid range")
var d20 = Downsampler(rate: .k20)
check(d20.process([1,2,3,4,5]) == [3], "20 kHz averaging")
var d10 = Downsampler(rate: .k10)
check(d10.process(Array(1...10).map(Float.init)) == [5.5], "10 kHz trimmed mean")

var viewport = TimeViewport(duration: 10)
viewport.update(earliest: 0, latest: 2)
check(viewport.start == 0 && viewport.end == 10 && viewport.fraction(at: 2) == 0.2, "2 seconds occupies only 20 percent of 10 second window")
viewport.update(earliest: 0, latest: 15)
check(viewport.start == 5 && viewport.end == 15, "live window remains exactly 10 seconds")
viewport.move(to: 2, earliest: 0, latest: 15)
viewport.update(earliest: 0, latest: 30)
check(viewport.start == 2 && viewport.end == 12 && !viewport.followsLatest, "panning freezes position without zoom")
viewport.move(to: -20, earliest: 0, latest: 15)
check(viewport.start == 0 && viewport.end == 10, "pan clamps at history start")
viewport.move(to: 40, earliest: 0, latest: 15)
check(viewport.start == 5 && viewport.end == 15, "pan clamps at history end")
viewport.zoom(to: 2, anchorFraction: 0.5, earliest: 0, latest: 30)
check(abs(viewport.start - 9) < 0.000001 && abs(viewport.end - 11) < 0.000001,
      "X zoom preserves time under cursor")
check(AxisZoom.next(10, inward: true, levels: AxisZoom.durations) == 5 &&
      AxisZoom.next(10, inward: false, levels: AxisZoom.durations) == 20,
      "axis zoom advances one defined level")
check(AxisZoom.target(x: 90, y: 220, plotMinX: 78, plotMaxX: 110,
                      plotMinY: 45, plotMaxY: 200, width: 120, height: 250) == .x,
      "scroll over X axis targets X zoom")
check(AxisZoom.target(x: 20, y: 100, plotMinX: 78, plotMaxX: 110,
                      plotMinY: 45, plotMaxY: 200, width: 120, height: 250) == .y,
      "scroll over Y axis targets Y zoom")
check(AxisZoom.target(x: 90, y: 100, plotMinX: 78, plotMaxX: 110,
                      plotMinY: 45, plotMaxY: 200, width: 120, height: 250) == nil &&
      AxisZoom.target(x: 20, y: 220, plotMinX: 78, plotMaxX: 110,
                      plotMinY: 45, plotMaxY: 200, width: 120, height: 250) == nil,
      "scroll over plot or axis corner is ignored")
let history = SampleHistory(capacity: 4)
history.append((0..<6).map { Measurement(index: UInt64($0), nanoamps: Float($0)) })
let frozen = history.snapshot()
history.append([Measurement(index: 6, nanoamps: 6)])
check(history.startIndex == 3 && history.endIndex == 7 && history.measurements().map(\.nanoamps) == [3,4,5,6], "ring keeps chronological samples after wrap")
check(frozen.startIndex == 2 && frozen.measurements().map(\.nanoamps) == [2,3,4,5], "history view remains unchanged as new samples arrive")
history.reset()
check(history.count == 0 && history.endIndex == 0, "new capture resets sample clock")
let waveform = SampleHistory(capacity: 20)
waveform.append([1, 2, 50, 4, 5, 6, 7, 8, 9, 10].enumerated().map { Measurement(index: UInt64($0.offset), nanoamps: Float($0.element)) })
let visible = waveform.visibleRange(start: 0.2, end: 0.5, rate: 10)
check(visible == 2..<5 && waveform.average(in: visible) == Float(59.0 / 3), "window average uses only visible samples, excludes right boundary")
let partial = waveform.visibleRange(start: 0, end: 10, rate: 10)
check(waveform.average(in: partial) == 10.2, "blank time is excluded from average")
check(waveform.average(in: waveform.visibleRange(start: 5, end: 10, rate: 10)) == nil, "empty window has no average")
let marker = waveform.nearest(to: 0.26, rate: 10, in: visible)
check(marker?.index == 3 && marker?.nanoamps == 4, "marker snaps to actual nearest sample with exact current")
check(waveform.nearest(to: 0.5, rate: 10, in: visible)?.index == 4, "marker clamps to last visible sample")
let polyline = waveform.polyline(in: partial, columns: 2)
check(polyline.map(\.index) == [0,2,4,5,9], "polyline preserves temporal order and actual extrema")
check(polyline.allSatisfy { $0.nanoamps == waveform.value(at: $0.index) }, "polyline contains no interpolated values")
check(waveform.polyline(in: partial, columns: 100).count == 10, "sparse polyline retains every sample")
let voltageHistory = SampleHistory(capacity: 4)
voltageHistory.append([
    Measurement(index: 0, nanoamps: 1_000, millivolts: 3300),
    Measurement(index: 1, nanoamps: 2_000, millivolts: 5000)
])
check(voltageHistory.measurements().compactMap(\.millivolts) == [3300, 5000],
      "sample history preserves voltage changes")
let csvURL = FileManager.default.temporaryDirectory.appendingPathComponent("PowerMeterCSV-\(UUID().uuidString).csv")
do {
    try CSVExporter.write(voltageHistory.measurements(), rate: .k100, millivolts: 3300, to: csvURL)
    let csv = try String(contentsOf: csvURL, encoding: .utf8)
    let rows = csv.split(separator: "\n").dropFirst().map { $0.split(separator: ",") }
    check(rows.count == 2 && rows[0][4] == "3.3" && rows[1][4] == "5.0" &&
          abs((Double(rows[0][5]) ?? 0) - 0.0000033) < 1e-12 &&
          abs((Double(rows[1][5]) ?? 0) - 0.00001) < 1e-12,
          "CSV exports per-sample voltage and power")
} catch { check(false, "CSV exports per-sample voltage and power: \(error)") }
try? FileManager.default.removeItem(at: csvURL)
let auditURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("PowerMeterSelfTest-\(UUID().uuidString)/commands.jsonl")
do {
    let audit = try CommandAuditLog(url: auditURL)
    try audit.record(session: "test", phase: "request", opcode: 3, payload: [0xE4, 0x0C])
    try audit.record(session: "test", phase: "response", opcode: 3, payload: [0xE4, 0x0C], result: 13)
    let lines = try String(contentsOf: auditURL, encoding: .utf8).split(separator: "\n")
    check(lines.count == 2 && lines[0].contains("0x03") && lines[0].contains("E40C") && lines[1].contains("13"),
          "command audit persists request and response payloads")
} catch { check(false, "command audit persists request and response payloads: \(error)") }
try? FileManager.default.removeItem(at: auditURL.deletingLastPathComponent())
if failures > 0 { exit(1) }
