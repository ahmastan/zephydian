import AppKit
import AVFoundation
import CoreServices

/// Words for the `dictionary` capability (SDK 4): definitions from the New Oxford American
/// Dictionary and synonyms from the Oxford American Writer's Thesaurus, both of which come with
/// macOS. Nothing is downloaded or runs in the background; each lookup reads Apple's files offline.
///
/// Apple documents only `DCSCopyTextDefinition`, which returns plain text from the first dictionary
/// that knows the word. The structured entries (senses, examples, synonym groups, opposites) come
/// from Dictionary Services functions Apple doesn't document, looked up with `dlsym`. If they ever
/// go away, definitions fall back to the plain text and synonyms report that they're unavailable.
final class PackDictionary {
    static let maxWord = 100

    private let api = Bridge.load()
    private var dictionary: AnyObject?
    private var thesaurus: AnyObject?
    private let speech = AVSpeechSynthesizer()

    // MARK: Lookups

    /// `{ word, found, entries: [...], suggestions }`, `{ word, found, plain }` from the fallback,
    /// or `{ word, found: false, available: false }` when the dictionary isn't on this Mac.
    func define(_ raw: String) -> [String: Any] {
        let word = Self.clean(raw)
        guard !word.isEmpty else { return ["word": word, "found": false, "suggestions": [String]()] }
        if let dict = source(.dictionary), let api {
            let entries = records(api, dict, word).compactMap(Self.parseDefinition)
            if !entries.isEmpty { return ["word": word, "found": true, "entries": entries] }
        } else if let text = Self.plainDefinition(word) {
            return ["word": word, "found": true, "plain": text]
        } else if Self.plainDefinition("word") == nil {
            return ["word": word, "found": false, "available": false]
        }
        return ["word": word, "found": false, "suggestions": suggestions(word)]
    }

    /// `{ word, found, entries: [{ headword, groups: [{ pos, senses: [...] }] }] }`, or
    /// `available: false` when the thesaurus can't be read.
    func synonyms(_ raw: String) -> [String: Any] {
        let word = Self.clean(raw)
        guard !word.isEmpty else { return ["word": word, "found": false, "suggestions": [String]()] }
        guard let api, let thes = source(.thesaurus) else { return ["word": word, "found": false, "available": false] }
        let entries = records(api, thes, word).compactMap(Self.parseThesaurus)
        if !entries.isEmpty { return ["word": word, "found": true, "entries": entries] }
        return ["word": word, "found": false, "suggestions": suggestions(word)]
    }

    /// Which of the two books this Mac has.
    func status() -> [String: Any] {
        ["dictionary": source(.dictionary) != nil || Self.plainDefinition("word") != nil,
         "thesaurus": api != nil && source(.thesaurus) != nil]
    }

