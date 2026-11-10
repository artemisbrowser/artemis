// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// a curated ~500 of the most commonly used SF Symbols, grouped into everyday
/// categories for the space icon picker. names are validated against the
/// on-device CoreGlyphs catalogue (aliases included — they still render)
nonisolated enum SFSymbols {
    struct Category { let name: String; let symbols: [String] }

    /// case-insensitive substring match on the symbol name; empty query returns
    /// the whole curated set in order
    static func search(_ query: String) -> [String] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return allSymbols }
        return allSymbols.filter { $0.contains(q) }
    }

    static let categories: [Category] = [
        Category(name: "General", symbols: [
            "star.fill", "star", "heart.fill", "heart", "sparkles", "sparkle", "bolt.fill",
            "bolt.heart.fill", "flame.fill", "circle.fill", "square.fill", "triangle.fill", "diamond.fill",
            "hexagon.fill", "octagon.fill", "pentagon.fill", "seal.fill", "shield.fill", "crown.fill",
            "rosette", "medal.fill", "trophy.fill", "flag.fill", "flag.2.crossed.fill", "bookmark.fill",
            "tag.fill", "pin.fill", "mappin", "paperclip", "link", "checkmark.seal.fill", "drop.fill",
            "leaf.fill", "gift.fill", "balloon.fill", "party.popper.fill", "lightbulb.fill", "key.fill",
            "lock.fill", "lock.open.fill", "bell.fill", "megaphone.fill", "hand.thumbsup.fill",
            "hand.raised.fill", "eye.fill", "wand.and.rays", "moon.stars.fill", "globe", "atom",
            "questionmark", "exclamationmark", "asterisk", "staroflife.fill", "burst.fill", "moon.fill",
            "bell.badge.fill", "flag.circle.fill", "star.circle.fill", "heart.circle.fill",
        ]),
        Category(name: "Space & Cosmos", symbols: [
            "moon.stars.fill", "moon.dust.fill", "moon.haze.fill", "moonrise.fill", "moonset.fill",
            "moonphase.full.moon", "moonphase.first.quarter", "moonphase.waxing.crescent",
            "moonphase.waning.crescent", "sun.horizon.fill", "sun.dust.fill", "sun.haze.fill",
            "star.hexagon.fill", "sparkles.2", "atom", "globe.central.south.asia.fill",
        ]),
        Category(name: "Communication", symbols: [
            "message.fill", "bubble.left.fill", "bubble.right.fill", "bubble.left.and.bubble.right.fill",
            "ellipsis.bubble.fill", "quote.bubble.fill", "exclamationmark.bubble.fill", "phone.fill",
            "phone.down.fill", "envelope.fill", "envelope.open.fill", "envelope.badge.fill",
            "paperplane.fill", "tray.fill", "tray.full.fill", "at", "video.fill", "video.bubble.fill",
            "antenna.radiowaves.left.and.right", "wifi", "person.fill", "person.2.fill", "person.3.fill",
            "person.crop.circle.fill", "hand.wave.fill", "mic.fill", "speaker.wave.2.fill",
            "phone.circle.fill", "envelope.circle.fill", "bubble.middle.bottom.fill",
            "person.crop.circle.badge.plus", "arrow.up.message.fill", "phone.arrow.up.right.fill",
        ]),
        Category(name: "Weather & Nature", symbols: [
            "sun.max.fill", "sun.min.fill", "sunrise.fill", "sunset.fill", "cloud.fill", "cloud.rain.fill",
            "cloud.heavyrain.fill", "cloud.drizzle.fill", "cloud.bolt.fill", "cloud.bolt.rain.fill",
            "cloud.snow.fill", "cloud.fog.fill", "cloud.sun.fill", "cloud.moon.fill", "wind", "snowflake",
            "tornado", "hurricane", "rainbow", "thermometer.sun.fill", "thermometer.snowflake",
            "humidity.fill", "tree.fill", "camera.macro", "mountain.2.fill", "globe.americas.fill",
            "globe.europe.africa.fill", "water.waves", "fish.fill", "pawprint.fill", "cloud.sun.rain.fill",
            "thermometer.medium", "snowflake.circle.fill", "aqi.medium", "sun.haze.fill",
        ]),
        Category(name: "Animals", symbols: [
            "dog.fill", "cat.fill", "bird.fill", "tortoise.fill", "hare.fill", "ant.fill", "ladybug.fill",
            "lizard.fill", "teddybear.fill", "carrot.fill",
        ]),
        Category(name: "Food & Drink", symbols: [
            "fork.knife", "cup.and.saucer.fill", "mug.fill", "wineglass.fill", "waterbottle.fill",
            "takeoutbag.and.cup.and.straw.fill", "birthday.cake.fill", "frying.pan.fill", "popcorn.fill",
            "wineglass", "mug", "cup.and.heat.waves.fill",
        ]),
        Category(name: "Travel & Transport", symbols: [
            "airplane", "airplane.departure", "airplane.arrival", "car.fill", "car.2.fill", "bus.fill",
            "tram.fill", "train.side.front.car", "bicycle", "scooter", "motorcycle", "sailboat.fill",
            "ferry.fill", "fuelpump.fill", "road.lanes", "map.fill", "location.fill",
            "location.north.fill", "signpost.right.fill", "suitcase.fill", "suitcase.rolling.fill",
            "beach.umbrella.fill", "tent.fill", "figure.walk", "parkingsign", "steeringwheel", "bag.fill",
            "airplane.circle.fill", "binoculars.fill", "car.circle.fill", "bicycle.circle.fill", "map",
            "location.circle.fill", "tram.circle.fill",
        ]),
        Category(name: "Devices & Tech", symbols: [
            "desktopcomputer", "laptopcomputer", "macbook", "iphone", "ipad", "applewatch", "apple.logo",
            "keyboard.fill", "computermouse.fill", "display", "tv.fill", "headphones", "airpods",
            "homepod.fill", "gamecontroller.fill", "printer.fill", "camera.fill", "cpu.fill",
            "memorychip.fill", "externaldrive.fill", "internaldrive.fill", "sdcard.fill", "simcard.fill",
            "battery.100percent", "powerplug.fill", "cable.connector", "network", "server.rack",
            "opticaldisc.fill", "speaker.wave.3.fill", "app.fill", "square.stack.3d.up.fill",
            "scanner.fill", "phone", "appletv.fill", "hifispeaker.fill", "lightswitch.on.fill",
            "magicmouse.fill", "sensor.fill", "camera.aperture",
        ]),
        Category(name: "Media & Audio", symbols: [
            "play.fill", "pause.fill", "stop.fill", "forward.fill", "backward.fill", "forward.end.fill",
            "backward.end.fill", "playpause.fill", "shuffle", "repeat", "speaker.slash.fill", "music.note",
            "music.note.list", "music.microphone", "guitars.fill", "pianokeys", "metronome.fill",
            "film.fill", "photo.fill", "photo.stack.fill", "mic.slash.fill", "waveform",
            "slider.horizontal.3", "radio.fill", "dot.radiowaves.left.and.right", "airplayvideo",
            "airplayaudio", "play.rectangle.fill", "speaker.fill", "music.quarternote.3",
            "video.circle.fill", "photo.on.rectangle.fill", "play.circle.fill", "pause.circle.fill",
        ]),
        Category(name: "Files & Work", symbols: [
            "folder.fill", "doc.fill", "doc.text.fill", "doc.on.doc.fill", "note.text", "list.bullet",
            "list.bullet.clipboard.fill", "checklist", "calendar", "archivebox.fill", "pencil",
            "pencil.tip", "highlighter", "scissors", "ruler.fill", "paintbrush.fill", "paintpalette.fill",
            "briefcase.fill", "case.fill", "book.fill", "book.closed.fill", "books.vertical.fill",
            "graduationcap.fill", "newspaper.fill", "magazine.fill", "chart.bar.fill", "chart.pie.fill",
            "chart.line.uptrend.xyaxis", "folder.badge.plus", "tray.and.arrow.down.fill",
            "doc.richtext.fill", "calendar.badge.clock", "clipboard.fill", "doc.plaintext.fill",
            "folder.circle.fill", "square.and.pencil", "tray.2.fill", "calendar.circle.fill",
            "doc.append.fill",
        ]),
        Category(name: "Commerce & Finance", symbols: [
            "cart.fill", "creditcard.fill", "banknote.fill", "dollarsign.circle.fill",
            "eurosign.circle.fill", "sterlingsign.circle.fill", "bitcoinsign.circle.fill",
            "yensign.circle.fill", "giftcard.fill", "wallet.pass.fill", "percent", "building.columns.fill",
            "storefront.fill", "shippingbox.fill", "barcode", "qrcode", "cart.badge.plus",
            "dollarsign.square.fill", "creditcard.and.123", "cart.circle.fill", "bag.circle.fill",
            "creditcard.circle.fill", "dollarsign", "eurosign", "gift.circle.fill",
        ]),
        Category(name: "Health & Fitness", symbols: [
            "cross.fill", "cross.case.fill", "pills.fill", "cross.vial.fill", "stethoscope",
            "bandage.fill", "brain.head.profile.fill", "lungs.fill", "figure.run", "figure.yoga",
            "figure.cooldown", "figure.strengthtraining.traditional", "dumbbell.fill", "sportscourt.fill",
            "bed.double.fill", "heart.text.square.fill", "waveform.path.ecg", "allergens.fill",
            "facemask.fill", "cross.circle.fill", "pills.circle.fill", "syringe.fill",
            "medical.thermometer.fill", "figure.mind.and.body",
        ]),
        Category(name: "Sports & Games", symbols: [
            "soccerball", "basketball.fill", "american.football.fill", "baseball.fill", "tennis.racket",
            "tennisball.fill", "volleyball.fill", "dice.fill", "puzzlepiece.fill", "target",
            "skateboard.fill", "surfboard.fill", "football.fill", "hockey.puck.fill", "cricket.ball.fill",
            "trophy.circle.fill", "figure.basketball", "figure.soccer", "figure.tennis", "figure.golf",
            "figure.boxing", "dice",
        ]),
        Category(name: "Home & Places", symbols: [
            "house.fill", "house.lodge.fill", "building.fill", "building.2.fill", "lamp.desk.fill",
            "sofa.fill", "chair.fill", "bathtub.fill", "shower.fill", "washer.fill", "refrigerator.fill",
            "oven.fill", "sink.fill", "door.left.hand.closed", "window.casement", "stairs",
            "fireplace.fill", "spigot.fill", "fan.fill", "mappin.and.ellipse", "house.circle.fill",
            "building.2.crop.circle.fill", "lightbulb.2.fill", "cabinet.fill", "mappin.circle.fill",
        ]),
        Category(name: "Time", symbols: [
            "clock.fill", "alarm.fill", "stopwatch.fill", "timer", "hourglass", "deskclock.fill",
            "gauge.with.needle.fill", "moon.zzz.fill", "clock.arrow.circlepath", "clock.badge.fill",
            "timer.circle.fill", "alarm.waves.left.and.right.fill",
        ]),
        Category(name: "Arrows & Navigation", symbols: [
            "arrow.up", "arrow.down", "arrow.left", "arrow.right", "arrow.up.right", "arrow.turn.up.right",
            "arrow.uturn.left", "arrow.uturn.right", "arrow.clockwise", "arrow.counterclockwise",
            "arrow.triangle.2.circlepath", "arrow.up.arrow.down", "arrow.left.arrow.right",
            "arrow.up.right.square.fill", "chevron.right", "chevron.up", "chevron.down",
            "chevron.left.forwardslash.chevron.right", "scope", "safari.fill",
            "arrowshape.turn.up.right.fill", "arrow.up.forward.app.fill", "arrow.down.circle.fill",
            "compass.drawing", "arrow.right.circle.fill", "arrow.left.circle.fill", "arrow.up.circle.fill",
            "arrowshape.right.fill", "arrowshape.left.fill", "hand.point.up.fill",
        ]),
        Category(name: "Symbols & Editing", symbols: [
            "plus", "minus", "multiply", "divide", "equal", "number.square.fill", "plus.circle.fill",
            "minus.circle.fill", "checkmark", "checkmark.circle.fill", "xmark", "xmark.circle.fill",
            "exclamationmark.triangle.fill", "questionmark.circle.fill", "info.circle.fill", "ellipsis",
            "ellipsis.circle.fill", "gearshape.fill", "gearshape.2.fill", "line.3.horizontal",
            "square.grid.2x2.fill", "trash.fill", "magnifyingglass", "eye.slash.fill", "hand.tap.fill",
            "wrench.and.screwdriver.fill", "hammer.fill", "screwdriver.fill", "function", "infinity",
            "textformat", "bold", "italic", "number", "command", "option", "power", "gear",
            "checkmark.square.fill", "square.and.arrow.up.fill", "square.and.arrow.down.fill",
            "bolt.circle.fill", "plus.square.fill",
        ]),
        Category(name: "People & Faces", symbols: [
            "person.crop.square.fill", "figure.stand", "figure.wave", "hand.thumbsdown.fill",
            "hands.clap.fill", "face.smiling", "brain.fill", "mustache.fill", "theatermasks.fill",
            "figure.2.and.child.holdinghands", "person.badge.shield.checkmark.fill",
            "figure.and.child.holdinghands", "person.circle.fill", "figure.child", "hand.point.right.fill",
            "hands.and.sparkles.fill", "figure.arms.open",
        ]),
    ]

    /// every curated symbol once, in category order — the search corpus
    static let allSymbols: [String] = categories.flatMap(\.symbols)
}
