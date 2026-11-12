import AppKit
import IslandCore
import SwiftUI

// MARK: - Tokens

/// One type scale (system text styles where macOS has the size): Title 17/600, Body 15,
/// Secondary 13, Caption 11/600, hero numerals 32/600 tabular, ears 13/600 like the menu bar.
enum IslandType {
    static let title = Font.title2.weight(.semibold)
    static let body = Font.title3
    static let secondary = Font.body
    static let caption = Font.subheadline.weight(.semibold)
    static let numeral = Font.system(size: 32, weight: .semibold).monospacedDigit()
    static let ear = Font.body.weight(.semibold)
}

extension View {
    /// A hero numeral's box is its point size, like the sim's `line-height: 1`.
    func numeralBox() -> some View { padding(.vertical, -3) }
}

enum IslandColor {
    static let green = Color(hex: "#30D158")
    static let orange = Color(hex: "#FF9F0A")
    static let red = Color(hex: "#FF453A")
    static let blue = Color(hex: "#0A84FF")
    static let indigo = Color(hex: "#7D7AFF")
    static let cyan = Color(hex: "#64D2FF")
    static let secondary = Color.white.opacity(0.55)
    static let dim = Color.white.opacity(0.5)
}

// MARK: - Layers

/// The activity's closed view: a slot in each ear, from the ear's end to the notch.
struct ActivityEarsLayer: View {
    let frame: FrameModel
    let director: IslandDirector
    // (No buttons in the ears: they never take a press from the island underneath.)

