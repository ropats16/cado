import Foundation
import NaturalLanguage

/// Rejects confidently recognized languages the installed model does not
/// support, before they can become misleading notes. Romanized and mixed
/// speech can evade language detection; never claim this handles all of it.
enum SummaryLanguageSupport {
    static func isClearlyUnsupported(_ text: String, supports: (String) -> Bool) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage,
              let confidence = recognizer.languageHypotheses(withMaximum: 1)[language],
              confidence >= 0.9 else { return false }
        return !supports(language.rawValue)
    }
}
