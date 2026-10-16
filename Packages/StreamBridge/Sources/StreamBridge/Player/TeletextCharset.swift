// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// The G0 character sets teletext pages are written in, from ETSI EN 300 706 clause 15.
///
/// A page's header bits C12–C14 give a 3-bit option, and packets X/28 or M/29 the 4-bit group (table 32). Most
/// broadcasts never send the group, so the stream's language stands in for it.
struct TeletextCharset: Equatable {
    enum Alphabet: Equatable {
        case latin(LatinSubset)
        case cyrillic1
        case cyrillic2
        case cyrillic3
        case greek
    }

    /// The national variants of the Latin set, which replace 13 positions (table 36).
    enum LatinSubset: Int, CaseIterable {
        case english, german, swedish, italian, french, portugueseSpanish, czechSlovak, polish, turkish,
             serbianCroatianSlovenian, rumanian, estonian, lettishLithuanian
    }

    let alphabet: Alphabet

    /// The set for a page: `group` from packet X/28 or M/29 (or guessed from the language), `option` from the
    /// page header's C12, C13 and C14 bits, C12 being the most significant.
    init(group: Int, option: Int) {
        alphabet = Self.table32[group]?[option] ?? .latin(.english)
    }

    init(_ alphabet: Alphabet) {
        self.alphabet = alphabet
    }

    /// The group a language's broadcasts use, for when the stream doesn't say. ISO 639-2 codes.
    static func group(forLanguage language: String?) -> Int? {
        switch language?.lowercased() {
        case "pol": 1
        case "tur": 2
        case "ron", "rum", "hrv", "scr", "slv", "srp", "bos": 3
        case "rus", "bul", "ukr", "bel", "mkd", "est", "lav", "lit": 4
        case "gre", "ell": 6
        default: nil
        }
    }

    /// The character for a 7-bit code from 0x20 to 0x7F, or `nil` for the block at 0x7F.
    func character(_ code: UInt8) -> Character? {
        guard (0x20...0x7E).contains(code) else { return nil }
        let index = Int(code) - 0x20
        switch alphabet {
        case .latin(let subset):
            if let position = Self.nationalPositions.firstIndex(of: code) {
                return Self.nationalSubsets[subset]![position]
            }
            return Character(Unicode.Scalar(code))
        case .cyrillic1: return Self.cyrillic1[index]
        case .cyrillic2: return Self.cyrillic2[index]
        case .cyrillic3: return Self.cyrillic3[index]
        case .greek: return Self.greek[index]
        }
    }

    // MARK: - Tables

    /// Table 32, by group (bits 14–11) and option (bits 10–8). Arabic and Hebrew pages fall back to Latin.
    private static let table32: [Int: [Int: Alphabet]] = [
        0: [0: .latin(.english), 1: .latin(.german), 2: .latin(.swedish), 3: .latin(.italian), 4: .latin(.french),
            5: .latin(.portugueseSpanish), 6: .latin(.czechSlovak)],
        1: [0: .latin(.polish), 1: .latin(.german), 2: .latin(.swedish), 3: .latin(.italian), 4: .latin(.french),
            6: .latin(.czechSlovak)],
        2: [0: .latin(.english), 1: .latin(.german), 2: .latin(.swedish), 3: .latin(.italian), 4: .latin(.french),
            5: .latin(.portugueseSpanish), 6: .latin(.turkish)],
        3: [5: .latin(.serbianCroatianSlovenian), 7: .latin(.rumanian)],
        4: [0: .cyrillic1, 1: .latin(.german), 2: .latin(.estonian), 3: .latin(.lettishLithuanian), 4: .cyrillic2,
            5: .cyrillic3, 6: .latin(.czechSlovak)],
        6: [6: .latin(.turkish), 7: .greek],
        8: [0: .latin(.english), 4: .latin(.french)],
    ]

    private static let nationalPositions: [UInt8] = [0x23, 0x24, 0x40, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F, 0x60, 0x7B, 0x7C, 0x7D, 0x7E]

    /// Table 36, in the order of `nationalPositions`.
    private static let nationalSubsets: [LatinSubset: [Character]] = [
        .english: Array("£$@←½→↑#—¼‖¾÷"),
        .german: Array("#$§ÄÖÜ^_°äöüß"),
        .swedish: Array("#¤ÉÄÖÅÜ_éäöåü"),
        .italian: Array("£$é°ç→↑#ùàòèì"),
        .french: Array("éïàëêùî#èâôûç"),
        .portugueseSpanish: Array("ç$¡áéíóú¿üñèà"),
        .czechSlovak: Array("#ůčťžýířéáěúš"),
        .polish: Array("#ńąƵŚŁćóężśłź"),
        .turkish: Array("₺ğİŞÖÇÜĞışöçü"),
        .serbianCroatianSlovenian: Array("#ËČĆŽĐŠëčćžđš"),
        .rumanian: Array("#¤ŢÂŞĂÎıţâşăî"),
        .estonian: Array("#õŠÄÖŽÜÕšäöžü"),
        .lettishLithuanian: Array("#$ŠėęŽčūšąųžį"),
    ]

    /// Tables 38 to 40 and 42: codes 0x20 to 0x7E.
    private static let cyrillic1 = Array(##" !"#$%&'()*+,-./0123456789:;<=>?ЧАБЦДЕФГХИЈКЛМНОПЌРСТУВЃЉЊЗЋЖЂШЏчабцдефгхијклмнопќрстувѓљњзћжђш"##)
    private static let cyrillic2 = Array(##" !"#$%ы'()*+,-./0123456789:;<=>?ЮАБЦДЕФГХИЙКЛМНОПЯРСТУЖВЬЪЗШЭЩЧЫюабцдефгхийклмнопярстужвьъзшэщч"##)
    private static let cyrillic3 = Array(##" !"#$%ї'()*+,-./0123456789:;<=>?ЮАБЦДЕФГХИЙКЛМНОПЯРСТУЖВЬІЗШЄЩЧЇюабцдефгхийклмнопярстужвьізшєщч"##)
    private static let greek = Array(##" !"#$%&'()*+,-./0123456789:;«=»?ΐΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡ΄ΣΤΥΦΧΨΩΪΫάέήίΰαβγδεζηθικλμνξοπρςστυφχψωϊϋόύώ"##)
}