    var body: some View {
        let cx = FrameModel.cx, nhw = frame.notchHalfWidth, nh = frame.notchHeight, e = frame.earScale
        let leftX = frame.left + 12, rightX = cx + nhw + 8
        let leftW = max(cx - nhw - 8 - leftX, 0), rightW = max(frame.right - 12 - rightX, 0)
        ZStack(alignment: .topLeading) {
            if let a = director.shownActivity {
                // Laid out at the design size, then scaled to the notch (`EarMetrics`; 1 in a real notch).
                ActivityEars(instance: a, side: .left, director: director)
                    .frame(width: leftW / e, height: nh / e, alignment: .leading)
                    .scaleEffect(e, anchor: .topLeading)
                    .frame(width: leftW, height: nh, alignment: .topLeading)
                    .clipped()
                    .offset(x: leftX)
                    .id("l\(a.serial)")
                ActivityEars(instance: a, side: .right, director: director)
                    .frame(width: rightW / e, height: nh / e, alignment: .trailing)
                    .scaleEffect(e, anchor: .topLeading)
                    .frame(width: rightW, height: nh, alignment: .topLeading)
                    .clipped()
                    .offset(x: rightX)
                    .id("r\(a.serial)")
            }
        }
        .frame(width: NotchContentView.size.width, height: NotchContentView.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// The activity's open card, laid out at its final size.
struct ActivityCardLayer: View {
    let frame: FrameModel
    let director: IslandDirector
    let card: CardSize

    var body: some View {
        if let a = director.cardShown {
            let size = a.spec.card
            CardPlacement(frame: frame, card: size) {
                ActivityCard(instance: a, director: director)
                    .padding(.horizontal, a.id == .incoming ? 20 : 18)
                    .padding(.vertical, a.spec.padding)
                    .frame(width: size.width, height: size.height)
                    .foregroundStyle(.white)
                    .id(a.serial)
            }
        }
    }
}

// MARK: - Ears

enum EarSide { case left, right }

struct ActivityEars: View {
    let instance: ActivityInstance
    let side: EarSide
    let director: IslandDirector
    @Environment(\.presenting) private var presenting

    var body: some View {
        let _ = director.now
        let s = director.samples
        HStack(spacing: 7) {
            switch (instance.id, side) {
            case (.incoming, .left):
                Caller(size: 24).entrance(side, 0)
                Text(presenting ? "Call" : "Marina").font(IslandType.ear).entrance(side, 1)
            case (.incoming, .right):
                Text("mobile").font(.body.weight(.medium)).foregroundStyle(IslandColor.secondary).entrance(side, 0)
                Ringing { Image(systemName: "phone.fill").font(.system(size: 15)).foregroundStyle(IslandColor.green) }
                    .entrance(side, 1)
            case (.call, .left):
                Image(systemName: "phone.fill").font(.system(size: 15)).foregroundStyle(IslandColor.green).entrance(side, 0)
                Text(clockText(s.callSeconds)).font(IslandType.ear.monospacedDigit()).foregroundStyle(IslandColor.green)
                    .entrance(side, 1)
            case (.call, .right):
                Waveform(count: 13, color: IslandColor.green, barWidth: 1.8, height: 18).entrance(side, 0)
            case (.airpods, .left):
                BudsImage(height: 22).frame(width: 34, height: 30).entrance(side, 0)
            case (.airpods, .right):
                let buds = director.podsFor(instance).buds
                Ring(progress: Double(buds ?? 0) / 100, color: (buds ?? 100) <= 20 ? IslandColor.red : IslandColor.green,
                     size: 24, stroke: 4, fillsIn: true).entrance(side, 0)
            case (.focus, .left):
                FocusPill(on: director.focusOnFor(instance), grows: true)
            case (.focus, .right):
                let on = director.focusOnFor(instance)
                Text(on ? director.focusModeFor(instance)?.name ?? "Focus" : "Focus off").font(IslandType.ear).lineLimit(1)
                    .foregroundStyle(on ? IslandColor.indigo : IslandColor.secondary).entrance(side, 0)
            case (.battery, .left):
                Text("Low Battery").font(IslandType.ear).entrance(side, 0)
            case (.battery, .right):
                let p = director.lowPowerFor(instance)
                Text("\(p.level)%").font(IslandType.ear.monospacedDigit()).foregroundStyle(IslandColor.red).entrance(side, 0)
                Battery(level: Double(p.level) / 100, width: 30, height: 14, low: true).entrance(side, 1)
            case (.camera, .left):
                Image(systemName: "video.fill").font(.system(size: 14)).foregroundStyle(IslandColor.green).entrance(side, 0)
            case (.camera, .right):
                Text(clockText(director.cameraFor(instance).seconds)).font(IslandType.ear.monospacedDigit())
                    .foregroundStyle(IslandColor.green).entrance(side, 0)
            case (.charging, .left):
                let p = director.powerFor(instance)
                Image(systemName: "bolt.fill").font(.system(size: 13)).foregroundStyle(IslandColor.green).zap()
                Text(p.charging ? "Charging" : "Plugged in").font(IslandType.ear).entrance(side, 1)
            case (.charging, .right):
                let p = director.powerFor(instance)
                CountUp(to: Double(p.level), suffix: "%").font(IslandType.ear.monospacedDigit()).foregroundStyle(IslandColor.green)
                    .entrance(side, 0)
                Battery(level: Double(p.level) / 100, width: 30, height: 14).entrance(side, 1)
            case (.timer, .left):
                TimerRing(left: s.timerLeft, total: s.timerTotal).entrance(side, 0)
            case (.timer, .right):
                TimerText(left: s.timerLeft, font: IslandType.ear.monospacedDigit()).entrance(side, 0)
            case (.recording, .left):
                RecordDot().entrance(side, 0)
                Text("REC").font(IslandType.caption).tracking(0.44).foregroundStyle(IslandColor.red).entrance(side, 1)
            case (.recording, .right):
                Text(clockText(s.recordSeconds)).font(IslandType.ear.monospacedDigit()).entrance(side, 0)
            case (.meeting, .left):
                CalendarTile(size: 22).entrance(side, 0)
            case (.meeting, .right):
                let left = director.meetingLeft(instance)
                Text(meetingText(left)).font(IslandType.ear.monospacedDigit())
                    .foregroundStyle(left <= 60 ? IslandColor.orange : .white).entrance(side, 0)
            case (.download, .left):
                DownloadRing(progress: director.transferFor(instance).fraction).entrance(side, 0)
            case (.download, .right):
                let t = director.transferFor(instance)
                Text(t.finished ? "Done" : "\(Int(t.fraction * 100))%").font(IslandType.ear.monospacedDigit())
                    .entrance(side, 0)
            case (.messages, .left):
                MessagesIcon(size: 22).entrance(side, 0)
            case (.messages, .right):
                Text(presenting ? "Message" : "Marina").font(IslandType.ear).entrance(side, 0)
                Avatar(initials: "MC", colors: ("#FF9F6B", "#E0567A"), size: 22).entrance(side, 1)
            case (.recordCountdown, .left):
                RecordDot().entrance(side, 0)
                Text("Recording").font(IslandType.ear).entrance(side, 1)
            case (.recordCountdown, .right):
                Text("\(director.recordCountdown)").font(IslandType.ear.monospacedDigit()).foregroundStyle(IslandColor.red)
                    .contentTransition(.numericText(countsDown: true)).entrance(side, 0)
            case (.recordingSaved, .left):
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(IslandColor.green)
                    .entrance(side, 0)
                Text("Saved").font(IslandType.ear).entrance(side, 1)
            case (.recordingSaved, .right):
                Text(clockText(director.lastRecording.seconds)).font(IslandType.ear.monospacedDigit())
                    .foregroundStyle(IslandColor.secondary).entrance(side, 0)

            case (.kickoff, _), (.match, _), (.goal, _), (.fulltime, _), (.chess, _), (.agentLimit, _), (.agentBack, _):
                SportsEars(instance: instance, side: side, director: director)
            case (.lockScreen, _), (.unlocked, _):
                LockEars(id: instance.id, side: side, unlocking: director.lockTouched)
            case (.notice, _):
                NoticeEar(notice: director.notice(for: instance), side: side)
            case (.airPane, _):
                AirPaneEar(side: side)
            case (.support, _):
                SupportEar(side: side)
            }
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The bubble's minimal view of an activity: its leading glyph.
struct ActivityGlyph: View {
    let instance: ActivityInstance
    let director: IslandDirector

    var body: some View {
        let _ = director.now
        let s = director.samples
        switch instance.id {
        case .incoming: Caller(size: 22)
        case .call: Image(systemName: "phone.fill").font(.system(size: 13)).foregroundStyle(IslandColor.green)
        case .airpods: BudsImage(height: 16)
        case .focus:
            Image(systemName: "moon.fill").font(.system(size: 12))
                .foregroundStyle(director.focusOnFor(instance) ? IslandColor.indigo : IslandColor.secondary)
        case .battery: Battery(level: Double(director.lowPowerFor(instance).level) / 100, width: 20, height: 10, low: true)
        case .camera: Image(systemName: "video.fill").font(.system(size: 12)).foregroundStyle(IslandColor.green)
        case .charging: Image(systemName: "bolt.fill").font(.system(size: 14)).foregroundStyle(IslandColor.green)
        case .timer: TimerRing(left: s.timerLeft, total: s.timerTotal)
        case .recording: RecordDot()
        case .meeting: CalendarTile(size: 20)
        case .download: DownloadRing(progress: director.transferFor(instance).fraction)
        case .messages: MessagesIcon(size: 20)
        case .recordCountdown: RecordDot()
        case .recordingSaved: Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(IslandColor.green)

        case .kickoff, .match, .goal, .fulltime, .chess, .agentLimit, .agentBack: SportsGlyph(instance: instance, director: director)
        case .lockScreen, .unlocked: Image(systemName: instance.id == .unlocked ? "lock.open.fill" : "lock.fill").font(.system(size: 12, weight: .semibold))
        case .notice: NoticeIcon(app: director.notice(for: instance).app, size: 20)
        case .airPane: Image(systemName: "airpods.gen4").font(.system(size: 12, weight: .semibold))
        case .support: Image(systemName: "cup.and.saucer.fill").font(.system(size: 11, weight: .semibold))
        }
    }
}

private func meetingText(_ left: Double) -> String { left <= 0 ? "now" : "in \(Int((left / 60).rounded(.up))) min" }

// MARK: - Cards

struct ActivityCard: View {
    let instance: ActivityInstance
    let director: IslandDirector
    @Environment(\.presenting) private var presenting

    var body: some View {
        switch instance.id {
        case .incoming: incoming
        case .call: CallCard(director: director)
        case .airpods: airpods
        case .focus: FocusCard(instance: instance, director: director)
        case .battery: lowBattery
        case .camera: CameraCard(instance: instance, director: director)
        case .charging: charging
        case .timer: TimerCard(director: director)
        case .recording: RecordingCard(instance: instance, director: director)
        case .recordCountdown: RecordCountdownCard(director: director)
        case .recordingSaved: RecordingSavedCard(director: director)
        case .meeting: MeetingCard(instance: instance, director: director)
        case .download: DownloadCard(instance: instance, director: director)
        case .messages: MessagesCard(director: director)

        case .kickoff, .match, .goal, .fulltime, .chess, .agentLimit, .agentBack: SportsCard(instance: instance, director: director)
        case .lockScreen, .unlocked: EmptyView()   // ears only
        case .notice: NoticeCard(notice: director.notice(for: instance), director: director)
        case .airPane: AirPaneCard(director: director)
        case .support: SupportCard(director: director)
        }
    }

    private var incoming: some View {
        HStack(spacing: 12) {
            Caller(size: 44).overlay(RingingHalo()).rise(0)
            VStack(alignment: .leading, spacing: 0) {
                Text("mobile").font(IslandType.secondary).foregroundStyle(IslandColor.secondary)
                Text(presenting ? "Incoming call" : "Marina Duarte").font(IslandType.title).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rise(1)
            HStack(spacing: 14) {
                RoundButton(symbol: "phone.down.fill", style: .red, label: "Decline") { director.perform(.decline) }
                RoundButton(symbol: "phone.fill", style: .green, label: "Accept", ringing: true) { director.perform(.accept) }
            }
            .rise(2)
        }
        .frame(maxHeight: .infinity)
    }

    private var airpods: some View {
        let pods = director.podsFor(instance)
        return HStack(spacing: 12) {
            BudsImage(height: 48).drop().frame(width: 104, height: 92).offset(x: -3, y: 3)
            VStack(alignment: .leading, spacing: 0) {
                Text(pods.name).font(IslandType.title).lineLimit(1)
                Text("Connected").font(IslandType.secondary).foregroundStyle(IslandColor.secondary)
                HStack(spacing: 30) {
                    if let buds = pods.buds {
                        PodBattery(level: buds, label: "AirPods", symbol: "airpods.gen4", charging: false)
                    }
                    if let c = pods.caseLevel {
                        PodBattery(level: c, label: "Case", symbol: "airpods.gen4.chargingcase.wireless", charging: false)
                    }
                }
                .padding(.top, 10)
            }
            .fixedSize()
            .rise(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lowBattery: some View {
        let p = director.lowPowerFor(instance)
        return HStack(spacing: 20) {
            Battery(level: Double(p.level) / 100, width: 104, height: 46, big: true, low: true).rise(0)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(p.level)%").font(IslandType.numeral).foregroundStyle(IslandColor.red).numeralBox()
                    .padding(.bottom, 3)
                Text(p.lowStatus).font(IslandType.secondary).foregroundStyle(IslandColor.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Text("Connect to power").font(IslandType.secondary).foregroundStyle(IslandColor.dim).padding(.top, 2)
            }
            .rise(1)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    private var charging: some View {
        let p = director.powerFor(instance)
        return HStack(spacing: 20) {
            Battery(level: Double(p.level) / 100, width: 104, height: 46, big: true).rise(0)
            VStack(alignment: .leading, spacing: 0) {
                CountUp(to: Double(p.level), suffix: "%").font(IslandType.numeral).foregroundStyle(IslandColor.green).numeralBox()
                    .padding(.bottom, 3)
                Text(p.status).font(IslandType.secondary).foregroundStyle(IslandColor.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Text(p.adapter ?? "Power adapter").font(IslandType.secondary).foregroundStyle(IslandColor.dim).padding(.top, 2)
            }
            .rise(1)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }
}

private struct CallCard: View {
    let director: IslandDirector

    var body: some View {
        let _ = director.now
        let s = director.samples
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Avatar(initials: "MD", colors: ("#F6B26B", "#C2457E"), size: 44)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Marina Duarte").font(IslandType.title).lineLimit(1)
                    Text((s.muted ? "Muted · " : "FaceTime Audio · ") + clockText(s.callSeconds))
                        .font(IslandType.secondary.monospacedDigit()).foregroundStyle(IslandColor.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { director.perform(.info) } label: {
                    Image(systemName: "info.circle").font(.system(size: 22)).foregroundStyle(.white.opacity(0.8))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Info")
            }
            .rise(0)
            HStack {
                RoundButton(symbol: "speaker.wave.2.fill", style: s.speaker ? .lit : .gray, label: "Speaker") { director.perform(.speaker) }
                Spacer()
                RoundButton(symbol: s.muted ? "mic.slash.fill" : "mic.fill", style: s.muted ? .lit : .gray, label: "Mute") {
                    director.perform(.mute)
                }
                Spacer()
                RoundButton(symbol: "video.fill", style: .gray, label: "Video") { director.perform(.video) }
                Spacer()
                RoundButton(symbol: "rectangle.inset.filled.and.person.filled", style: .gray, label: "Share screen") {
                    director.perform(.share)
                }
                Spacer()
                RoundButton(symbol: "phone.down.fill", style: .red, label: "End call") { director.perform(.endCall) }
            }
            .rise(1)
        }
        .frame(maxHeight: .infinity)
    }
}

/// Focus, read-only, like iPhone's Silent mode: on or off (which one, with its symbol, when macOS says), and a way to
/// its settings.
private struct FocusCard: View {
    let instance: ActivityInstance
    let director: IslandDirector

    var body: some View {
        let on = director.focusOnFor(instance), mode = on ? director.focusModeFor(instance) : nil
        HStack(spacing: 12) {
            Image(systemName: mode?.symbol ?? "moon.fill").font(.system(size: 20)).foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(on ? IslandColor.indigo : Color.white.opacity(0.15)))
                .rise(0)
            VStack(alignment: .leading, spacing: 0) {
                Text(on ? mode.map { "\($0.name) on" } ?? "Focus on" : "Focus off").font(IslandType.title).lineLimit(1)
                Text(on ? "Notifications are silenced" : "Notifications are back").font(IslandType.secondary)
                    .foregroundStyle(IslandColor.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rise(1)
            RoundButton(symbol: "gearshape.fill", style: .gray, label: "Focus settings") { director.perform(.focusSettings) }
                .rise(2)
        }
        .frame(maxHeight: .infinity)
    }
}

/// The camera is on (filming, a video call, Photo Booth): since when, and for how long.
private struct CameraCard: View {
    let instance: ActivityInstance
    let director: IslandDirector

    var body: some View {
        let cam = director.cameraFor(instance)
        HStack(spacing: 12) {
            Image(systemName: "video.fill").font(.system(size: 18)).foregroundStyle(IslandColor.green)
                .frame(width: 44, height: 44)
                .background(Circle().fill(IslandColor.green.opacity(0.18)))
                .rise(0)
            VStack(alignment: .leading, spacing: 0) {
                Text("Camera on").font(IslandType.title).lineLimit(1)
                Text("Since \(cam.since.formatted(date: .omitted, time: .shortened)) · \(clockText(cam.seconds))")
                    .font(IslandType.secondary.monospacedDigit()).foregroundStyle(IslandColor.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rise(1)
        }
        .frame(maxHeight: .infinity)
    }
}

private struct TimerCard: View {
    let director: IslandDirector

    var body: some View {
        let _ = director.now
        let s = director.samples
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Timer").font(IslandType.secondary).foregroundStyle(IslandColor.orange)
                    TimerText(left: s.timerLeft, font: IslandType.numeral, base: IslandColor.orange).numeralBox()
                }
                Spacer()
                HStack(spacing: 14) {
                    RoundButton(symbol: s.timerPaused ? "play.fill" : "pause.fill", style: .orange,
                                label: s.timerPaused ? "Resume" : "Pause") { director.perform(.pauseTimer) }
                    RoundButton(symbol: "xmark", style: .gray, label: "Cancel") { director.perform(.cancelTimer) }
                }
            }
            .rise(0)
            Bar(progress: s.timerLeft / max(s.timerTotal, 1), color: IslandColor.orange, height: 3).rise(1)
        }
        .frame(maxHeight: .infinity)
    }
}

private struct RecordingCard: View {
    let instance: ActivityInstance
    let director: IslandDirector

    var body: some View {
        let _ = director.now
        let s = director.samples
        let real = !director.isSample(instance)
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "record.circle").font(.system(size: 21)).foregroundStyle(IslandColor.red)
                    .frame(width: 40, height: 40).background(Circle().fill(IslandColor.red.opacity(0.18)))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Recording screen").font(IslandType.title).lineLimit(1)
                    Text(real ? "The whole screen · saving to the Desktop" : "Built-in Retina Display · Microphone on")
                        .font(IslandType.secondary).foregroundStyle(IslandColor.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .rise(0)
            HStack(spacing: 14) {
                Text(clockText(s.recordSeconds)).font(IslandType.numeral).numeralBox().frame(minWidth: 76, alignment: .leading)
                Waveform(count: 16, color: IslandColor.red, barWidth: 2.2, height: 22, live: !s.recordPaused)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 14) {
                    // A real recording can't pause (ScreenCaptureKit writes one file): only the sample can.
                    if !real {
                        RoundButton(symbol: s.recordPaused ? "play.fill" : "pause.fill", style: .gray,
                                    label: s.recordPaused ? "Resume" : "Pause") { director.perform(.pauseRecording) }
                    }
                    RoundButton(symbol: "stop.fill", style: .red, label: "Stop") { director.perform(.stopRecording) }
                }
            }
            .rise(1)
        }
        .frame(maxHeight: .infinity)
    }
}

private struct MeetingCard: View {
    let instance: ActivityInstance
    let director: IslandDirector
    @Environment(\.presenting) private var presenting

    private static let palette: [(String, String)] = [("#FF9F6B", "#E0567A"), ("#7FD1FF", "#2F7BE0"), ("#B6F09C", "#35A869")]

    var body: some View {
        let m = director.meetingFor(instance)
        let left = director.meetingLeft(instance)
        let time = "\(m.start.formatted(date: .omitted, time: .shortened)) – \(m.end.formatted(date: .omitted, time: .shortened))"
        let canJoin = director.isSample(instance) || m.joinURL != nil
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                CalendarTile(size: 40)
                VStack(alignment: .leading, spacing: 0) {
                    // The title is private while presenting.
                    Text(presenting ? "Event" : m.title).font(IslandType.title).lineLimit(1)
                    Text(time + " · " + (left <= 0 ? "now" : meetingText(left)))
                        .font(IslandType.secondary.monospacedDigit()).foregroundStyle(IslandColor.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .rise(0)
            HStack {
                if m.initials.isEmpty {
                    // An event without people (a class, lunch): its calendar, and what else is on now.
                    let others = m.alsoNow > 0 ? "+\(m.alsoNow) more now" : ""
                    let line = [m.calendar, others].filter { !$0.isEmpty }.joined(separator: " · ")
                    Text(line.isEmpty ? (canJoin ? "" : "No call link") : line)
                        .font(IslandType.secondary).foregroundStyle(IslandColor.secondary).lineLimit(1)
                } else {
                    HStack(spacing: -2) {
                        ForEach(Array(m.initials.enumerated()), id: \.offset) { i, initials in
                            Avatar(initials: initials, colors: Self.palette[i % Self.palette.count], size: 28, ring: true)
                        }
                        if m.more > 0 {
                            Text("+\(m.more)").font(IslandType.secondary).foregroundStyle(IslandColor.secondary).padding(.leading, 10)
                        }
                    }
                }
                Spacer()
                if canJoin {
                    Button { director.perform(.join) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "video.fill").font(.system(size: 14))
                            Text("Join").font(IslandType.body.weight(.semibold))
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(Capsule().fill(IslandColor.green))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressScaleStyle(pressed: 0.94, hover: 1.04))
                    .accessibilityLabel("Join")
                }
            }
            .frame(height: 32)
            .rise(1)
        }
        .frame(maxHeight: .infinity)
    }
}

private struct DownloadCard: View {
    let instance: ActivityInstance
    let director: IslandDirector

    var body: some View {
        let _ = director.now
        let t = director.transferFor(instance)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottom) {
                    Image(systemName: "doc.fill").font(.system(size: 36)).foregroundStyle(Color(hex: "#8FB8FF"))
                    Text(t.kind).font(.system(size: 7.5, weight: .heavy)).tracking(0.3).foregroundStyle(Color(hex: "#0B2A55"))
                        .padding(.bottom, 7)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 0) {
                    Text(t.name).font(IslandType.title).lineLimit(1).truncationMode(.middle)
                    Text(t.progressLine).font(IslandType.secondary.monospacedDigit()).foregroundStyle(IslandColor.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .rise(0)
            Bar(progress: t.fraction, color: t.finished ? IslandColor.green : IslandColor.cyan, height: 5)
                .padding(.top, 10)
                .rise(1)
            HStack {
                Text(t.timeLeft).font(IslandType.secondary).foregroundStyle(IslandColor.secondary)
                Spacer()
                HStack(spacing: 14) {
                    if !t.finished {
                        RoundButton(symbol: t.paused ? "play.fill" : "pause.fill", style: .gray, size: 36,
                                    label: t.paused ? "Resume" : "Pause") { director.perform(.pauseDownload) }
                    }
                    RoundButton(symbol: "folder.fill", style: .gray, size: 36, label: "Show in Finder") {
                        director.perform(.showInFinder)
                    }
                }
            }
            .padding(.top, 8)
            .rise(2)
        }
        .frame(maxHeight: .infinity)
    }
}

/// A notification like iOS's communication ones, with the reply in place (the owner's reference):
/// dismiss on the left, a field with the send button inside.
private struct MessagesCard: View {
    let director: IslandDirector
    @State private var reply = ""
    @FocusState private var focused: Bool
    @Environment(\.presenting) private var presenting
    @Environment(\.islandMotion) private var motion

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Avatar(initials: "MC", colors: ("#FF9F6B", "#E0567A"), size: 40)
                    .overlay(alignment: .bottomTrailing) {
                        MessagesIcon(size: 16)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(.black, lineWidth: 4))
                            .offset(x: 4, y: 4)
                    }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(presenting ? "Message" : "Marina Costa").font(IslandType.title).lineLimit(1)
                        Spacer()
                        Text("now").font(IslandType.secondary).foregroundStyle(IslandColor.dim)
                    }
                    // Never show message text while presenting.
                    Text(presenting ? "Message hidden while presenting"
                                    : "Still on for dinner tonight? I booked the place on the corner for 8:30 🍝")
                        .font(IslandType.body).foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2).lineSpacing(1.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .rise(0)
            HStack(spacing: 10) {
                RoundButton(symbol: "xmark", style: .gray, size: 32, label: "Mark as read") { director.perform(.markRead) }
                HStack(spacing: 0) {
                    if motion.stills {
                        Text("Reply").font(IslandType.body).foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("Reply", text: $reply)
                            .textFieldStyle(.plain)
                            .font(IslandType.body)
                            .focused($focused)
                            .onSubmit(send)
                            .accessibilityLabel(presenting ? "Reply" : "Reply to Marina Costa")
                    }
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(IslandColor.blue))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressScaleStyle(pressed: 0.85, hover: 1.06))
                    .accessibilityLabel("Send")
                }
                .padding(.leading, 14)
                .padding(.trailing, 3)
                .frame(height: 32)
                .background(Capsule().fill(.white.opacity(0.1)))
                .overlay(Capsule().strokeBorder(.white.opacity(focused ? 0.35 : 0.12), lineWidth: focused ? 1 : 0.5))
            }
            .rise(1)
        }
        .frame(maxHeight: .infinity)
        .onChange(of: focused) { _, f in director.replyFocused = f }
    }

    private func send() {
        guard !reply.trimmingCharacters(in: .whitespaces).isEmpty else { focused = true; return }
        director.perform(.send(reply))
        reply = ""
    }
}

// MARK: - Pieces

/// The caller's photo, or a plain phone while presenting (names and photos stay private).
private struct Caller: View {
    let size: Double
    @Environment(\.presenting) private var presenting

    var body: some View {
        if presenting {
            Image(systemName: "phone.fill").font(.system(size: size * 0.42)).foregroundStyle(.white)
                .frame(width: size, height: size).background(Circle().fill(Color(hex: "#3A3A3C")))
        } else {
            Avatar(initials: "MD", colors: ("#F6B26B", "#C2457E"), size: size)
        }
    }
}

/// A contact photo placeholder: a soft two-tone gradient with a highlight and a hairline ring.
struct Avatar: View {
    let initials: String
    let colors: (String, String)
    let size: Double
    var ring = false

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                ZStack {
                    LinearGradient(colors: [Color(hex: colors.0), Color(hex: colors.1)],
                                   startPoint: UnitPoint(x: 0.25, y: 0), endPoint: UnitPoint(x: 0.75, y: 1))
                    RadialGradient(colors: [.white.opacity(0.35), .clear], center: UnitPoint(x: 0.3, y: 0.25),
                                   startRadius: 0, endRadius: size * 0.55)
                }
                .clipShape(Circle())
            }
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .background(ring ? Circle().fill(.black).padding(-2) : nil)
    }
}

/// The Messages app icon, drawn (real marks can't ship as assets).
struct MessagesIcon: View {
    let size: Double

    var body: some View {
        Image(systemName: "message.fill")
            .font(.system(size: size * 0.55))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "#6CF06B"), Color(hex: "#24C13A")], startPoint: .top, endPoint: .bottom)))
    }
}

