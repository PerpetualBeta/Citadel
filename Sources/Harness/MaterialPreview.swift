// Citadel — material swatch sheet (design preview).
//
// Behind CITADEL_MATERIALS: renders every procedural wall + flat texture as a
// labelled 256px swatch to ~/Desktop/Citadel-Materials/ so the industrial /
// underground material set can be judged in isolation before it's seen in the
// raycast world. Mockup-first, the same loop we used for the creatures.

import Cocoa

enum MaterialPreview {
    static func run() {
        // build both sets so each material shows raw (before) vs embossed (after)
        let raw = Textures(relief: false)
        let rel = Textures(relief: true)
        let tile = rel.size                       // 256
        let gap = 10                              // between the before|after pair
        let pairW = tile * 2 + gap
        let pad = 22, labelH = 26, cols = 2, headerH = 46
        let rowH = tile + labelH + pad
        let walls = WallTex.allCases, flats = FlatTex.allCases
        let wallRows = (walls.count + cols - 1) / cols
        let flatRows = (flats.count + cols - 1) / cols
        let sheetW = cols * pairW + (cols + 1) * pad
        let sheetH = pad + headerH + wallRows * rowH + headerH + flatRows * rowH + pad

        let c = Canvas2D(width: sheetW, height: sheetH)
        for i in 0..<(sheetW * sheetH) { c.framebuffer[i] = packRGBA(20, 22, 28) }

        func blit(_ pixels: [UInt32], _ ox: Int, _ oy: Int) {
            for ty in 0..<tile { for tx in 0..<tile { c.plot(ox + tx, oy + ty, pixels[ty * tile + tx]) } }
            c.strokeRect(ox - 1, oy - 1, tile + 2, tile + 2, packRGBA(64, 68, 80))
        }
        func drawPair(_ before: [UInt32], _ after: [UInt32], _ name: String, _ ox: Int, _ oy: Int) {
            c.label(name, ox, oy, size: 17, color: packRGBA(212, 216, 226), weight: .semibold)
            c.label("before", ox + tile - 44, oy, size: 13, color: packRGBA(150, 154, 168), weight: .medium)
            c.label("relief", ox + pairW - 40, oy, size: 13, color: packRGBA(150, 220, 160), weight: .bold)
            blit(before, ox, oy + labelH)
            blit(after, ox + tile + gap, oy + labelH)
        }

        var y = pad
        c.label("WALLS — directional relief baked from luminance (before → after)", pad, y, size: 22, color: packRGBA(120, 170, 240), weight: .bold)
        y += headerH
        let wallsBaseY = y
        for (i, w) in walls.enumerated() {
            let ox = pad + (i % cols) * (pairW + pad), oy = wallsBaseY + (i / cols) * rowH
            drawPair(raw.wall(w.rawValue).pixels, rel.wall(w.rawValue).pixels, nameW(w), ox, oy)
        }
        y = wallsBaseY + wallRows * rowH
        c.label("FLATS — floors & ceilings (before → after)", pad, y, size: 22, color: packRGBA(120, 170, 240), weight: .bold)
        y += headerH
        let flatsBaseY = y
        for (i, f) in flats.enumerated() {
            let ox = pad + (i % cols) * (pairW + pad), oy = flatsBaseY + (i / cols) * rowH
            drawPair(raw.flat(f.rawValue).pixels, rel.flat(f.rawValue).pixels, nameF(f), ox, oy)
        }

        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Citadel-Materials")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Captures.writePNG(c.framebuffer, w: sheetW, h: sheetH, scale: 1, to: dir.appendingPathComponent("00-materials.png"))

        // focused, legible before/after for the materials where relief matters most
        let heroes: [(String, [UInt32], [UInt32])] = [
            ("stone", raw.wall(WallTex.stone.rawValue).pixels, rel.wall(WallTex.stone.rawValue).pixels),
            ("ironPlate", raw.wall(WallTex.ironPlate.rawValue).pixels, rel.wall(WallTex.ironPlate.rawValue).pixels),
            ("ribbedSteel", raw.wall(WallTex.ribbedSteel.rawValue).pixels, rel.wall(WallTex.ribbedSteel.rawValue).pixels),
            ("stoneSteel", raw.wall(WallTex.stoneSteel.rawValue).pixels, rel.wall(WallTex.stoneSteel.rawValue).pixels),
            ("rock (floor)", raw.flat(FlatTex.rock.rawValue).pixels, rel.flat(FlatTex.rock.rawValue).pixels),
            ("metalFloor", raw.flat(FlatTex.metalFloor.rawValue).pixels, rel.flat(FlatTex.metalFloor.rawValue).pixels),
        ]
        let hcols = 2, hrows = (heroes.count + hcols - 1) / hcols
        let hW = hcols * pairW + (hcols + 1) * pad
        let hH = pad + headerH + hrows * rowH + pad
        let hc = Canvas2D(width: hW, height: hH)
        for i in 0..<(hW * hH) { hc.framebuffer[i] = packRGBA(20, 22, 28) }
        hc.label("RELIEF — hero materials (before → after)", pad, pad, size: 22, color: packRGBA(120, 170, 240), weight: .bold)
        for (i, h) in heroes.enumerated() {
            let ox = pad + (i % hcols) * (pairW + pad), oy = pad + headerH + (i / hcols) * rowH
            hc.label(h.0, ox, oy, size: 17, color: packRGBA(212, 216, 226), weight: .semibold)
            hc.label("before", ox + tile - 44, oy, size: 13, color: packRGBA(150, 154, 168), weight: .medium)
            hc.label("relief", ox + pairW - 40, oy, size: 13, color: packRGBA(150, 220, 160), weight: .bold)
            for ty in 0..<tile { for tx in 0..<tile {
                hc.plot(ox + tx, oy + labelH + ty, h.1[ty * tile + tx])
                hc.plot(ox + tile + gap + tx, oy + labelH + ty, h.2[ty * tile + tx])
            }}
            hc.strokeRect(ox - 1, oy + labelH - 1, tile + 2, tile + 2, packRGBA(64, 68, 80))
            hc.strokeRect(ox + tile + gap - 1, oy + labelH - 1, tile + 2, tile + 2, packRGBA(64, 68, 80))
        }
        Captures.writePNG(hc.framebuffer, w: hW, h: hH, scale: 1, to: dir.appendingPathComponent("01-relief-hero.png"))
        FileHandle.standardError.write("Materials → \(dir.path)\n".data(using: .utf8)!)
    }

