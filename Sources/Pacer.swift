import Foundation

/// One word of the script, plus the pause that follows it.
struct Word {
    let text: String
    /// Where the word sits in the script, in UTF-16 units (what AppKit uses).
    let range: NSRange
    let endsParagraph: Bool

    var endsSentence: Bool { text.last.map { ".!?".contains($0) } ?? false }

    /// How long this word stays current, measured in "word beats"
    /// (1 beat = 60 / wpm seconds).
    var beats: Double {
        var b = 1.0
        if endsSentence { b += 1.0 }
        else if let last = text.last, ",;:—".contains(last) { b += 0.5 }
        if endsParagraph { b += 2.0 }
        return b
    }
}

/// Pure pacing engine: turns a script plus a words-per-minute speed into
/// "which word is current right now". Knows nothing about windows or timers;
/// the UI calls `advance(by:)` with elapsed seconds.
struct Pacer {
    let words: [Word]
    var wpm: Double
    private(set) var currentIndex = 0
    private var elapsedInWord: Double = 0

    init(script: String, wpm: Double) {
        self.words = Pacer.tokenize(script)
        self.wpm = wpm
    }

    /// True once the last word has been on screen for its full time.
    var isFinished: Bool {
        guard let last = words.last else { return true }
        return currentIndex == words.count - 1 && elapsedInWord >= last.beats * 60.0 / wpm
    }

    mutating func advance(by seconds: Double) {
        guard !words.isEmpty else { return }
        elapsedInWord += seconds
        while currentIndex < words.count - 1 {
            let duration = words[currentIndex].beats * 60.0 / wpm
            guard elapsedInWord >= duration else { break }
            elapsedInWord -= duration
            currentIndex += 1
        }
    }

    /// Jump to the start of the current sentence, or to the previous
    /// sentence if already on a sentence's first word.
    mutating func backOneSentence() {
        var i = words.sentenceStart(atOrBefore: currentIndex)
        if i == currentIndex && i > 0 { i = words.sentenceStart(atOrBefore: i - 1) }
        currentIndex = i
        elapsedInWord = 0
    }

    /// Jump to the start of the next sentence (stays put on the last one).
    mutating func forwardOneSentence() {
        if let next = words.nextSentenceStart(after: currentIndex) {
            currentIndex = next
            elapsedInWord = 0
        }
    }

    mutating func jump(to index: Int) {
        currentIndex = Swift.min(Swift.max(0, index), Swift.max(0, words.count - 1))
        elapsedInWord = 0
    }

    mutating func restart() {
        currentIndex = 0
        elapsedInWord = 0
    }

    private static func tokenize(_ script: String) -> [Word] {
        let ns = script as NSString
        let regex = try! NSRegularExpression(pattern: "\\S+")
        let matches = regex.matches(in: script, range: NSRange(location: 0, length: ns.length))
        return matches.enumerated().map { i, m in
            var endsParagraph = false
            if i + 1 < matches.count {
                let gapStart = NSMaxRange(m.range)
                let gap = ns.substring(with: NSRange(location: gapStart, length: matches[i + 1].range.location - gapStart))
                endsParagraph = gap.filter(\.isNewline).count >= 2
            }
            return Word(text: ns.substring(with: m.range), range: m.range, endsParagraph: endsParagraph)
        }
    }
}

extension Array where Element == Word {
    private func endsSentence(_ i: Int) -> Bool { self[i].endsSentence || self[i].endsParagraph }

    /// Index of the first word of the sentence containing `index`.
    func sentenceStart(atOrBefore index: Int) -> Int {
        var i = index
        while i > 0 && !endsSentence(i - 1) { i -= 1 }
        return i
    }

    /// Index of the first word of the sentence after the one containing `index`.
    func nextSentenceStart(after index: Int) -> Int? {
        var i = index
        while i < count - 1 {
            if endsSentence(i) { return i + 1 }
            i += 1
        }
        return nil
    }
}