/// Today's date on a little calendar tile.
private struct CalendarTile: View {
    let size: Double

    var body: some View {
        let d = Date()
        VStack(spacing: 0) {
            Text(d.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.system(size: size * 0.2, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: size * 0.32)
                .background(IslandColor.red)
            Text(d.formatted(.dateTime.day()))
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(Color(hex: "#111111"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: size, height: size)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

/// A ring with an optional glyph inside: battery, timer and download progress.
struct Ring<Inner: View>: View {
    let progress: Double
    let color: Color
    let size: Double
    var stroke = 3.4
    /// A level that fills in from empty when it first shows (sim `ringFill`); live clocks and downloads don't.
    var fillsIn = false
    @ViewBuilder var inner: Inner
    @State private var filled = false
    @Environment(\.islandMotion) private var motion

    var body: some View {
        let w = stroke * size / 36
        let shown = !fillsIn || filled || motion.reduce ? min(max(progress, 0), 1) : 0
        ZStack {
            Circle().stroke(.white.opacity(0.13), lineWidth: w)
            Circle().trim(from: 0, to: shown)
                .stroke(color, style: StrokeStyle(lineWidth: w, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)
            inner
        }
        .padding(w / 2 + 0.5 * size / 36)
        .frame(width: size, height: size)
        .onAppear {
            guard fillsIn, !motion.reduce else { return }
            withAnimation(.timingCurve(0.3, 0.9, 0.3, 1, duration: motion.seconds(1)).delay(motion.seconds(motion.delay))) {
                filled = true
            }
        }
    }
}

extension Ring where Inner == EmptyView {
    init(progress: Double, color: Color, size: Double, stroke: Double = 3.4, fillsIn: Bool = false) {
        self.init(progress: progress, color: color, size: size, stroke: stroke, fillsIn: fillsIn) { EmptyView() }
    }
}

private struct TimerRing: View {
    let left: Double
    var total: Double = 60
    var body: some View {
        Ring(progress: left / max(total, 1), color: IslandColor.orange, size: 22) {
            Image(systemName: "timer").font(.system(size: 8, weight: .bold)).foregroundStyle(IslandColor.orange)
        }
    }
}

private struct DownloadRing: View {
    let progress: Double
    var body: some View {
        Ring(progress: progress, color: progress >= 1 ? IslandColor.green : IslandColor.cyan, size: 22, stroke: 3) {
            Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold)).foregroundStyle(IslandColor.cyan)
        }
    }
}

/// The countdown, red and blinking in the last ten seconds.
private struct TimerText: View {
    let left: Double
    let font: Font
    var base: Color = IslandColor.orange
    @Environment(\.islandMotion) private var motion

    var body: some View {
        let urgent = left <= 10 && left > 0
        Text(clockText(left.rounded(.up)))
            .font(font)
            .foregroundStyle(urgent ? IslandColor.red : base)
            .phaseAnimator(urgent && !motion.reduce ? [1.0, 0.55] : [1.0]) { v, o in v.opacity(o) } animation: { _ in
                .easeInOut(duration: motion.seconds(0.5))
            }
    }
}

/// The recording dot, blinking (still under Reduce Motion).
private struct RecordDot: View {
    @Environment(\.islandMotion) private var motion
    var body: some View {
        Circle().fill(IslandColor.red)
            .frame(width: 9, height: 9)
            .shadow(color: IslandColor.red.opacity(0.7), radius: 3)
            .phaseAnimator(motion.reduce ? [1.0] : [1.0, 0.45]) { v, o in v.opacity(o) } animation: { _ in
                .easeInOut(duration: motion.seconds(0.6))
            }
    }
}

/// Focus's ear: the moon in a pill, indigo when on, grey when off.
private struct FocusPill: View {
    let on: Bool
    /// In the ears it grows out of nothing and the moon turns in after it (sim `pillGrow`, `moonIn`).
    var grows = false
    @State private var pill = false
    @State private var moon = false
    @Environment(\.islandMotion) private var motion

    var body: some View {
        let still = !grows || motion.reduce
        let pillOut = still || pill, moonIn = still || moon
        Image(systemName: "moon.fill").font(.system(size: 13))
            .foregroundStyle(.white)
            .rotationEffect(.degrees(moonIn ? 0 : -120))
            .scaleEffect(moonIn ? 1 : 0.3)
            .opacity(moonIn ? 1 : 0)
            .frame(width: pillOut ? 40 : 0, height: 24)
            .background(Capsule().fill(on ? IslandColor.indigo : Color.white.opacity(0.18)))
            .opacity(pillOut ? 1 : 0)
            .frame(width: 40, alignment: .leading)
            .onAppear {
                guard !still else { return }
                let overshoot = { (s: Double, delay: Double) in
                    Animation.timingCurve(0.2, 1.4, 0.4, 1, duration: motion.seconds(s)).delay(motion.seconds(motion.delay + delay))
                }
                withAnimation(overshoot(0.6, 0)) { pill = true }
                withAnimation(overshoot(0.7, 0.15)) { moon = true }
            }
    }
}

/// A straight progress bar.
private struct Bar: View {
    let progress: Double
    let color: Color
    let height: Double

    var body: some View {
        GeometryReader { g in
            Capsule().fill(color.opacity(0.18))
                .overlay(alignment: .leading) {
                    Capsule().fill(color).frame(width: g.size.width * min(max(progress, 0), 1))
                        .animation(.linear(duration: 0.25), value: progress)
                }
        }
        .frame(height: height)
    }
}

/// A battery with a bolt: the outline, the green fill and the nub.
private struct Battery: View {
    let level: Double
    let width: Double
    let height: Double
    var big = false
    /// Low battery: a red fill and no bolt.
    var low = false
    @State private var shown = 0.0
    @Environment(\.islandMotion) private var motion

    var body: some View {
        let border = big ? 2.2 : 1.6, pad = big ? 2.5 : 1.5
        let radius = big ? 13 : height / 2
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: border)
            RoundedRectangle(cornerRadius: max(radius - pad - border, 1), style: .continuous)
                .fill(low ? AnyShapeStyle(IslandColor.red)
                          : AnyShapeStyle(LinearGradient(colors: [Color(hex: "#7BE77B"), IslandColor.green],
                                                         startPoint: .leading, endPoint: .trailing)))
                .overlay { Shine() }
                .clipShape(RoundedRectangle(cornerRadius: max(radius - pad - border, 1), style: .continuous))
                .frame(width: max((width - 2 * (border + pad)) * (motion.reduce ? level : shown), 0))
                .padding(border + pad)
            if !low {
                Image(systemName: "bolt.fill").font(.system(size: height * 0.55)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1)
                    .boltFlash()
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: width, height: height)
        .overlay(alignment: .trailing) {
            UnevenRoundedRectangle(bottomTrailingRadius: big ? 3 : 2, topTrailingRadius: big ? 3 : 2)
                .fill(.white.opacity(0.35))
                .frame(width: big ? 4 : 2.5, height: height * 0.36)
                .offset(x: big ? 7 : 4.5)
        }
        .onAppear {
            if motion.reduce { shown = level; return }
            withAnimation(.timingCurve(0.3, 0.9, 0.3, 1, duration: motion.seconds(1.1)).delay(motion.seconds(motion.delay))) { shown = level }
        }
    }
}

/// One battery in the AirPods card: a small ring with the glyph, the percentage, the name under it.
private struct PodBattery: View {
    let level: Int
    let label: String
    let symbol: String
    let charging: Bool

    var body: some View {
        HStack(spacing: 8) {
            Ring(progress: Double(level) / 100, color: level <= 20 ? IslandColor.red : IslandColor.green, size: 30, stroke: 3.2,
                 fillsIn: true) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.white)
            }
            .overlay(alignment: .bottomTrailing) {
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundStyle(IslandColor.green)
                        .frame(width: 14, height: 14).background(Circle().fill(.black))
                        .offset(x: 4, y: 3)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("\(level)%").font(IslandType.body.weight(.semibold).monospacedDigit())
                Text(label).font(.subheadline).foregroundStyle(IslandColor.secondary)
            }
        }
    }
}

/// The AirPods buds, `height` points tall: the 3D buds (`BudsStage`), turning about their own vertical axis at the
/// front (owner, 11-07: "it should spin slowly, showing only its front"; the 10-31 ruling: never a full turn). Still
/// with Reduce Motion and in stills, paused while hidden. The cutout (the stage's own front view, so nothing jumps)
/// stands in while the model loads, or if it can't.
struct BudsImage: View {
    let height: Double
    @Environment(\.islandMotion) private var motion
    @Environment(\.revealed) private var revealed
    @Environment(\.displayScale) private var scale
    /// Bumped when a load finishes, to draw the stage.
    @State private var loads = 0

