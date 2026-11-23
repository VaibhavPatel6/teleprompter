import Foundation

/// Pure matcher for voice-follow mode: given words the speech recognizer
/// heard, works out how far into the script the speaker has got.
///
/// Rules, in order, for each heard word:
/// 1. It matches the next script word (allowing small mishearings) -> advance.
/// 2. It matches one of the two words after that (the recognizer dropped a
///    word) -> advance past it.
/// 3. It ends a run of three heard words that matches three consecutive script
///    words further ahead, within the next two sentence endings after the
///    current word (the speaker skipped something) -> jump there.
/// Otherwise the word is treated as ad-lib and position holds.
/// A hyphenated script word ("Control-Option-Space") also matches when the
/// recognizer hears its parts as separate words.
struct VoiceFollower {
    private let script: [String]           // normalized script words
    private let endsSentence: [Bool]
    private let parts: [[String]]          // "Control-Option-Space" -> [control, option, space]
    private var state = MatchState()
    var spokenCount: Int { state.pos }      // script words spoken so far

    private struct MatchState {
        var pos = 0
        var recentUnmatched: [String] = []
        var partsHeard = 0                  // parts heard so far of a hyphenated word
    }

    init(words: [Word]) {
        script = words.map { VoiceFollower.normalize($0.text) }
        endsSentence = words.map { $0.endsSentence || $0.endsParagraph }
        parts = words.map { word in
            word.text.split(whereSeparator: { "-–—/".contains($0) }).map { VoiceFollower.normalize(String($0)) }.filter { !$0.isEmpty }
        }
    }

    /// Advance permanently for words the recognizer has finalized.
    mutating func commit(heard: [String]) {
        state = advanced(state, heard: heard)
    }

    /// Where the speaker would be if these in-progress words were finalized.
    func preview(heard: [String]) -> Int {
        advanced(state, heard: heard).pos
    }

    mutating func jump(to count: Int) {
        state = MatchState(pos: min(max(0, count), script.count))
    }

    // MARK: Matching

    private func advanced(_ start: MatchState, heard: [String]) -> MatchState {
        var st = start
        for raw in heard {
            let w = VoiceFollower.normalize(raw)
            guard !w.isEmpty else { continue }
            if st.pos < script.count && parts[st.pos].count > 1 {
                let wordParts = parts[st.pos]
                if st.partsHeard == 0 && Self.similar(w, script[st.pos]) {
                    st = MatchState(pos: st.pos + 1)      // heard whole, e.g. "well-known"
                    continue
                }
                if Self.similar(w, wordParts[st.partsHeard]) {
                    st.partsHeard += 1
                    if st.partsHeard == wordParts.count { st = MatchState(pos: st.pos + 1) }
                    continue
                }
                st.partsHeard = 0
            }
            var pos = st.pos
            if let skip = (0...2).first(where: { pos + $0 < script.count && Self.similar(w, script[pos + $0]) && ($0 == 0 || w.count >= 3) }) {
                pos += skip + 1
                st = MatchState(pos: pos)
                continue
            }
            st.recentUnmatched = Array((st.recentUnmatched + [w]).suffix(3))
            if st.recentUnmatched.count == 3, let j = runStart(matching: st.recentUnmatched, after: pos) {
                st = MatchState(pos: j + 3)
            }
        }
        return st
    }

    /// First index j in the look-ahead window where script[j..<j+3] matches run.
    private func runStart(matching run: [String], after pos: Int) -> Int? {
        let last = windowEnd(from: pos)
        guard pos + 3 <= last else { return nil }
        for j in pos...(last - 2) where zip(run, script[j..<j + 3]).allSatisfy({ Self.similar($0, $1) }) {
            return j
        }
        return nil
    }

    /// Index of the second sentence ending after the word at `pos`: the rest
    /// of the current sentence plus the next one, or, when stuck on a
    /// sentence's last word, the next two sentences.
    private func windowEnd(from pos: Int) -> Int {
        var ends = 0
        var i = pos + 1
        while i < script.count {
            if endsSentence[i] { ends += 1; if ends == 2 { return i } }
            i += 1
        }
        return script.count - 1
    }

    /// Exact match, or close enough: one edit apart for words of 4+ letters,
    /// two for words of 8+ ("teleprompture" ~ "teleprompter").
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let shorter = min(a.count, b.count)
        let allowed = shorter >= 8 ? 2 : shorter >= 4 ? 1 : 0
        guard allowed > 0, abs(a.count - b.count) <= allowed else { return false }
        return editDistance(Array(a), Array(b)) <= allowed
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// Lowercase and keep only letters and digits ("I'm," -> "im").
    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
