import AppKit
import Foundation

/// The Command Bar's inline answers: math, unit conversions, dates and colors. All worked out on
/// this Mac, nothing sent anywhere. Each returns nil when the text isn't for it.
nonisolated enum CommandAnswers {
    // MARK: Math

    /// "12*7", "(3+4)^2", "sqrt(2)", "15% of 80", "2pi". Plain numbers alone aren't answered.
    static func math(_ text: String) -> (answer: String, value: Double)? {
        var source = text.trimmingCharacters(in: .whitespaces).lowercased()
        if source.hasPrefix("=") { source.removeFirst() }
        source = source.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: ",", with: "")
        // "15% of 80" → 15/100*80
        if let range = source.range(of: #"^\s*([\d.]+)\s*%\s*of\s*([\d.]+)\s*$"#, options: .regularExpression) {
            let parts = source[range].components(separatedBy: CharacterSet(charactersIn: "% of")).filter { !$0.isEmpty }
            if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]) { return (format(a / 100 * b), a / 100 * b) }
        }
        guard source.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/^%()")) != nil
                || ["sqrt", "sin", "cos", "tan", "log", "ln", "abs", "pi", "round", "floor", "ceil"].contains(where: source.contains)
        else { return nil }
        var parser = MathParser(source)
        guard let value = parser.parse(), value.isFinite else { return nil }
        return (format(value), value)
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 10
        formatter.usesGroupingSeparator = false
        return formatter.string(from: value as NSNumber) ?? String(value)
    }

    /// A small recursive-descent parser: + - * / ^ %, brackets, implied multiplication ("2pi",
    /// "3(4+1)"), and a few functions and constants.
    struct MathParser {
        private let chars: [Character]
        private var i = 0

        init(_ text: String) { chars = Array(text.filter { !$0.isWhitespace }) }

        mutating func parse() -> Double? {
            guard let value = expression(), i == chars.count else { return nil }
            return value
        }

        private var peek: Character? { i < chars.count ? chars[i] : nil }

        private mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let c = peek, c == "+" || c == "-" {
                i += 1
                guard let rhs = term() else { return nil }
                value = c == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while let c = peek {
                if c == "*" || c == "/" {
                    i += 1
                    guard let rhs = power() else { return nil }
                    value = c == "*" ? value * rhs : value / rhs
                } else if c == "%" {
                    i += 1
                    // "a % b" is the remainder; a trailing "%" means percent.
                    if let next = peek, next.isNumber || next == "(" || next == "." {
                        guard let rhs = power() else { return nil }
                        value = value.truncatingRemainder(dividingBy: rhs)
                    } else {
                        value /= 100
                    }
                } else if c == "(" || c.isLetter {
                    guard let rhs = power() else { return nil }   // implied multiplication
                    value *= rhs
                } else { break }
            }
            return value
        }

        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek == "^" {
                i += 1
                guard let exponent = power() else { return nil }   // right-associative
                return pow(base, exponent)
            }
            return base
        }

        private mutating func unary() -> Double? {
            if peek == "-" { i += 1; return unary().map { -$0 } }
            if peek == "+" { i += 1; return unary() }
            return primary()
        }

        private mutating func primary() -> Double? {
            guard let c = peek else { return nil }
            if c == "(" {
                i += 1
                guard let value = expression(), peek == ")" else { return nil }
                i += 1
                return value
            }
            if c.isNumber || c == "." {
                var text = ""
                while let d = peek, d.isNumber || d == "." { text.append(d); i += 1 }
                if peek == "e", i + 1 < chars.count, chars[i + 1].isNumber || chars[i + 1] == "-" {   // 1e6
                    text.append("e"); i += 1
                    if peek == "-" { text.append("-"); i += 1 }
                    while let d = peek, d.isNumber { text.append(d); i += 1 }
                }
                return Double(text)
            }
            if c.isLetter {
                var name = ""
                while let d = peek, d.isLetter { name.append(d); i += 1 }
                switch name {
                case "pi", "π": return .pi
                case "e": return M_E
                default: break
                }
                guard peek == "(" else { return nil }
                i += 1
                guard let arg = expression(), peek == ")" else { return nil }
                i += 1
                switch name {
                case "sqrt": return sqrt(arg)
                case "sin": return sin(arg)
                case "cos": return cos(arg)
                case "tan": return tan(arg)
                case "log": return log10(arg)
                case "ln": return log(arg)
                case "abs": return abs(arg)
                case "round": return arg.rounded()
                case "floor": return floor(arg)
                case "ceil": return ceil(arg)
                default: return nil
                }
            }
            return nil
        }
    }

    // MARK: Units

    /// "5 km in miles", "100f to c", "2.5 l in cups", "1 gb in mb".
    static func units(_ text: String) -> String? {
        let pattern = #"^\s*(-?[\d.,]+)\s*([a-zA-Z°µ²³ "'/]+?)\s+(?:in|to|as|into|=)\s+([a-zA-Z°µ²³ "'/]+?)\s*$"#
        guard let match = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let ns = String(text[match]) as NSString
        guard let m = regex.firstMatch(in: ns as String, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges == 4 else { return nil }
        let amountText = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")
        guard let amount = Double(amountText),
              let from = unit(ns.substring(with: m.range(at: 2))), let to = unit(ns.substring(with: m.range(at: 3))),
              type(of: from) == type(of: to) else { return nil }
        let result = Measurement(value: amount, unit: from).converted(to: to)
        return "\(format((result.value * 1e6).rounded() / 1e6)) \(label(ns.substring(with: m.range(at: 3)), unit: to))"
    }

    private static func label(_ typed: String, unit: Dimension) -> String {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .short
        return formatter.string(from: unit)
    }

    private static func unit(_ raw: String) -> Dimension? {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let unit = unitNames[name] { return unit }
        if name.hasSuffix("s"), let unit = unitNames[String(name.dropLast())] { return unit }   // plurals
        return nil
    }

    private static let unitNames: [String: Dimension] = {
        var map: [String: Dimension] = [:]
        func add(_ unit: Dimension, _ names: String...) { for n in names { map[n] = unit } }
        // Length
        add(UnitLength.millimeters, "mm", "millimeter", "millimetre")
        add(UnitLength.centimeters, "cm", "centimeter", "centimetre")
        add(UnitLength.meters, "m", "meter", "metre")
        add(UnitLength.kilometers, "km", "kilometer", "kilometre")
        add(UnitLength.inches, "in", "inch", "inche", "\"")
        add(UnitLength.feet, "ft", "foot", "feet", "'")
        add(UnitLength.yards, "yd", "yard")
        add(UnitLength.miles, "mi", "mile")
        add(UnitLength.nauticalMiles, "nmi", "nautical mile")
        // Mass
        add(UnitMass.milligrams, "mg", "milligram")
        add(UnitMass.grams, "g", "gram")
        add(UnitMass.kilograms, "kg", "kilogram", "kilo")
        add(UnitMass.ounces, "oz", "ounce")
        add(UnitMass.pounds, "lb", "lbs", "pound")
        add(UnitMass.stones, "st", "stone")
        add(UnitMass.metricTons, "t", "tonne", "metric ton")
        // Temperature
        add(UnitTemperature.celsius, "c", "°c", "celsius", "centigrade")
        add(UnitTemperature.fahrenheit, "f", "°f", "fahrenheit")
        add(UnitTemperature.kelvin, "k", "kelvin")
        // Volume
        add(UnitVolume.milliliters, "ml", "milliliter", "millilitre")
        add(UnitVolume.liters, "l", "liter", "litre")
        add(UnitVolume.teaspoons, "tsp", "teaspoon")
        add(UnitVolume.tablespoons, "tbsp", "tablespoon")
        add(UnitVolume.fluidOunces, "fl oz", "floz", "fluid ounce")
        add(UnitVolume.cups, "cup")
        add(UnitVolume.pints, "pt", "pint")
        add(UnitVolume.quarts, "qt", "quart")
        add(UnitVolume.gallons, "gal", "gallon")
        // Speed
        add(UnitSpeed.kilometersPerHour, "kmh", "km/h", "kph")
        add(UnitSpeed.milesPerHour, "mph")
        add(UnitSpeed.metersPerSecond, "m/s")
        add(UnitSpeed.knots, "kn", "knot")
        // Area
        add(UnitArea.squareMeters, "m²", "sqm", "square meter", "square metre")
        add(UnitArea.squareKilometers, "km²", "square kilometer")
        add(UnitArea.squareFeet, "sqft", "ft²", "square foot", "square feet")
        add(UnitArea.acres, "acre", "ac")
        add(UnitArea.hectares, "ha", "hectare")
        // Time
        add(UnitDuration.seconds, "s", "sec", "second")
        add(UnitDuration.minutes, "min", "minute")
        add(UnitDuration.hours, "h", "hr", "hour")
        // Data
        add(UnitInformationStorage.bytes, "b", "byte")
        add(UnitInformationStorage.kilobytes, "kb", "kilobyte")
        add(UnitInformationStorage.megabytes, "mb", "megabyte")
        add(UnitInformationStorage.gigabytes, "gb", "gigabyte")
        add(UnitInformationStorage.terabytes, "tb", "terabyte")
        add(UnitInformationStorage.kibibytes, "kib", "kibibyte")
        add(UnitInformationStorage.mebibytes, "mib", "mebibyte")
        add(UnitInformationStorage.gibibytes, "gib", "gibibyte")
        // Energy
        add(UnitEnergy.kilocalories, "kcal", "calorie", "cal")
        add(UnitEnergy.kilojoules, "kj", "kilojoule")
        return map
    }()

    // MARK: Dates

    /// "3 weeks from today", "in 10 days", "40 days ago", "tomorrow", "days until dec 25".
    static func dates(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        switch t {
        case "today", "now": return formatter.string(from: now)
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: now).map(formatter.string)
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: now).map(formatter.string)
        default: break
        }
        let units: [String: Calendar.Component] = ["day": .day, "week": .weekOfYear, "month": .month, "year": .year, "hour": .hour, "minute": .minute]
        let offset = #"^(?:in\s+)?(\d+)\s+(day|week|month|year|hour|minute)s?(?:\s+(from\s+(?:now|today)|ago|later))?$"#
        if let regex = try? NSRegularExpression(pattern: offset),
           let m = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let amount = Int((t as NSString).substring(with: m.range(at: 1))),
           let component = units[(t as NSString).substring(with: m.range(at: 2))] {
            let tail = m.range(at: 3).location == NSNotFound ? "" : (t as NSString).substring(with: m.range(at: 3))
            // Only answer when it's clearly about a date ("in 5 days", "5 days ago", "5 days from now").
            guard t.hasPrefix("in ") || !tail.isEmpty else { return nil }
            guard let date = calendar.date(byAdding: component, value: tail == "ago" ? -amount : amount, to: now) else { return nil }
            if component == .hour || component == .minute { formatter.timeStyle = .short }
            return formatter.string(from: date)
        }
        if t.hasPrefix("days until ") || t.hasPrefix("days till ") || t.hasPrefix("days to ") {
            let rest = String(t.drop(while: { $0 != " " }).dropFirst().drop(while: { $0 != " " }).dropFirst())
            guard let target = detectDate(rest, now: now, calendar: calendar) else { return nil }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: target)).day ?? 0
            return "\(days) day\(abs(days) == 1 ? "" : "s") (\(formatter.string(from: target)))"
        }
        return nil
    }

    /// A date written in plain words; a date already past this year means next year's.
    private static func detectDate(_ text: String, now: Date, calendar: Calendar) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              var date = match.date else { return nil }
        if date < calendar.startOfDay(for: now), !text.contains(where: \.isNumber) || !text.contains(String(calendar.component(.year, from: date))) {
            date = calendar.date(byAdding: .year, value: 1, to: date) ?? date
        }
        return date
    }

    // MARK: Colors

    /// "#3a7", "#33aa77", "rgb(51, 170, 119)", "hsl(155, 54%, 43%)" → the color and its three spellings.
    static func color(_ text: String) -> (color: NSColor, hex: String, rgb: String, hsl: String)? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        var rgb: (Double, Double, Double)?
        if t.hasPrefix("#") {
            var hex = String(t.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            if hex.count == 8 { hex = String(hex.prefix(6)) }
            if hex.count == 6, let v = UInt32(hex, radix: 16) {
                rgb = (Double(v >> 16 & 0xff), Double(v >> 8 & 0xff), Double(v & 0xff))
            }
        } else if t.hasPrefix("rgb") {
            let n = numbers(t)
            if n.count >= 3, n[0...2].allSatisfy({ (0...255).contains($0) }) { rgb = (n[0], n[1], n[2]) }
        } else if t.hasPrefix("hsl") {
            let n = numbers(t)
            if n.count >= 3, (0...100).contains(n[1]), (0...100).contains(n[2]) {
                rgb = hslToRGB(n[0], n[1] / 100, n[2] / 100)
            }
        }
        guard let (r, g, b) = rgb else { return nil }
        let color = NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
        let hex = String(format: "#%02X%02X%02X", Int(r.rounded()), Int(g.rounded()), Int(b.rounded()))
        let (h, s, l) = rgbToHSL(r / 255, g / 255, b / 255)
        return (color, hex, "rgb(\(Int(r.rounded())), \(Int(g.rounded())), \(Int(b.rounded())))",
                "hsl(\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)")
    }

    private static func numbers(_ text: String) -> [Double] {
        text.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).compactMap(Double.init)
    }

    private static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h.truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch hp {
        case 0..<1: (c, x, 0)
        case 1..<2: (x, c, 0)
        case 2..<3: (0, c, x)
        case 3..<4: (0, x, c)
        case 4..<5: (x, 0, c)
        default: (c, 0, x)
        }
        let m = l - c / 2
        return ((r + m) * 255, (g + m) * 255, (b + m) * 255)
    }

    private static func rgbToHSL(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maxV = max(r, g, b), minV = min(r, g, b)
        let l = (maxV + minV) / 2
        guard maxV != minV else { return (0, 0, l) }
        let d = maxV - minV
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        var h: Double
        if maxV == r { h = (g - b) / d + (g < b ? 6 : 0) } else if maxV == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h *= 60
        return (h, s, l)
    }
}