    var body: some View {
        let stage = BudsStage.shared
        let still = motion.stills || motion.reduce
        // Stills draw in one pass, with no task to wait on.
        let _ = motion.stills ? stage.loadNow() : ()
        let _ = loads
        if stage.isReady {
            TimelineView(.animation(paused: still || !revealed)) { ctx in
                let frame = stage.image(at: still ? nil : ctx.date, timeScale: motion.timeScale, height: height,
                                        scale: max(scale, 2))
                if let frame { budsFrame(frame, rect: stage.budsRect) } else { cutout }
            }
        } else {
            // Loads on the first showing, and again after the stage let go (a minute unseen); never while hidden.
            cutout.task(id: revealed) {
                guard revealed else { return }
                await stage.load()
                loads += 1
            }
        }
    }

    /// The whole frame, sized and placed so the buds at the front fill `height` where the cutout did.
    private func budsFrame(_ image: CGImage, rect r: CGRect) -> some View {
        let h = height / r.height, w = h * BudsStage.aspect
        return Image(decorative: image, scale: 1).resizable().interpolation(.high)
            .frame(width: w, height: h)
            .offset(x: (0.5 - r.midX) * w, y: (0.5 - r.midY) * h)
            .frame(width: w * r.width, height: height)
            .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
    }

    @ViewBuilder private var cutout: some View {
        if let img = Self.image {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                .frame(height: height)
                .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
        } else {
            Image(systemName: "airpods.gen4").font(.system(size: height * 0.7)).foregroundStyle(.white)
        }
    }

