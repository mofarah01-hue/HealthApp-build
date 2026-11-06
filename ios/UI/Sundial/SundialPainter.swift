import SwiftUI
import MGContext
import MGDesign

// Draws the Sundial's layers into SwiftUI Canvas contexts (UX-SPEC §3.3; prototype dial() L518-570; owner WP-12).
// Three passes so the night arc can turn the page on its own (SundialView); the 0.6 inner rings are animated views
// between `under` and `night` (SundialRings):
//   under — the recessed well, the pale track and elapsed-awake time
//   night — last night's stages, or tonight's plan with the smart-wake window hatched, + their labels
//   over  — naps, workouts, strap-off gaps, caffeine in body, plan ticks, rim marks, hour ticks, labels, hand
// Every layer keeps its own radius AND mark shape AND a direct label (UX §1.2: the colour-blind check failed
// caffeine↔focus and caffeine↔body, so colour is never the only code):
//   caffeine in body  track − 17 · dotted ring of small dots, opacity from the state
//   main track        track     · 13-unit band: stage shades / outlined thin-hatched "asleep, stage unknown" /
//                                 pale plan / dashed nap / ⟋ hatched workout / ✕ cross-hatched strap-off /
//                                 darker elapsed-awake
//   rim events        track + 20 · vape ● (○ unconfirmed) · medication ◆ · caffeine ● with a sip tail ·
//                                 food ▲ · supplement ■
//   plan ticks        across    · cut-off: long tick reaching the caffeine ring · bedtime: short bar (outline once
//                                 missed) · smart-wake window: ⟍ hatched band · wake marker: bar + ring
struct SundialPainter {
    let state: DialState
    let metrics: SundialMetrics
    let colors: ThemeColors
    let calendar: Calendar
    let labels: [SundialLabel]

    private var m: SundialMetrics { metrics }
    private var now: Date { state.now }

    // MARK: Passes

    func drawUnder(_ ctx: inout GraphicsContext) {
        // The recessed well behind the inner rings (0.6): `well` disc, 1 pt `rule` edge. The rings themselves are
        // animated views above this pass (SundialRings).
        let w = m.units(SundialDesign.wellRadius)
        let well = Path(ellipseIn: CGRect(x: m.center.x - w, y: m.center.y - w, width: 2 * w, height: 2 * w))
        ctx.fill(well, with: .color(colors.well.color))
        ctx.stroke(well, with: .color(colors.rule.color), lineWidth: 1)
        // Pale track: a full ring.
        let ring = Path(ellipseIn: CGRect(x: m.center.x - m.trackRadius, y: m.center.y - m.trackRadius,
                                          width: 2 * m.trackRadius, height: 2 * m.trackRadius))
        ctx.stroke(ring, with: .color(colors.trackPale.color), lineWidth: m.units(SundialDesign.trackWidth))
        for arc in state.arcs where arc.kind == .awakeElapsed {
            strokeArc(&ctx, arc.start, arc.end, offset: 0, width: SundialDesign.trackWidth, color: colors.trackDone,
                      opacity: arc.pale ? 0.45 : 1)
        }
    }

    func drawNight(_ ctx: inout GraphicsContext) {
        for arc in state.arcs {
            if arc.kind == .unstaged {
                // Asleep, stage unknown (strap member / epochs without R-R): an outlined band hatched in the
                // light-stage colour, never filled, so it can never be read as light sleep (main, 2026-10-11).
                if let s = sectorPath(arc.start, arc.end, offset: 0, width: SundialDesign.trackWidth) {
                    let fade = arc.pale ? 0.45 : 1
                    hatch(&ctx, s, wash: nil, stripe: colors.stageLight, stripeWidth: 1.2, direction: .up, opacity: fade)
                    ctx.stroke(s, with: .color(colors.stageLight.opacity(fade).color), lineWidth: m.units(1))
                }
                continue
            }
            let color: MGRGBA
            switch arc.kind {
            case .deep: color = colors.stageDeep
            case .light: color = colors.stageLight
            case .rem: color = colors.stageRem
            case .awake: color = colors.stageAwake
            case .plannedSleep: color = colors.sleep
            default: continue
            }
            // Solid = happened, pale = predicted (UX §3.3); tonight's predicted sleep is always pale.
            let pale = arc.pale || arc.kind == .plannedSleep
            strokeArc(&ctx, arc.start, arc.end, offset: 0, width: SundialDesign.trackWidth, color: color,
                      opacity: pale ? 0.45 : 1)
        }
        for tick in state.ticks where tick.kind == .smartWakeWindow {
            if let end = tick.end, end > tick.at, let sector = sectorPath(tick.at, end, offset: 0,
                                                                          width: SundialDesign.trackWidth) {
                hatch(&ctx, sector, wash: colors.sleepWash, stripe: colors.sleep, stripeWidth: 2, direction: .down)
            } else {
                radialLine(&ctx, hour: hour(tick.at), from: -10, to: 10, width: 2.6, color: colors.sleep)
            }
        }
        drawLabels(&ctx, night: true)
    }

