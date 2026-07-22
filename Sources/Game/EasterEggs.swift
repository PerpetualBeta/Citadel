// Citadel — terminal easter eggs.
//
// Activating USE beside a computer desk zooms into its terminal and shows one of
// these on the amber screen (Terminal.swift renders them). Each is seen at most
// ONCE per session; the pool drains as the player reads them, and once every one
// has been seen any further terminal reveals the Amiga GURU MEDITATION instead.
// Session tracking lives on the Renderer (in-memory → resets each launch).
//
// The three story documents are INTERACTIVE: LEFT / RIGHT page backwards and
// forwards through them, so each unfolds a back-story across several screens —
//   • Director's Log — the professional / command view of the colony's fall
//   • ARC memos      — the corporate view, darkly funny doublespeak
//   • ARCMAIL        — the human view: Kirsty Smith's emails home to her mum
// The mini-game (Space Invaders) and the bare pop-culture nods are single-screen.
//
// CONTENT IS PLACEHOLDER — Jonathan is directing the real entries. Each document
// is just a list of pages; add or rewrite freely. Keep bodies to ~8 lines / ~52
// cols so they sit above the page footer without paging within a screen.

import Foundation

enum TerminalEggKind {
    case directorsLog   // ARC facility director's log (professional view)
    case email          // ARCMAIL — Kirsty Smith's letters home (human view)
    case memo           // ARC internal memo / notice (corporate view)
    case miniGame       // the one interactive game — an amber Space Invaders clone
    case blankMessage   // a bare screen with a couple of centred lines (pop-culture nods)

    /// Screen masthead for this form (rendered small, amber, letter-spaced).
    /// (Unused by .miniGame and .blankMessage, which draw themselves.)
    var banner: String {
        switch self {
        case .directorsLog: return "DIRECTOR'S LOG"
        case .email:        return "ARCMAIL \u{2014} INBOX"
        case .memo:         return "ARC \u{2014} INTERNAL MEMO"
        case .miniGame:     return "ARC//ARCADE"
        case .blankMessage: return ""
        }
    }
}

/// One screen of a document: its own header line (stardate / subject / RE:) and body.
struct TerminalPage {
    let sub: String
    let body: [String]
}

struct TerminalEgg {
    let kind: TerminalEggKind
    let pages: [TerminalPage]

    var pageCount: Int { pages.count }

    /// Convenience for a single-screen egg (blank nods / the mini-game slot).
    static func single(_ kind: TerminalEggKind, sub: String = "", body: [String] = []) -> TerminalEgg {
        TerminalEgg(kind: kind, pages: [TerminalPage(sub: sub, body: body)])
    }