    @MainActor static let image: NSImage? = BudsStage.resource("airpods-buds", "png").flatMap(NSImage.init(contentsOf:))
}

/// A live waveform following a jittery "voice" level rather than a fixed loop. Holds still
/// under Reduce Motion (and while paused).
struct Waveform: View {
    let count: Int
    let color: Color
    let barWidth: Double
    let height: Double
    var live = true
    @Environment(\.islandMotion) private var motion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.11)) { ctx in
            let step = live && !motion.reduce ? Int(ctx.date.timeIntervalSinceReferenceDate / 0.11) : 0
            HStack(spacing: 2) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule().fill(color)
                        .frame(width: barWidth, height: height * scale(i, step))
                }
            }
            .frame(height: height)
            .animation(motion.reduce ? nil : .linear(duration: 0.11), value: step)
        }
    }

    private func scale(_ i: Int, _ step: Int) -> Double {
        guard step != 0 else { return 0.2 }
        let level = 0.35 + noise(step, 0) * 0.65
        let n = Double(count - 1)
        let centre = 1 - abs(Double(i) - n / 2) / (n / 2) * 0.55
        return max(0.12, min(1, level * centre * (0.55 + noise(step, i + 1) * 0.6)))
    }

    /// Deterministic per (step, bar), so the bars hold their shape between redraws.
    private func noise(_ a: Int, _ b: Int) -> Double {
        var h = UInt64(bitPattern: Int64(a &* 73_856_093 ^ b &* 19_349_663))
        h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
        return Double(h % 10_000) / 10_000
    }
}