    func drawOver(_ ctx: inout GraphicsContext) {
        // Naps, workouts, strap-off gaps on the main track.
        for arc in state.arcs {
            switch arc.kind {
            case .nap:
                strokeArc(&ctx, arc.start, arc.end, offset: 0, width: SundialDesign.trackWidth, color: colors.stageLight,
                          opacity: arc.pale ? 0.45 : 1)
            case .napUnconfirmed:
                // Dashed until confirmed; the "nap?" label carries the question mark.
                strokeArc(&ctx, arc.start, arc.end, offset: 0, width: SundialDesign.trackWidth, color: colors.stageLight,
                          opacity: arc.pale ? 0.45 : 1, dash: [5, 3])
            case .workout:
                if let s = sectorPath(arc.start, arc.end, offset: 0, width: SundialDesign.trackWidth) {
                    hatch(&ctx, s, wash: colors.bodyWash, stripe: colors.body, stripeWidth: 2.4, direction: .up,
                          opacity: arc.pale ? 0.45 : 1)
                }
            case .strapOff:
                if let s = sectorPath(arc.start, arc.end, offset: 0, width: SundialDesign.trackWidth) {
                    // 0.6: the same cross-hatch, quieter (stripe at 35 %).
                    hatch(&ctx, s, wash: colors.muteWash, stripe: colors.mute.opacity(0.35), stripeWidth: 1.1,
                          direction: .cross)
                }
            default:
                break
            }
        }

        // Caffeine in body: a dotted ring, each dot at the state's opacity; predicted dots paler.
        for p in state.caffeineCurve where p.opacity > 0.01 {
            let c = m.point(hour: hour(p.at), offset: SundialDesign.caffeineOffset)
            let r = m.units(1.7)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(colors.caffeine.opacity(min(1, p.opacity) * (p.at > now ? 0.45 : 1)).color))
        }

