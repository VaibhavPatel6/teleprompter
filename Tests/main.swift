import Foundation

var failures = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String, line: UInt = #line) {
    if actual == expected {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name) (line \(line)): got \(actual), expected \(expected)")
    }
}

// At 60 WPM each word takes one second.
do {
    var p = Pacer(script: "one two three", wpm: 60)
    expect(p.words.map(\.text), ["one", "two", "three"], "splits the script into words")
    expect(p.currentIndex, 0, "starts on the first word")
    p.advance(by: 1.5)
    expect(p.currentIndex, 1, "is on the second word after 1.5s at 60 WPM")
    p.advance(by: 1.0)
    expect(p.currentIndex, 2, "is on the third word after 2.5s at 60 WPM")
}

// Pauses: comma +0.5 word, sentence end +1 word, paragraph break +2 words.
do {
    var p = Pacer(script: "Hi, there. You\n\nok", wpm: 60)
    p.advance(by: 1.4)
    expect(p.currentIndex, 0, "comma holds the word for 1.5s at 60 WPM")
    p.advance(by: 0.2)
    expect(p.currentIndex, 1, "moves on after the comma pause")
    // "there." starts at 1.5 and lasts 2.0 -> ends at 3.5
    p.advance(by: 1.8) // t = 3.4
    expect(p.currentIndex, 1, "sentence end holds the word for 2s")
    p.advance(by: 0.2) // t = 3.6
    expect(p.currentIndex, 2, "moves on after the sentence pause")
    // "You" + paragraph break lasts 3.0 -> ends at 6.5
    p.advance(by: 2.8) // t = 6.4
    expect(p.currentIndex, 2, "paragraph break holds the word for 3s")
    p.advance(by: 0.2)
    expect(p.currentIndex, 3, "moves on after the paragraph pause")
    expect(p.words[2].endsParagraph, true, "marks the last word of a paragraph")
}

// Back one sentence: to the start of this sentence, or the previous one
// if we're already on a sentence's first word.
do {
    var p = Pacer(script: "A b. C d. E f.", wpm: 60)
    p.advance(by: 4.5) // A=1, b.=2, C=1 -> on "d." (index 3)
    expect(p.currentIndex, 3, "is mid-sentence on d.")
    p.backOneSentence()
    expect(p.currentIndex, 2, "jumps to the start of the current sentence")
    p.backOneSentence()
    expect(p.currentIndex, 0, "from a sentence start, jumps to the previous sentence")
    p.backOneSentence()
    expect(p.currentIndex, 0, "stays at the beginning")
    p.advance(by: 0.5)
    p.restart()
    p.advance(by: 0.9)
    expect(p.currentIndex, 0, "restart resets the clock for the current word too")
}

// Finishing: done once the last word's time has passed.
do {
    var p = Pacer(script: "one two", wpm: 60)
    p.advance(by: 1.5)
    expect(p.isFinished, false, "not finished while on the last word")
    p.advance(by: 1.0)
    expect(p.isFinished, true, "finished after the last word's time")
    expect(p.currentIndex, 1, "stays on the last word when finished")
}

// Ranges: each word knows where it sits in the script (UTF-16, for AppKit).
do {
    let p = Pacer(script: "Hi,  thére\n\nyo", wpm: 60)
    expect(p.words.map(\.range), [NSRange(location: 0, length: 3), NSRange(location: 5, length: 5), NSRange(location: 12, length: 2)], "records each word's range")
    expect(Pacer(script: "   \n ", wpm: 60).isFinished, true, "an empty script is already finished")
}

// Forward one sentence: to the start of the next sentence.
do {
    var p = Pacer(script: "A b. C d. E f.", wpm: 60)
    p.forwardOneSentence()
    expect(p.currentIndex, 2, "forward jumps to the next sentence start")
    p.advance(by: 0.5)
    p.forwardOneSentence()
    expect(p.currentIndex, 4, "forward from mid-word still lands on the next sentence")
    p.forwardOneSentence()
    expect(p.currentIndex, 4, "forward on the last sentence stays put")
    expect(p.words.nextSentenceStart(after: 0), 2, "nextSentenceStart is shared with voice mode")
    expect(p.words.sentenceStart(atOrBefore: 3), 2, "sentenceStart is shared with voice mode")
}