/// Numbers that count up from zero as they arrive.
private struct CountUp: View {
    let to: Double
    let suffix: String
    @State private var value = 0.0
    @Environment(\.islandMotion) private var motion

    var body: some View {
        Text("0")
            .modifier(CountText(value: motion.reduce ? to : value, suffix: suffix))
            .onAppear {
                if motion.reduce { value = to; return }
                withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: motion.seconds(0.9))) { value = to }
            }
    }
}

private struct CountText: ViewModifier, @preconcurrency Animatable {
    var value: Double
    let suffix: String
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    func body(content: Content) -> some View { Text("\(Int(value.rounded()))\(suffix)") }
}

/// The incoming call's motion: the phone wiggles on a 1.1 s beat (still under Reduce Motion).
private struct Ringing<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.islandMotion) private var motion

    var body: some View {
        content.phaseAnimator(motion.reduce ? [0.0] : [0.0, -16, 14, -10, 6, 0, 0, 0, 0, 0]) { v, a in
            v.rotationEffect(.degrees(a), anchor: UnitPoint(x: 0.5, y: 0.6))
        } animation: { _ in .linear(duration: motion.seconds(0.11)) }
    }
}

/// A ring that grows off the caller's photo and fades, every 1.1 s.
private struct RingingHalo: View {
    @Environment(\.islandMotion) private var motion
    var body: some View {
        if !motion.reduce {
            Circle().strokeBorder(IslandColor.green.opacity(0.7), lineWidth: 2)
                .padding(-3)
                .phaseAnimator([false, true]) { v, out in
                    v.scaleEffect(out ? 1.25 : 0.92).opacity(out ? 0 : 1)
                } animation: { out in out ? .easeOut(duration: motion.seconds(1.1)) : nil }
        }
    }
}