    static let all: [TerminalEgg] = [
        // ── 1. Director's Log — the professional's view; a back-story across pages ──
        TerminalEgg(kind: .directorsLog, pages: [
            TerminalPage(sub: "STARDATE 7738.0  \u{00B7}  ARRIVAL", body: [
                "Assumed command of Demeter Station today.",
                "Population four thousand. The mandate is",
                "simple: extract, refine, ship. ARC calls it",
                "\"the deepest colony ever sunk.\" They mean it",
                "as a boast.",
                "",
                "The lifts take forty minutes to the surface.",
                "You stop counting after the first week.",
            ]),
            TerminalPage(sub: "STARDATE 7742.3  \u{00B7}  ROUTINE", body: [
                "Day 210 below the crust. The reactor hums,",
                "the quotas are met, the sun is a rumour.",
                "",
                "Corporate reminds us the Citadel \"runs itself.\"",
                "It does. We are, increasingly, a formality.",
                "",
                "I have started dating my logs by the shift",
                "rotations. It is easy to forget there is a sky.",
            ]),
            TerminalPage(sub: "STARDATE 7749.6  \u{00B7}  ANOMALY", body: [
                "Something in the lower galleries is not on",
                "the manifest. Seismics that aren't seismics.",
                "A warmth where the rock should be cold.",
                "",
                "I have logged it three times. Three times the",
                "log has been \u{2014} amended. Not by me, and not",
                "from this station.",
            ]),
            TerminalPage(sub: "STARDATE 7755.1  \u{00B7}  SUB-LEVEL 7", body: [
                "Sealed Sub-level 7 this morning. Corporate",
                "overruled me by lunch. \"Legacy asset,\" they",
                "said. It has a heartbeat. I have heard it",
                "through two metres of shielding.",
                "",
                "Six of my people are down there and ARC will",
                "not say why. I am a formality with a title.",
            ]),
            TerminalPage(sub: "STARDATE 7760.4  \u{00B7}  FINAL ENTRY", body: [
                "If you are reading this, the lifts are down",
                "and so are we. Do not come for the ore.",
                "Do not come for us. There is nothing left",
                "to retake but the dark \u{2014} and it is awake.",
                "",
                "\u{2014} Director, Demeter Station. Signing off.",
            ]),
        ]),
        // ── 2. ARCMAIL — Kirsty Smith to her mum; the human perspective, an arc ──
        TerminalEgg(kind: .email, pages: [
            TerminalPage(sub: "TO: MUM   \u{00B7}   RE: I MADE IT!", body: [
                "Hi Mum,",
                "",
                "Landed on Demeter today! The brochure said",
                "\"resort colony.\" The brochure lied \u{2014} it's dark,",
                "it's loud, and everything hums. But the pay is",
                "real and the people are kind.",
                "",
                "Tell Dad his awful lunchbox note made me cry in",
                "front of my whole intake. Love you \u{2014} Kirsty x",
            ]),
            TerminalPage(sub: "TO: MUM   \u{00B7}   RE: SETTLING IN", body: [
                "Week three. I can find the canteen without the",
                "map now, which counts as a promotion round here.",
                "",
                "My bunkmate Ana says the old hands never look at",
                "the lower galleries. \"Nothing down there but",
                "company secrets,\" she says, and laughs.",
                "She doesn't quite laugh, though. You know the one.",
            ]),
            TerminalPage(sub: "TO: MUM   \u{00B7}   RE: (no subject)", body: [
                "Mum, something's off. They moved a whole shift",
                "to Sub-level 7 and none of them came up for mess.",
                "Ana went to ask about it \u{2014} now her bunk's empty",
                "too. Nobody will say a word.",
                "",
                "I keep hearing it through the walls at night. Like",
                "a heartbeat, but too big. Probably just tired.",
                "Write back soon? Please.",
            ]),
            TerminalPage(sub: "TO: MUM   \u{00B7}   RE: (no subject)", body: [
                "if you get this the lifts only go DOWN now and",
                "the lights are nearly gone. i'm in a maintenance",
                "crawl with three others and we're being quiet.",
                "it's close.",
                "",
                "tell dad i wasn't scared. that's a lie but tell",
                "him anyway.",
                "",
                "i love you \u{2014} K",
            ]),
        ]),
        // ── 3. ARC memos — the corporate view; escalating, darkly funny ──
        TerminalEgg(kind: .memo, pages: [
            TerminalPage(sub: "RE: MORALE, PRODUCTIVITY & YOU", body: [
                "ALL STAFF \u{2014} PRIORITY: ROUTINE",
                "",
                "1. Unscheduled screaming is down 4% this cycle.",
                "   Excellent work, everyone.",
                "2. The thing in Sub-level 7 is a \"legacy asset.\"",
                "   Do not name it. Naming implies ownership.",
                "3. Your loyalty bonus is now additional loyalty.",
            ]),
            TerminalPage(sub: "RE: SUB-LEVEL 7 \u{2014} FAQ", body: [
                "Q: What is the noise?       A: There is no noise.",
                "Q: What is the smell?       A: Productivity.",
                "Q: Where is my shift team?  A: Reassigned.",
                "",
                "Please direct further questions to the empty",
                "office where Employee Relations used to be.",
            ]),
            TerminalPage(sub: "RE: NEW OVERTIME OPPORTUNITIES", body: [
                "Great news! Due to \"staffing volatility,\" all",
                "shifts are now double shifts.",
                "",
                "Rest periods have been converted to standing",
                "periods. Standing periods have been converted to",
                "opportunities. You have never had so many",
                "opportunities. Congratulations.",
            ]),
            TerminalPage(sub: "RE: THIS IS FINE", body: [
                "A brief note as containment is \"optimised\":",
                "",
                "1. The lifts going down is a feature.",
                "2. The lights going out is mood lighting.",
                "3. The screaming is back, but on-brand.",
                "",
                "ARC \u{2014} A Brighter Tomorrow, Underground\u{2122}",
            ]),
        ]),
        // ── 4. The mini-game — amber Space Invaders. Pages unused; the terminal
        //       detects `.miniGame` and runs SpaceInvaders on the glass. ──
        .single(.miniGame),
        // ── 5. Zero Wing (Toaplan, 1991) — the ur-meme, on a bare screen. ──
        .single(.blankMessage, body: [
            "All your base are belong to us",
        ]),
        // ── 6. The KLF / The Justified Ancients of Mu Mu — a nod to a favourite. ──
        .single(.blankMessage, body: [
            "They're justified & ancient",
            "Mu Mu!",
        ]),
    ]
}