        // Plan ticks across the track.
        for tick in state.ticks {
            let h = hour(tick.at)
            switch tick.kind {
            case .caffeineCutoff:
                radialLine(&ctx, hour: h, from: SundialDesign.cutoffInner, to: SundialDesign.cutoffOuter, width: 2.4,
                           color: colors.caffeine)
            case .bedtime:
                if tick.hollow {
                    hollowRadialBar(&ctx, hour: h, from: -SundialDesign.bedtimeHalf, to: SundialDesign.bedtimeHalf,
                                    width: 4.8, wall: 1.3, color: colors.sleep)
                } else {
                    radialLine(&ctx, hour: h, from: -SundialDesign.bedtimeHalf, to: SundialDesign.bedtimeHalf,
                               width: 2.6, color: colors.sleep)
                }
            case .wakeMarker:
                radialLine(&ctx, hour: h, from: -SundialDesign.bedtimeHalf, to: 12, width: 2, color: colors.sleep)
                let c = m.point(hour: h, offset: 16)
                let r = m.units(3)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(colors.sleep.color), lineWidth: m.units(1.3))
            case .smartWakeWindow:
                break   // night pass
            }
        }

        drawRim(&ctx)
        drawHourRing(&ctx)
        drawLabels(&ctx, night: false)
        drawHand(&ctx)
    }

    // MARK: Rim marks (UX §3.3 "Rim events")

    private func drawRim(_ ctx: inout GraphicsContext) {
        // Sip tails first so every head sits on top.
        for e in state.rimEvents where e.kind == .caffeine {
            // A drink always shows a tail (≥ 8 min), so its mark is never a bare dot like a vape hit.
            let end = max(e.end ?? e.at, e.at.addingTimeInterval(8 * 60))
            strokeArc(&ctx, e.at, end, offset: SundialDesign.rimOffset, width: 2.6, color: colors.caffeine,
                      opacity: e.at > now ? 0.45 : 1, cap: .round)
        }
        for e in state.rimEvents {
            let c = m.point(hour: hour(e.at), offset: SundialDesign.rimOffset)
            let fade = e.at > now ? 0.45 : 1
            switch e.kind {
            case .vape:
                if e.hollow {
                    let r = m.units(2.6)
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(colors.body.opacity(fade).color), lineWidth: m.units(1.3))
                } else {
                    let r = m.units(2.7)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(colors.body.opacity(fade).color))
                }
            case .medication:
                let d = m.units(4.7)
                var p = Path()
                p.move(to: CGPoint(x: c.x, y: c.y - d))
                p.addLine(to: CGPoint(x: c.x + d, y: c.y))
                p.addLine(to: CGPoint(x: c.x, y: c.y + d))
                p.addLine(to: CGPoint(x: c.x - d, y: c.y))
                p.closeSubpath()
                ctx.fill(p, with: .color(colors.ink.opacity(fade).color))
            case .caffeine:
                let r = m.units(3.3)
                let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(dot, with: .color(colors.caffeine.opacity(fade).color))
                ctx.stroke(dot, with: .color(backdrop.color), lineWidth: m.units(1))
            case .food:
                var p = Path()
                p.move(to: CGPoint(x: c.x, y: c.y - m.units(3.6)))
                p.addLine(to: CGPoint(x: c.x + m.units(3.4), y: c.y + m.units(2.4)))
                p.addLine(to: CGPoint(x: c.x - m.units(3.4), y: c.y + m.units(2.4)))
                p.closeSubpath()
                ctx.fill(p, with: .color(colors.ink2.opacity(fade).color))
            case .supplement:
                let s = m.units(5)
                ctx.fill(Path(CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)),
                         with: .color(colors.focus.opacity(fade).color))
            }
        }
    }

    // MARK: Hour ticks, labels, hand

    private func drawHourRing(_ ctx: inout GraphicsContext) {
        for h in 0..<24 {
            let big = h % 6 == 0
            radialLine(&ctx, hour: Double(h), from: SundialDesign.hourTickInner,
                       to: big ? SundialDesign.hourTickOuterBig : SundialDesign.hourTickOuterSmall,
                       width: big ? 1.3 : 0.8, color: colors.mute.opacity(big ? 1 : 0.55), cap: .butt)
        }
        // The four position labels stay 24-hour (Mo's 0.5.3 face); every time Mo reads elsewhere is 12-hour.
        let size = m.units(MGTextStyle.dialHour.size)
        for (text, h) in [("12", 12.0), ("18", 18.0), ("00", 0.0), ("06", 6.0)] {
            let p = m.point(hour: h, offset: SundialDesign.hourLabelOffset)
            ctx.draw(Text(text).font(MGTextStyle.dialHour.font(size: size))
                        .tracking(MGTextStyle.dialHour.trackingEm * size)
                        .foregroundColor(colors.mute.color), at: p, anchor: .center)
        }
    }

    private func drawLabels(_ ctx: inout GraphicsContext, night: Bool) {
        for l in labels where l.night == night {
            ctx.draw(Text(l.text).font(.system(size: m.units(8), weight: .medium, design: .monospaced))
                        .foregroundColor(colors.text(l.tone).color), at: l.center, anchor: .center)
        }
    }

    /// The scrub position (hour of day) while a finger or VoiceOver is on the dial: a dashed ghost hand. Drawn by the
    /// live overlay on its own, so a finger move never redraws the static layers (audit #14).
    func drawGhost(_ ctx: inout GraphicsContext, hour s: Double) {
        radialLine(&ctx, hour: s, from: SundialDesign.handInner, to: SundialDesign.handOuter, width: 1.5,
                   color: colors.ink2, dash: [3, 3])
        let c = m.point(hour: s, offset: SundialDesign.handOuter)
        let r = m.units(3.2)
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                   with: .color(colors.ink2.color), lineWidth: m.units(1.4))
    }

    private func drawHand(_ ctx: inout GraphicsContext) {
        // UX §3.3: ink 2 pt line from the well edge (0.6; was the hub edge) past the rim, a dot on the rim = now.
        // Moves once a minute (the state's `now`), never animated (UX §1.4).
        let h = hour(now)
        radialLine(&ctx, hour: h, from: SundialDesign.handInner, to: SundialDesign.handOuter, width: 2, color: colors.ink)
        let c = m.point(hour: h, offset: SundialDesign.handOuter)
        let r = m.units(4.2)
        let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(dot, with: .color(colors.ink.color))
        ctx.stroke(dot, with: .color(backdrop.color), lineWidth: m.units(1.6))
    }

    // MARK: Primitives

    private func hour(_ date: Date) -> Double { SundialGeometry.hourOfDay(date, calendar: calendar) }

    /// What sits behind the dial (for the thin halo around the hand dot and drink heads).
    private var backdrop: MGRGBA {
        switch colors.background {
        case .solid(let c): return c
        case .radial(let stops, _, _, _, _): return stops.count > 2 ? stops[2].color : colors.background.lastColor
        }
    }

    private func arcPath(_ start: Date, _ end: Date, offset: CGFloat) -> Path? {
        let sweep = SundialGeometry.sweepHours(from: start, to: end, calendar: calendar)
        let pts = SundialGeometry.arcPoints(startHour: hour(start), sweep: sweep, radius: m.radius(offset),
                                            center: m.center)
        guard pts.count >= 2 else { return nil }
        var p = Path()
        p.addLines(pts)
        return p
    }

    /// The annular sector of a band `width` design units wide around ring `offset`.
    private func sectorPath(_ start: Date, _ end: Date, offset: CGFloat, width: CGFloat) -> Path? {
        let sweep = SundialGeometry.sweepHours(from: start, to: end, calendar: calendar)
        let h0 = hour(start)
        let outer = SundialGeometry.arcPoints(startHour: h0, sweep: sweep, radius: m.radius(offset + width / 2),
                                              center: m.center)
        let inner = SundialGeometry.arcPoints(startHour: h0, sweep: sweep, radius: m.radius(offset - width / 2),
                                              center: m.center)
        guard outer.count >= 2 else { return nil }
        var p = Path()
        p.addLines(outer + inner.reversed())
        p.closeSubpath()
        return p
    }

    private func strokeArc(_ ctx: inout GraphicsContext, _ start: Date, _ end: Date, offset: CGFloat, width: CGFloat,
                           color: MGRGBA, opacity: Double = 1, cap: CGLineCap = .butt, dash: [CGFloat] = []) {
        guard let p = arcPath(start, end, offset: offset) else { return }
        ctx.stroke(p, with: .color(color.opacity(opacity).color),
                   style: StrokeStyle(lineWidth: m.units(width), lineCap: cap, lineJoin: .round,
                                      dash: dash.map { m.units($0) }))
    }

    private func radialLine(_ ctx: inout GraphicsContext, hour h: Double, from a: CGFloat, to b: CGFloat, width: CGFloat,
                            color: MGRGBA, cap: CGLineCap = .round, dash: [CGFloat] = []) {
        var p = Path()
        p.move(to: m.point(hour: h, offset: a))
        p.addLine(to: m.point(hour: h, offset: b))
        ctx.stroke(p, with: .color(color.color),
                   style: StrokeStyle(lineWidth: m.units(width), lineCap: cap, dash: dash.map { m.units($0) }))
    }

    /// A radial bar drawn as an outline only ("hollow once missed"): stroke wide, then clear the middle inside a layer
    /// so whatever is underneath (the track) shows through.
    private func hollowRadialBar(_ ctx: inout GraphicsContext, hour h: Double, from a: CGFloat, to b: CGFloat,
                                 width: CGFloat, wall: CGFloat, color: MGRGBA) {
        var p = Path()
        p.move(to: m.point(hour: h, offset: a))
        p.addLine(to: m.point(hour: h, offset: b))
        ctx.drawLayer { layer in
            layer.stroke(p, with: .color(color.color), style: StrokeStyle(lineWidth: m.units(width), lineCap: .round))
            layer.blendMode = .clear
            layer.stroke(p, with: .color(.black),
                         style: StrokeStyle(lineWidth: m.units(width - 2 * wall), lineCap: .round))
        }
    }

    enum HatchDirection { case up, down, cross }

    /// Fill a sector with a wash (none when nil), then diagonal stripes clipped to it (prototype SVG patterns hB / hO /
    /// hS, 5-unit pitch).
    private func hatch(_ ctx: inout GraphicsContext, _ sector: Path, wash: MGRGBA?, stripe: MGRGBA, stripeWidth: CGFloat,
                       direction: HatchDirection, opacity: Double = 1) {
        if let wash { ctx.fill(sector, with: .color(wash.opacity(opacity).color)) }
        let b = sector.boundingRect
        let pitch = m.units(5)
        let style = StrokeStyle(lineWidth: m.units(stripeWidth), lineCap: .butt)
        ctx.drawLayer { layer in
            layer.clip(to: sector)
            var lines = Path()
            var x = b.minX - b.height
            while x <= b.maxX + b.height {
                if direction == .up || direction == .cross {
                    lines.move(to: CGPoint(x: x, y: b.maxY))
                    lines.addLine(to: CGPoint(x: x + b.height, y: b.minY))
                }
                if direction == .down || direction == .cross {
                    lines.move(to: CGPoint(x: x, y: b.minY))
                    lines.addLine(to: CGPoint(x: x + b.height, y: b.maxY))
                }
                x += pitch
            }
            layer.stroke(lines, with: .color(stripe.opacity(opacity).color), style: style)
        }
    }
}