// MARK: - Buttons

enum RoundStyle { case red, green, gray, orange, lit }

/// A 44 pt round button (the iPhone island's). Hover and press scale it; nothing shifts layout.
struct RoundButton: View {
    let symbol: String
    let style: RoundStyle
    var size: Double = 44
    let label: String
    var ringing = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if ringing {
                    Ringing { glyph }
                } else {
                    glyph
                }
            }
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .overlay(ringing ? AcceptPulse(size: size) : nil)
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(style == .lit ? .black : style == .orange ? IslandColor.orange : .white)
            .contentTransition(.symbolEffect(.replace))
    }

    private var fill: AnyShapeStyle {
        switch style {
        case .red: AnyShapeStyle(LinearGradient(colors: [Color(hex: "#FF5A4F"), Color(hex: "#E5362B")], startPoint: .top, endPoint: .bottom))
        case .green: AnyShapeStyle(LinearGradient(colors: [Color(hex: "#3EDB66"), Color(hex: "#26B84B")], startPoint: .top, endPoint: .bottom))
        case .gray: AnyShapeStyle(Color.white.opacity(0.15))
        case .orange: AnyShapeStyle(IslandColor.orange.opacity(0.24))
        case .lit: AnyShapeStyle(Color.white)
        }
    }
}

/// The accept button's ring: it spreads out and fades on the ringing beat.
private struct AcceptPulse: View {
    let size: Double
    @Environment(\.islandMotion) private var motion
    var body: some View {
        if !motion.reduce {
            Circle().stroke(IslandColor.green.opacity(0.6), lineWidth: 2)
                .phaseAnimator([false, true]) { v, out in
                    v.scaleEffect(out ? (size + 28) / size : 1).opacity(out ? 0 : 1)
                } animation: { out in out ? .easeOut(duration: motion.seconds(0.77)) : .linear(duration: motion.seconds(0.33)) }
                .allowsHitTesting(false)
        }
    }
}

/// Grows a little on hover and squashes on press, with a springy release. Scales only, so
/// nothing around it moves.
struct PressScaleStyle: ButtonStyle {
    var pressed = 0.88
    var hover = 1.06

    func makeBody(configuration: Configuration) -> some View {
        Hovering(scale: configuration.isPressed ? pressed : nil, hover: hover) { configuration.label }
    }

    private struct Hovering<Label: View>: View {
        let scale: Double?
        let hover: Double
        @ViewBuilder let label: Label
        @State private var over = false

        var body: some View {
            label
                .scaleEffect(scale ?? (over ? hover : 1))
                .animation(.spring(response: 0.25, dampingFraction: 0.55), value: scale)
                .animation(.spring(response: 0.25, dampingFraction: 0.55), value: over)
                .onHover { over = $0 }
        }
    }
}

// MARK: - Entrances

private struct Entrance: ViewModifier {
    /// Ears slide in from beside the notch; card rows rise.
    enum Kind { case ear(EarSide), rise }
    let kind: Kind
    let index: Int
    @State private var shown = false
    @Environment(\.islandMotion) private var motion

    func body(content: Content) -> some View {
        let dx: Double = { if case .ear(let s) = kind { return s == .left ? 18 : -18 } else { return 0 } }()
        let isEar: Bool = { if case .ear = kind { return true } else { return false } }()
        let visible = shown || motion.reduce
        content
            .opacity(visible ? 1 : 0)
            .blur(radius: visible ? 0 : (isEar ? 6 : 5))
            .scaleEffect(visible ? 1 : (isEar ? 0.5 : 0.95))
            .offset(x: visible ? 0 : dx, y: visible || isEar ? 0 : 10)
            .onAppear {
                if motion.reduce { shown = true; return }
                let stagger = isEar ? 0.05 : 0.07
                withAnimation(.spring(response: motion.seconds(0.5), dampingFraction: 0.62)
                    .delay(motion.seconds(motion.delay + stagger * Double(index)))) { shown = true }
            }
    }
}

extension View {
    func entrance(_ side: EarSide, _ index: Int) -> some View { modifier(Entrance(kind: .ear(side), index: index)) }
    func rise(_ index: Int) -> some View { modifier(Entrance(kind: .rise, index: index)) }
    /// The sim's one-off moments when something first shows (11-06 polish).
    func zap() -> some View { modifier(Zap()) }
    func boltFlash() -> some View { modifier(BoltFlash()) }
    func drop() -> some View { modifier(Drop()) }
}

// MARK: - Moments

/// A pose the moments animate through.
struct MomentPose {
    var opacity = 1.0
    var scale = 1.0
    var angle = 0.0
}

/// CSS's default `ease`, which the sim's keyframes use between their stops.
private let cssEase = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.25, y: 0.1), endControlPoint: UnitPoint(x: 0.25, y: 1))

/// The charging bolt zaps in (sim `zap`, 0.9 s): out of nothing to 1.5× with a twist, a dip, then rest.
struct Zap: ViewModifier {
    @State private var run = false
    @Environment(\.islandMotion) private var motion

    nonisolated static let hidden = MomentPose(opacity: 0, scale: 0.2, angle: -30)

