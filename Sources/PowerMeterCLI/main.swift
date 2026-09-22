import Foundation
import PowerMeterCore

func usage() { print("powermeter list | info | sample [seconds] [10|20|50|100]") }
do {
    let args = CommandLine.arguments
    guard args.count >= 2 else { usage(); exit(2) }
    switch args[1] {
    case "list": try USBDevice.discover().forEach { Swift.print($0) }
    case "info":
        let device = try USBDevice(); defer { device.close() }
        let data = try JSONEncoder().encode(device.info!); print(String(decoding: data, as: UTF8.self))
    case "sample":
        let seconds = args.count > 2 ? Double(args[2]) ?? 1 : 1
        let khz = args.count > 3 ? Int(args[3]) ?? 100 : 100
        guard let rate = SampleRate(rawValue: khz * 1000), seconds > 0, seconds <= 30 else { throw MeterError.message("采样参数无效") }
        let device = try USBDevice(); defer { device.close() }
        try device.setVoltage(3300) // output remains OFF
        let calibration = device.calibration!; var parser = FrameParser(); var decoder = try CurrentDecoder(calibration: calibration, millivolts: 3300); var down = Downsampler(rate: rate)
        try device.drain(); try device.setCapture(true); defer { try? device.setCapture(false) }
        let deadline = Date().addingTimeInterval(seconds); var values: [Float] = []
        while Date() < deadline { for frame in parser.feed(try device.read()) { values += down.process(decoder.decode(frame)) } }
        let avg = values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count)
        print("samples=\(values.count) rate=\(rate.rawValue)Hz average=\(avg)nA min=\(values.min() ?? 0)nA max=\(values.max() ?? 0)nA anomalies=\(parser.sequenceAnomalies)")
    default: usage(); exit(2)
    }
} catch { fputs("错误：\(error.localizedDescription)\n", stderr); exit(1) }