// Jump: used to keep your place when switching between voice and timed mode.
do {
    var p = Pacer(script: "a b c d", wpm: 60)
    p.advance(by: 0.5)
    p.jump(to: 2)
    p.advance(by: 0.9)
    expect(p.currentIndex, 2, "jump lands on the word and restarts its clock")
    p.jump(to: 99)
    expect(p.currentIndex, 3, "jump clamps to the last word")
}

// MARK: VoiceFollower

func follower(_ script: String) -> VoiceFollower {
    VoiceFollower(words: Pacer(script: script, wpm: 60).words)
}

do {
    var f = follower("Hi, I'm Vaibhav. Thanks for having me.")
    expect(f.spokenCount, 0, "voice: nothing spoken at start")
    f.commit(heard: ["hi", "Im"])
    expect(f.spokenCount, 2, "voice: matching words advance, ignoring case and punctuation")
}

do {
    var f = follower("Thanks for having me today.")
    f.commit(heard: ["um", "so", "yeah"])
    expect(f.spokenCount, 0, "voice: ad-libbed words hold position")
    f.commit(heard: ["thank"])
    expect(f.spokenCount, 1, "voice: a one-letter mishearing still matches (thank ~ thanks)")
}

do {
    var f = follower("I love building small tools.")
    f.commit(heard: ["I", "building", "small"])
    expect(f.spokenCount, 4, "voice: a word the recognizer dropped is skipped over")
}

do {
    var f = follower("One two three. Four five six. Seven eight nine.")
    f.commit(heard: ["four", "five", "six"])
    expect(f.spokenCount, 6, "voice: three matching words in a row re-sync after a skipped sentence")
}

do {
    var f = follower("One two three. Four five six. Seven eight nine.")
    f.commit(heard: ["four"])
    expect(f.spokenCount, 0, "voice: one word far ahead is not enough to jump")
    f.commit(heard: ["five", "six"])
    expect(f.spokenCount, 6, "voice: a matching run can span separate recognizer results")
}

do {
    var f = follower("A b c. D e f. G h i. Hello there friend.")
    f.commit(heard: ["hello", "there", "friend"])
    expect(f.spokenCount, 0, "voice: won't jump past the next sentence")
}

do {
    let f = follower("One two three.")
    expect(f.preview(heard: ["one", "two"]), 2, "voice: preview shows in-progress speech")
    expect(f.spokenCount, 0, "voice: preview does not commit")
}

do {
    var f = follower("Press Control-Option-Space to start.")
    f.commit(heard: ["press", "control", "option"])
    expect(f.spokenCount, 1, "voice: a hyphenated word waits until all its parts are heard")
    f.commit(heard: ["space", "to"])
    expect(f.spokenCount, 3, "voice: a hyphenated word matches when heard as separate words")
    var g = follower("A well-known fact.")
    g.commit(heard: ["a", "well-known", "fact"])
    expect(g.spokenCount, 3, "voice: a hyphenated word heard with its hyphen still matches")
}

// Cases taken from a live recognizer log.
do {
    var f = follower("Welcome to your teleprompter. Paste your script.")
    f.commit(heard: ["Welcome", "to", "your", "teleprompture."])
    expect(f.spokenCount, 4, "voice: long words tolerate a two-letter mishearing")
}

do {
    var f = follower("Welcome to your teleprompter. Paste your script with Edit. In voice mode the words follow you.")
    f.commit(heard: ["welcome", "to", "your", "xyz", "let", "me", "think"])
    expect(f.spokenCount, 3, "voice: stuck on a sentence's last word")
    f.commit(heard: ["in", "voice", "mode"])
    expect(f.spokenCount, 12, "voice: from a sentence's last word, looks two sentences ahead")
}

do {
    var f = follower("Press Control-Option-Space now.")
    f.commit(heard: ["press", "control", "options", "space"])
    expect(f.spokenCount, 2, "voice: parts of a hyphenated word tolerate small mishearings")
}

exit(failures == 0 ? 0 : 1)