    /// `wait` holds it hidden while the content's reveal is still to come; `t` is the zap's own length.
    @KeyframesBuilder<MomentPose> static func keys(wait: Double, t: Double) -> some Keyframes<MomentPose> {
        KeyframeTrack(\.opacity) {
            MoveKeyframe(0); LinearKeyframe(0, duration: wait)
            LinearKeyframe(1, duration: 0.35 * t, timingCurve: cssEase)
        }
        KeyframeTrack(\.scale) {
            MoveKeyframe(0.2); LinearKeyframe(0.2, duration: wait)
            LinearKeyframe(1.5, duration: 0.35 * t, timingCurve: cssEase)
            LinearKeyframe(0.9, duration: 0.25 * t, timingCurve: cssEase)
            LinearKeyframe(1, duration: 0.4 * t, timingCurve: cssEase)
        }
        KeyframeTrack(\.angle) {
            MoveKeyframe(-30); LinearKeyframe(-30, duration: wait)
            LinearKeyframe(8, duration: 0.35 * t, timingCurve: cssEase)
            LinearKeyframe(0, duration: 0.25 * t, timingCurve: cssEase)
        }
    }

    func body(content: Content) -> some View {
        let wait = motion.seconds(motion.delay + 0.1), t = motion.seconds(0.9), started = run || motion.reduce
        content
            .keyframeAnimator(initialValue: MomentPose(), trigger: run) { c, v in
                let p = started ? v : Self.hidden
                c.opacity(p.opacity).scaleEffect(p.scale).rotationEffect(.degrees(p.angle))
            } keyframes: { _ in Self.keys(wait: wait, t: t) }
            .onAppear { if !motion.reduce { run = true } }
    }
}

/// The battery's bolt flashes in after the fill has started (sim `boltFlash`, 1.2 s, 0.55 s after the content).
struct BoltFlash: ViewModifier {
    @State private var run = false
    @Environment(\.islandMotion) private var motion

    nonisolated static let hidden = MomentPose(opacity: 0, scale: 0.3)

    @KeyframesBuilder<MomentPose> static func keys(wait: Double, t: Double) -> some Keyframes<MomentPose> {
        KeyframeTrack(\.opacity) {
            MoveKeyframe(0); LinearKeyframe(0, duration: wait)
            LinearKeyframe(1, duration: 0.4 * t, timingCurve: cssEase)
        }
        KeyframeTrack(\.scale) {
            MoveKeyframe(0.3); LinearKeyframe(0.3, duration: wait)
            LinearKeyframe(1.35, duration: 0.4 * t, timingCurve: cssEase)
            LinearKeyframe(1, duration: 0.6 * t, timingCurve: cssEase)
        }
    }

    func body(content: Content) -> some View {
        let wait = motion.seconds(motion.delay + 0.55), t = motion.seconds(1.2), started = run || motion.reduce
        content
            .keyframeAnimator(initialValue: MomentPose(), trigger: run) { c, v in
                let p = started ? v : Self.hidden
                c.opacity(p.opacity).scaleEffect(p.scale)
            } keyframes: { _ in Self.keys(wait: wait, t: t) }
            .onAppear { if !motion.reduce { run = true } }
    }
}

/// The AirPods drop into their card with a little tilt (sim `podsDrop`, 0.8 s, overshooting).
private struct Drop: ViewModifier {
    @State private var down = false
    @Environment(\.islandMotion) private var motion

    func body(content: Content) -> some View {
        let v = down || motion.reduce
        content
            .opacity(v ? 1 : 0)
            .scaleEffect(v ? 1 : 0.7)
            .rotationEffect(.degrees(v ? 0 : -10))
            .offset(y: v ? 0 : -30)
            .onAppear {
                guard !motion.reduce else { return }
                withAnimation(.timingCurve(0.2, 1.4, 0.4, 1, duration: motion.seconds(0.8)).delay(motion.seconds(motion.delay))) {
                    down = true
                }
            }
    }
}

/// A light that sweeps across a battery's fill every 1.8 s, starting a second after it shows (sim `shine`).
private struct Shine: View {
    private enum Pass { case before, across, rest }
    @State private var on = false
    @Environment(\.islandMotion) private var motion

    var body: some View {
        GeometryReader { g in
            if on {
                LinearGradient(stops: [.init(color: .clear, location: 0.2), .init(color: .white.opacity(0.55), location: 0.45),
                                       .init(color: .clear, location: 0.7)],
                               startPoint: UnitPoint(x: 0, y: 0.41), endPoint: UnitPoint(x: 1, y: 0.59))
                    .phaseAnimator([Pass.before, .across, .rest]) { v, pass in
                        // `rest` sits past the edge (clipped) so the pause between sweeps is a real move that takes its time.
                        v.offset(x: g.size.width * (pass == .before ? -1.2 : pass == .across ? 1.2 : 1.3))
                    } animation: { pass in
                        switch pass {
                        case .across: .timingCurve(0.25, 0.1, 0.25, 1, duration: motion.seconds(1.08))
                        case .rest: .linear(duration: motion.seconds(0.72))
                        case .before: nil
                        }
                    }
            }
        }
        .allowsHitTesting(false)
        .task {
            guard !motion.reduce else { return }
            try? await Task.sleep(for: .seconds(motion.seconds(motion.delay + 1)))
            on = true
        }
    }
}

/// Recording from the notch (11-06): the 3-2-1, pressed again to cancel.
private struct RecordCountdownCard: View {
    let director: IslandDirector

    var body: some View {
        let _ = director.now
        HStack(spacing: 12) {
            Image(systemName: "record.circle").font(.system(size: 21)).foregroundStyle(IslandColor.red)
                .frame(width: 40, height: 40).background(Circle().fill(IslandColor.red.opacity(0.18))).rise(0)
            VStack(alignment: .leading, spacing: 0) {
                Text("Recording in \(director.recordCountdown)").font(IslandType.title).monospacedDigit().lineLimit(1)
                Text("The whole screen · ⌃⌥⌘R again cancels").font(IslandType.secondary)
                    .foregroundStyle(IslandColor.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rise(1)
        }
        .frame(maxHeight: .infinity)
    }
}

/// The recording is on the Desktop (and the Shelf): its name, length, and a way to it.
private struct RecordingSavedCard: View {
    let director: IslandDirector

    var body: some View {
        let r = director.lastRecording
        HStack(spacing: 12) {
            Image(systemName: "film").font(.system(size: 19)).foregroundStyle(IslandColor.green)
                .frame(width: 40, height: 40).background(Circle().fill(IslandColor.green.opacity(0.18))).rise(0)
            VStack(alignment: .leading, spacing: 0) {
                Text(r.name).font(IslandType.title).lineLimit(1).truncationMode(.middle)
                Text("Desktop · \(clockText(r.seconds)) · on the Shelf too").font(IslandType.secondary)
                    .foregroundStyle(IslandColor.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rise(1)
            RoundButton(symbol: "folder", style: .gray, label: "Show in Finder") { director.perform(.revealRecording) }.rise(2)
        }
        .frame(maxHeight: .infinity)
    }
}