    /// For a word the dictionary doesn't know: words it could be the start of, then spelling guesses.
    func suggestions(_ word: String) -> [String] {
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (word as NSString).length)
        let completions = word.contains(" ") ? [] : checker.completions(forPartialWordRange: range, in: word, language: "en", inSpellDocumentWithTag: 0) ?? []
        let guesses = checker.guesses(forWordRange: range, in: word, language: "en", inSpellDocumentWithTag: 0) ?? []
        var seen = Set<String>([word.lowercased()])
        return Array((completions.prefix(5) + guesses).filter { seen.insert($0.lowercased()).inserted }.prefix(8))
    }

    /// Says the word with the Mac's voice (offline).
    func speak(_ raw: String) {
        let word = Self.clean(raw)
        guard !word.isEmpty else { return }
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: word)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        speech.speak(utterance)
    }

    func stopSpeaking() { speech.stopSpeaking(at: .immediate) }

    /// Shows the word in Apple's Dictionary app.
    func openInApp(_ raw: String) {
        let word = Self.clean(raw)
        guard !word.isEmpty, let q = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "dict://\(q)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Finding the books

    private enum Book {
        case dictionary, thesaurus
        var id: String { self == .dictionary ? "com.apple.dictionary.NOAD" : "com.apple.dictionary.OAWT" }
        var file: String { self == .dictionary ? "New Oxford American Dictionary.dictionary" : "Oxford American Writer's Thesaurus.dictionary" }
    }

    /// The book, from the dictionaries the person has turned on in Apple's Dictionary app, or else
    /// straight from where macOS keeps it. Looked for again next time if it isn't there yet.
    private func source(_ book: Book) -> AnyObject? {
        if let found = book == .dictionary ? dictionary : thesaurus { return found }
        guard let api else { return nil }
        var found = api.active().first { api.identifier($0) == book.id }
        if found == nil {
            let fm = FileManager.default
            let base = URL(fileURLWithPath: "/System/Library/AssetsV2", isDirectory: true)
            let folders = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).filter { $0.contains("DictionaryServices") }
            search: for folder in folders {
                for asset in (try? fm.contentsOfDirectory(atPath: base.appendingPathComponent(folder).path)) ?? [] {
                    let url = base.appendingPathComponent(folder).appendingPathComponent(asset).appendingPathComponent("AssetData")
                        .appendingPathComponent(book.file)
                    if fm.fileExists(atPath: url.path), let dict = api.create(url) { found = dict; break search }
                }
            }
        }
        if book == .dictionary { dictionary = found } else { thesaurus = found }
        return found
    }

    /// The word's entries as XHTML documents, once each (a search can return the same entry twice).
    private func records(_ api: Bridge, _ dict: AnyObject, _ word: String) -> [XMLElement] {
        var seen = Set<String>()
        var entries: [XMLElement] = []
        for record in api.search(dict, word).prefix(6) {
            guard let xml = api.data(record),
                  let doc = try? XMLDocument(xmlString: xml, options: []),
                  let entry = Self.all(doc.rootElement(), "entry").first else { continue }
            let id = entry.attribute(forName: "id")?.stringValue ?? xml
            guard seen.insert(id).inserted else { continue }
            entries.append(entry)
        }
        // "-happy" (a suffix entry) only when nothing else matched.
        let whole = entries.filter { !(Self.title($0).hasPrefix("-") || Self.title($0).hasSuffix("-")) }
        return whole.isEmpty ? entries : whole
    }

    // MARK: Reading entries

    private static func parseDefinition(_ entry: XMLElement) -> [String: Any]? {
        guard let hg = all(entry, "hg").first else { return nil }
        var out: [String: Any] = [:]
        let hw = all(hg, "hw").first
        out["headword"] = hw.map { text($0, skip: ["ty_hom"]) } ?? title(entry)
        out["homograph"] = hw.flatMap { all($0, "ty_hom").first }.map { text($0) } ?? NSNull()
        out["syllables"] = all(hg, "syl_txt").first.map { text($0) } ?? NSNull()
        out["pronunciation"] = all(hg, "ph").first.map { text($0) } ?? NSNull()

        var groups: [[String: Any]] = []
        for se1 in all(entry, "se1", stopAt: ["subEntryBlock"]) {
            var senses: [[String: Any]] = []
            for m in all(se1, "msDict") {
                let sense = parseSense(m)
                if has(m, "t_subsense"), var last = senses.popLast() {
                    last["subsenses"] = (last["subsenses"] as? [[String: Any]] ?? []) + [sense]
                    senses.append(last)
                } else {
                    senses.append(sense)
                }
            }
            let posg = all(se1, "posg").first
            groups.append(["pos": posg.flatMap { all($0, "pos").first }.map { text($0) } ?? "",
                           "forms": posg.map { all($0, "inf").map { text($0) }.joined(separator: ", ") } ?? "",
                           "senses": Array(senses.prefix(40))])
        }
        out["groups"] = groups

        var phrases: [[String: Any]] = [], derivatives: [[String: Any]] = []
        for block in all(entry, "subEntryBlock") {
            for sub in all(block, "subEntry") {
                let phrase = all(sub, "l").first.map { text($0) } ?? ""
                guard !phrase.isEmpty else { continue }
                if has(block, "t_derivatives") {
                    derivatives.append(["word": phrase, "pos": all(sub, "pos").first.map { text($0) } ?? ""])
                } else {
                    phrases.append(["phrase": phrase, "senses": all(sub, "msDict").prefix(6).map(parseSense)])
                }
            }
        }
        out["phrases"] = Array(phrases.prefix(40))
        out["derivatives"] = Array(derivatives.prefix(20))
        out["origin"] = all(entry, "etym").first.map { text($0, skip: ["ty_label"]) } ?? NSNull()
        return groups.isEmpty && phrases.isEmpty ? nil : out
    }

    /// One sense: its labels ("[with object]", "informal"), the definition and up to four examples.
    private static func parseSense(_ m: XMLElement) -> [String: Any] {
        let labels = all(m, ["gg", "fg", "lg"], stopAt: ["eg", "df"]).map { text($0, skip: ["gp"]) }.filter { !$0.isEmpty }
        let definition = all(m, "df").first.map { text($0) } ?? text(m, skip: ["sn", "eg", "gg", "fg", "lg", "gp"])
        let examples = all(m, "ex").prefix(4).map { strip(text($0, skip: ["lbl"])) }.filter { !$0.isEmpty }
        return ["label": labels.joined(separator: " "), "text": definition, "examples": examples]
    }

    private static func parseThesaurus(_ entry: XMLElement) -> [String: Any]? {
        var groups: [[String: Any]] = []
        for se1 in all(entry, "se1", stopAt: ["subEntryBlock"]) {
            var senses: [[String: Any]] = []
            for m in all(se1, "msThes") {
                var synonyms: [[String: Any]] = [], labeled: [[String: Any]] = []
                for group in all(m, "synGroup") {
                    let words = all(group, "syn").map { ["word": text($0, skip: ["gp"]), "core": has($0, "t_core")] as [String: Any] }
                        .filter { !($0["word"] as? String ?? "").isEmpty }
                    let label = all(group, "lg").map { text($0) }.joined(separator: " ")
                    if label.isEmpty { synonyms += words } else { labeled.append(["label": label, "words": words.map { $0["word"]! }]) }
                }
                let antonyms = all(m, "ant").map { text($0, skip: ["gp"]) }.filter { !$0.isEmpty }
                guard !synonyms.isEmpty || !labeled.isEmpty else { continue }
                senses.append(["example": all(m, "ex").first.map { strip(text($0)) } ?? "",
                               "synonyms": synonyms, "labeled": labeled, "antonyms": antonyms])
            }
            guard !senses.isEmpty else { continue }
            let pos = all(se1, "posg").first.flatMap { all($0, "pos").first }.map { text($0) } ?? ""
            groups.append(["pos": pos, "senses": Array(senses.prefix(30))])
        }
        guard !groups.isEmpty else { return nil }
        let hw = all(entry, "hw").first.map { text($0, skip: ["ty_hom"]) } ?? title(entry)
        return ["headword": hw, "groups": groups]
    }

    // MARK: XHTML helpers

    private static func title(_ entry: XMLElement) -> String {
        entry.attribute(forName: "d:title")?.stringValue ?? entry.attributes?.first { $0.localName == "title" }?.stringValue ?? ""
    }

    private static func has(_ e: XMLElement, _ c: String) -> Bool {
        (e.attribute(forName: "class")?.stringValue ?? "").split(separator: " ").contains { $0 == c }
    }

    /// Descendants with one of these classes, in order. Doesn't look inside a match, or inside
    /// elements with a `stopAt` class.
    private static func all(_ root: XMLElement?, _ classes: [String], stopAt: [String] = []) -> [XMLElement] {
        var out: [XMLElement] = []
        func walk(_ e: XMLElement) {
            for case let child as XMLElement in e.children ?? [] {
                if classes.contains(where: { has(child, $0) }) { out.append(child); continue }
                if stopAt.contains(where: { has(child, $0) }) { continue }
                walk(child)
            }
        }
        if let root { walk(root) }
        return out
    }

    private static func all(_ root: XMLElement?, _ c: String, stopAt: [String] = []) -> [XMLElement] { all(root, [c], stopAt: stopAt) }

    /// The element's text without the parts inside it that have a `skip` class (and without
    /// homograph numbers, "hap¹"), with spaces tidied.
    private static func text(_ e: XMLElement, skip: [String] = []) -> String {
        var s = ""
        let skip = skip + ["ty_hom"]
        func walk(_ n: XMLNode) {
            if let el = n as? XMLElement {
                if skip.contains(where: { has(el, $0) }) { return }
                el.children?.forEach(walk)
            } else if n.kind == .text {
                s += n.stringValue ?? ""
            }
        }
        e.children?.forEach(walk)
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// An example without the ": " and quote marks around it.
    private static func strip(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: ":|. ").union(.whitespaces))
    }

    private static func clean(_ raw: String) -> String {
        String(raw.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(maxWord))
    }

    /// Apple's documented lookup: plain text from the first dictionary that knows the word.
    private static func plainDefinition(_ word: String) -> String? {
        let range = CFRange(location: 0, length: (word as NSString).length)
        return DCSCopyTextDefinition(nil, word as CFString, range)?.takeRetainedValue() as String?
    }

    // MARK: Dictionary Services

    /// The undocumented functions, found at run time. Nil if any is missing.
    private struct Bridge {
        typealias List = @convention(c) () -> Unmanaged<CFArray>?
        typealias Identifier = @convention(c) (AnyObject) -> Unmanaged<CFString>?
        typealias Create = @convention(c) (CFURL) -> Unmanaged<AnyObject>?
        typealias Search = @convention(c) (AnyObject, CFString, UnsafeRawPointer?, Int) -> Unmanaged<CFArray>?
        typealias Data = @convention(c) (AnyObject, Int) -> Unmanaged<CFString>?

        let activeFn: List
        let identifierFn: Identifier
        let createFn: Create
        let searchFn: Search
        let dataFn: Data

        static func load() -> Bridge? {
            guard let h = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW),
                  let active = dlsym(h, "DCSGetActiveDictionaries"), let identifier = dlsym(h, "DCSDictionaryGetIdentifier"),
                  let create = dlsym(h, "DCSDictionaryCreate"), let search = dlsym(h, "DCSCopyRecordsForSearchString"),
                  let data = dlsym(h, "DCSRecordCopyData") else { return nil }
            return Bridge(activeFn: unsafeBitCast(active, to: List.self), identifierFn: unsafeBitCast(identifier, to: Identifier.self),
                          createFn: unsafeBitCast(create, to: Create.self), searchFn: unsafeBitCast(search, to: Search.self),
                          dataFn: unsafeBitCast(data, to: Data.self))
        }

        func active() -> [AnyObject] { activeFn()?.takeUnretainedValue() as? [AnyObject] ?? [] }
        func identifier(_ d: AnyObject) -> String? { identifierFn(d)?.takeUnretainedValue() as String? }
        func create(_ url: URL) -> AnyObject? { createFn(url as CFURL)?.takeRetainedValue() }
        func search(_ d: AnyObject, _ word: String) -> [AnyObject] { searchFn(d, word as CFString, nil, 0)?.takeRetainedValue() as? [AnyObject] ?? [] }
        func data(_ record: AnyObject) -> String? { dataFn(record, 0)?.takeRetainedValue() as String? }
    }
}