    private static func nameW(_ w: WallTex) -> String {
        switch w {
        case .none: return "none (solid fill)"
        case .ironPlate: return "ironPlate"
        case .brushedSteel: return "brushedSteel"
        case .steelPanel: return "steelPanel"
        case .litPanel: return "litPanel"
        case .ribbedSteel: return "ribbedSteel"
        case .pipework: return "pipework"
        case .glass: return "glass"
        case .stone: return "stone"
        case .stoneSteel: return "stoneSteel"
        case .computer: return "computer"
        case .hazard: return "hazard"
        case .doorPanel: return "doorPanel"
        case .doorRed: return "doorRed"
        case .doorBlue: return "doorBlue"
        case .doorYellow: return "doorYellow"
        case .exitSwitch: return "exitSwitch"
        case .doorHazard: return "doorHazard"
        case .elevatorSealed: return "elevatorSealed"
        case .liftWall: return "liftWall"
        case .concrete: return "concrete"
        case .opsBoard: return "opsBoard"
        case .medWall: return "medWall"
        }
    }
    private static func nameF(_ f: FlatTex) -> String {
        switch f {
        case .concrete: return "concrete"
        case .metalFloor: return "metalFloor"
        case .grate: return "grate"
        case .nukage: return "nukage"
        case .ceilTech: return "ceilTech"
        case .ceilDark: return "ceilDark"
        case .ceilStone: return "ceilStone"
        case .rock: return "rock"
        case .blood: return "blood"
        case .teleportPad: return "teleportPad"
        case .ceilWhite: return "ceilWhite"
        }
    }
}
