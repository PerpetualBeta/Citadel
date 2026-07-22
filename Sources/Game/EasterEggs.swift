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
// CONTENT follows the Strataris / Citadel back-story: Demeter — deepest of the six
// colonies ARC sank into the cluster to mine Tantalanium — the intercepted signal
// and its false dawn of first contact, the marauder fleet, the fall, the retreat
// below, and the infestation the signal always heralded. The three documents view
// that one timeline through three lenses. The dates line up across them (the
// Director's DAY count, the memo REF numbers, Kirsty's arc). Keep bodies to <= 8
// lines / ~52 cols so they sit above the page footer without paging within a screen.

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
            TerminalPage(sub: "DEMETER  \u{00B7}  DAY 001  \u{00B7}  FIRST LIGHT", body: [
                "One year to build it, one day to fill it.",
                "The first crews rode the shafts down today,",
                "with the modest guard ARC saw fit to send.",
                "Deepest colony we have ever sunk \u{2014} I sank it.",
                "",
                "Tantalanium runs richer than the surveys dared:",
                "harder than diamond, superconducting cold, and",
                "it shrugs off open flame. ARC will mint gods.",
            ]),
            TerminalPage(sub: "DEMETER  \u{00B7}  DAY 061  \u{00B7}  ON QUOTA", body: [
                "Two months under, and we have already cleared",
                "target. The refineries never sleep; lately,",
                "neither do I.",
                "",
                "Six colonies in the Strataris cluster and",
                "Demeter ships the most ore of any. Corporate",
                "sends congratulations. No bonus. Just the",
                "word, on repeat: congratulations.",
            ]),
            TerminalPage(sub: "DEMETER  \u{00B7}  DAY 074  \u{00B7}  THE SIGNAL", body: [
                "PROSERPINE woke me at 03:00 over a whisper",
                "beneath the background hiss. I called it noise.",
                "The core will not agree. It finds pattern in it,",
                "order, intent \u{2014} and cannot translate one word.",
                "Still it insists: something out there speaks.",
                "",
                "First contact, they murmur in the mess halls.",
                "God help me, I let myself hope. \u{2014} Director",
            ]),
            TerminalPage(sub: "DEMETER  \u{00B7}  DAY 079  \u{00B7}  THEY CAME", body: [
                "Five days. Five days between that whisper and",
                "the sky tearing open. The marauder fleet burned",
                "our air defence in a single afternoon.",
                "",
                "ARC swears reinforcements are en route. I have",
                "stopped reading the bulletins. We hold with the",
                "guard we landed with \u{2014} and no more are coming.",
                "I am ordering everyone below.",
            ]),
            TerminalPage(sub: "DEMETER  \u{00B7}  DAY 088  \u{00B7}  BELOW", body: [
                "The lifts only travel down now. We sealed the",
                "upper levels behind us and called it strategy,",
                "not burial. It was burial.",
                "",
                "Then the bombing stopped, and something worse",
                "began. They are in the dark with us \u{2014} not the",
                "fleet, but what the fleet was only ever herding",
                "toward us. The signal had a body all along.",
            ]),
            TerminalPage(sub: "DEMETER  \u{00B7}  DAY 093  \u{00B7}  LAST ENTRY", body: [
                "I am the last of command; the guard is spent.",
                "One soldier still breathes in the medbay \u{2014}",
                "months in a coma, skull broken in the first",
                "raid, and waking to nothing they remember.",
                "",
                "Marine, if you read this: the Citadel is yours",
                "now. Retake it, or fall taking it.",
                "\u{2014} Director, Demeter. Signing off.",
            ]),
        ]),
        // ── 2. ARCMAIL — Kirsty Smith to her mum; the human perspective, an arc ──
        TerminalEgg(kind: .email, pages: [
            TerminalPage(sub: "TO: MUM   \u{00B7}   RE: I MADE IT!!", body: [
                "Hi Mum,",
                "",
                "I'm here \u{2014} Demeter, the bottom of the deepest",
                "colony people have ever dug. My badge actually",
                "reads JUNIOR RESEARCH SCIENTIST. Me!",
                "",
                "It's dark, it hums, and I have never been this",
                "happy. This is the frontier, Mum. Love, K x",
            ]),
            TerminalPage(sub: "TO: MUM   \u{00B7}   RE: you won't believe this", body: [
                "Mum \u{2014} I can't say much (so many forms), but the",
                "big machine down here has caught a SIGNAL.",
                "From out there. With patterns in it.",
                "",
                "They think it might be someone. Not us. I came",
                "to test ore and I might get to say hello to a",
                "whole new everyone. Tell Dad his girl was here",
                "for that. x",
            ]),
            TerminalPage(sub: "TO: MUM   \u{00B7}   RE: (no subject)", body: [
                "Mum, it wasn't hello.",
                "",
                "Ships came \u{2014} more than the sky could hold. It",
                "all burned, and then the sky was simply gone.",
                "They keep promising help. No one's face",
                "believes it.",
                "",
                "They're sending us down to the lower levels. K",
            ]),
            TerminalPage(sub: "TO: MUM   \u{00B7}   RE: (no subject)", body: [
                "day ten below, i think. we ration the lamps.",
                "there is something in the tunnels that isn't",
                "the ships. it doesn't make the ships' sound.",
                "it makes the SIGNAL's sound. i would know that",
                "anywhere now.",
                "",
                "the machine was right, mum: we are not alone.",
                "i only wish we were.",
            ]),
            TerminalPage(sub: "TO: MUM   \u{00B7}   RE: (no subject)", body: [
                "if this ever reaches you \u{2014} i wasn't brave, but",
                "i was useful to the last. i logged everything.",
                "someone will need what i wrote down.",
                "",
                "there's a soldier in the medbay who won't wake.",
                "i leave a light on for them. someone should.",
                "",
                "i love you, i love you. \u{2014} Kirsty",
            ]),
        ]),
        // ── 3. ARC memos — the corporate view; escalating, darkly funny ──
        TerminalEgg(kind: .memo, pages: [
            TerminalPage(sub: "REF: ARC/DEM/001  \u{00B7}  PRODUCTION", body: [
                "ALL PERSONNEL \u{2014} ASOLAR RESOURCE CORP",
                "",
                "Demeter has beaten extraction targets by 31%.",
                "Tantalanium is now the single most valuable",
                "substance our species has drawn from rock.",
                "",
                "You are not miners. You are shareholders in the",
                "future \u{2014} minus the shares. Keep digging.",
            ]),
            TerminalPage(sub: "REF: ARC/DEM/044  \u{00B7}  ANOMALY \u{2014} SEALED", body: [
                "The acoustic anomaly logged by PROSERPINE is",
                "reclassified: SURVEY ARTEFACT. Non-biological.",
                "Non-intelligent. Non-existent, preferably.",
                "",
                "Staff overheard discussing \"first contact\" will",
                "be reassigned to morale. Contact is a licensing",
                "matter, and ARC has not filed the paperwork.",
            ]),
            TerminalPage(sub: "REF: ARC/DEM/061  \u{00B7}  SECURITY EVENT", body: [
                "The hostile fleet is a temporary logistics",
                "disruption. Reinforcements are EN ROUTE.",
                "",
                "(That sentence ships in every bulletin since the",
                "disruption began. It is load-bearing. Leave it.)",
                "",
                "Production continues regardless. The ore does not",
                "care who is shooting at whom.",
            ]),
            TerminalPage(sub: "REF: ARC/DEM/077  \u{00B7}  RELOCATION", body: [
                "Withdrawal to the lower levels is a strategic",
                "consolidation, not a rout. The upper colony is",
                "not lost \u{2014} it is \"awaiting recustomer.\"",
                "",
                "The biological presence now sharing those levels",
                "is, per memo 044, non-existent. Kindly do not",
                "feed it, name it, or be eaten by it.",
            ]),
            TerminalPage(sub: "REF: ARC/DEM/093  \u{00B7}  ASSET RECOVERY", body: [
                "PRIORITY RECOVERY, in order:",
                "1. PROSERPINE's core and all signal data.",
                "2. Tantalanium survey maps.",
                "3. \u{2014}",
                "",
                "Personnel are not listed. Personnel are not",
                "recoverable. Personnel were always the cheapest",
                "line on Demeter. \u{2014} Asolar Resource Corp",
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
        // ── 7. The Hitchhiker's Guide to the Galaxy — Deep Thought's answer. ──
        .single(.blankMessage, body: [
            "The answer to the ultimate question of",
            "life, the universe, and everything, is...",
            "",
            "42!",
        ]),
        // ── 8. Highlander (1986) — the Quickening. ──
        .single(.blankMessage, body: [
            "There can be only one",
        ]),
        // ── 9. WarGames (1983) — the WOPR learns the futility of the game. ──
        .single(.blankMessage, body: [
            "The only winning move is not to play",
        ]),
    ]
}