/// How well a query matches a name: a whole-name or word-start match ranks above a match inside a
/// word, and that above the letters appearing in order ("vsc" → "Visual Studio Code"). Nil: no match.
nonisolated enum Fuzzy {
    static func score(_ query: String, _ text: String) -> Double? {
        let q = query.lowercased(), t = text.lowercased()
        guard !q.isEmpty else { return nil }
        if t == q { return 100 }
        if t.hasPrefix(q) { return 90 - Double(t.count - q.count) * 0.1 }
        let words = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(q) }) { return 75 - Double(t.count - q.count) * 0.05 }
        // Several words, each starting a word: "sys set" → System Settings.
        let parts = q.split(separator: " ")
        if parts.count > 1, parts.allSatisfy({ part in words.contains { $0.hasPrefix(part) } }) { return 72 }
        // Initials: "vsc" → Visual Studio Code.
        let initials = String(words.compactMap(\.first))
        if q.count >= 2, initials.hasPrefix(q) { return 70 }
        if t.contains(q) { return 55 - Double(t.count - q.count) * 0.05 }
        // Letters in order.
        guard q.count >= 2 else { return nil }
        var index = t.startIndex, gaps = 0
        for c in q {
            guard let found = t[index...].firstIndex(of: c) else { return nil }
            gaps += t.distance(from: index, to: found)
            index = t.index(after: found)
        }
        return max(10, 35 - Double(gaps))
    }
}
