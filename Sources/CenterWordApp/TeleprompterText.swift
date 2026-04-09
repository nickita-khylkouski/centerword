import Foundation

struct TeleprompterText {
    static func words(in text: String) -> [String] {
        var tokens: [String] = []
        var currentWord = ""
        let characters = Array(text)

        func flushCurrentWord() {
            guard !currentWord.isEmpty else {
                return
            }

            tokens.append(currentWord)
            currentWord.removeAll(keepingCapacity: true)
        }

        for index in characters.indices {
            let character = characters[index]

            if character.isWhitespace {
                flushCurrentWord()
                continue
            }

            let previousCharacter = index > characters.startIndex ? characters[characters.index(before: index)] : nil
            let nextIndex = characters.index(after: index)
            let nextCharacter = nextIndex < characters.endIndex ? characters[nextIndex] : nil

            if isWordCharacter(character, previousCharacter: previousCharacter, nextCharacter: nextCharacter) {
                currentWord.append(character)
                continue
            }

            flushCurrentWord()
            tokens.append(String(character))
        }

        flushCurrentWord()
        return tokens
    }

    static func isFastSeparatorToken(_ token: String) -> Bool {
        guard token.count == 1, let character = token.first else {
            return false
        }

        return !character.isWhitespace && !isWordCharacter(character, previousCharacter: nil, nextCharacter: nil)
    }

    private static func isWordCharacter(
        _ character: Character,
        previousCharacter: Character?,
        nextCharacter: Character?
    ) -> Bool {
        if character == "'" || character == "’" {
            return previousCharacter.map(isAlphanumeric) == true && nextCharacter.map(isAlphanumeric) == true
        }

        return isAlphanumeric(character)
    }

    private static func isAlphanumeric(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    }
}
