import SwiftUI

struct ReferenceTheme {
    let dark: Bool
    var content: Color { Color(hex: dark ? 0x141417 : 0xeef0f4) }
    var window: Color { Color(hex: dark ? 0x1c1c1f : 0xf3f3f6) }
    var card: Color { Color(hex: dark ? 0x2a2a2e : 0xffffff) }
    var text: Color { Color(hex: dark ? 0xf2f2f5 : 0x1d1d1f) }
    var secondary: Color { Color(hex: dark ? 0xb0b2b9 : 0x5f6168) }
    var faint: Color { Color(hex: dark ? 0x85878e : 0x8e9097) }
    var accent: Color { Color(hex: dark ? 0x3c96ff : 0x0a7aff) }
    var line: Color { (dark ? Color.white : Color.black).opacity(dark ? 0.08 : 0.09) }
    var strongLine: Color { (dark ? Color.white : Color.black).opacity(0.14) }
    var control: Color { (dark ? Color.white : Color.black).opacity(dark ? 0.08 : 0.05) }
    var lane: Color { Color.white.opacity(dark ? 0.035 : 0.55) }
    var column: Color { dark ? Color.white.opacity(0.035) : Color(hex: 0x788096).opacity(0.07) }
    var glass: Color { dark ? Color(hex: 0x28282e).opacity(0.55) : Color.white.opacity(0.58) }
    func status(_ key: String) -> (Color, Color, Color) {
        let light: [String: (UInt32, UInt32, UInt32)] = [
            "queued": (0x8e8e93,0xf2f2f4,0x5f6168), "running": (0x0a7aff,0xeaf3ff,0x0059c7),
            "gating": (0x5e5ce6,0xefeefe,0x4240b8), "retry": (0xe0a800,0xfff8dc,0x8a6400),
            "waiting": (0xff8a00,0xfff2e3,0xb45a00), "review": (0x12a5b8,0xe6f7f9,0x0a7584),
            "paused": (0x7d8796,0xeef0f3,0x535c6a), "blocked": (0xa2845e,0xf6f0e8,0x7a5f3c),
            "conflict": (0xaf52de,0xf7eefc,0x8333ad), "incident": (0xe5251b,0xffe9e7,0xb3140c),
            "done": (0x30b553,0xeaf8ee,0x1e7d38), "cancelled": (0xa4a6ad,0xf3f3f5,0x7c7e85)]
        let night: [String: (UInt32, UInt32, UInt32)] = [
            "queued": (0x8e8e93,0x2f2f34,0xb0b2b9), "running": (0x3c96ff,0x16273d,0x7db8ff),
            "gating": (0x8381ff,0x23223f,0xaeacff), "retry": (0xffd23f,0x362d10,0xffd966),
            "waiting": (0xff9f2e,0x3a2610,0xffb763), "review": (0x3cc6d8,0x11303a,0x74dbe8),
            "paused": (0x7d8796,0x2c3038,0xa9b2c0), "blocked": (0xc4a37a,0x33291e,0xd9bb94),
            "conflict": (0xcf7cf6,0x34203f,0xdfa2fb), "incident": (0xff453a,0x4a1513,0xff8c85),
            "done": (0x3fcf68,0x15301e,0x74e094), "cancelled": (0xa4a6ad,0x2c2c30,0x8a8c93)]
        let v = (dark ? night : light)[key == "suspicious" ? "waiting" : key] ?? light["queued"]!
        return (Color(hex: v.0), Color(hex: v.1), Color(hex: v.2))
    }
}

extension Color {
    init(hex: UInt32) { self.init(red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255) }
}

struct ReferenceButton: View {
    let title: String
    var icon: String? = nil
    var primary = false
    var small = false
    let theme: ReferenceTheme
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: small ? 10 : 11)) }
                Text(title).font(.system(size: small ? 11 : 12, weight: .medium))
            }.padding(.horizontal, small ? 8 : 10).frame(height: small ? 20 : 24)
                .foregroundStyle(primary ? .white : theme.text)
                .background(primary ? theme.accent : theme.card, in: RoundedRectangle(cornerRadius: small ? 6 : 7))
                .overlay(RoundedRectangle(cornerRadius: small ? 6 : 7).stroke(primary ? .clear : theme.line, lineWidth: 0.5))
        }.buttonStyle(.plain)
    }
}

struct ReferenceChip: View {
    let title: String
    let theme: ReferenceTheme
    var tone: String? = nil
    var mono = false
    var body: some View {
        Text(title).font(.system(size: 10.5, weight: .medium, design: mono ? .monospaced : .default))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(tone.map { theme.status($0).2 } ?? theme.secondary)
            .background(tone.map { theme.status($0).1 } ?? theme.control, in: RoundedRectangle(cornerRadius: 5))
    }
}

struct ReferenceBackdrop: View {
    let theme: ReferenceTheme
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin:.zero,size:size)),with:.color(theme.content))
            for item in [(CGRect(x:-120,y:-80,width:520,height:420),UInt32(0xffb08a)),(CGRect(x:-60,y:420,width:420,height:520),UInt32(0x9ec5ff)),(CGRect(x:620,y:-200,width:700,height:360),UInt32(0xc7d7ff)),(CGRect(x:1100,y:560,width:500,height:400),UInt32(0xffd9ec))] {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius:70))
                    layer.opacity = theme.dark ? 0.28 : 0.55
                    layer.fill(Path(ellipseIn:item.0),with:.color(Color(hex:item.1)))
                }
            }
        }.background(theme.content).clipped()
    }
}

struct ReferenceBox<Content: View>: View {
    let title: String
    let theme: ReferenceTheme
    @ViewBuilder var content: () -> Content
    private static var headerInfo:[String:(String,String)]{["Идентичность и вид":("tag","id, display"),"Пропускная способность":("gauge.with.dots.needle.50percent","wip, priority"),"Исполнитель":("cpu","agent"),"Права":("shield","permissions, mcp, git"),"Окружение и рабочая копия":("shippingbox","env, workspace"),"Вход":("rectangle.portrait.and.arrow.right","inputs"),"Гейты":("checklist","gates"),"Переходы":("arrow.triangle.branch","on_success, returns_to"),"Надёжность":("timer","retry, timeouts"),"Хуки и уведомления":("powerplug","hooks, notify")]}
    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            HStack(spacing:6){if let item=Self.headerInfo[title]{Image(systemName:item.0).font(.system(size:13));Text(title).font(.system(size:12.5,weight:.semibold));Spacer();Text(item.1).font(.system(size:10,design:.monospaced)).foregroundStyle(theme.faint)}else{Text(title).font(.system(size:12.5,weight:.semibold))}}
            content()
        }.padding(12).frame(maxWidth: .infinity,alignment: .leading)
            .background(theme.card,in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line,lineWidth: 0.5))
    }
}

// Original outlined Onest wordmark, from supplied brand SVG (no font installation).
struct ReferenceWordmark: Shape {
 func path(in rect:CGRect)->Path {
 var p=Path()
p.move(to:CGPoint(x:15.00009765625,y:148.0))
p.addLine(to:CGPoint(x:15.00009765625,y:6.480004882812494))
p.addLine(to:CGPoint(x:43.679638671875004,y:6.480004882812494))
p.addLine(to:CGPoint(x:43.679638671875004,y:65.2002685546875))
p.addLine(to:CGPoint(x:63.6396728515625,y:65.2002685546875))
p.addLine(to:CGPoint(x:100.48005371093751,y:6.480004882812494))
p.addLine(to:CGPoint(x:133.1995361328125,y:6.480004882812494))
p.addLine(to:CGPoint(x:87.6793212890625,y:75.2400634765625))
p.addLine(to:CGPoint(x:133.11955566406252,y:148.0))
p.addLine(to:CGPoint(x:99.68007812500001,y:148.0))
p.addLine(to:CGPoint(x:64.7596923828125,y:91.5598388671875))
p.addLine(to:CGPoint(x:43.679638671875004,y:91.5598388671875))
p.addLine(to:CGPoint(x:43.679638671875004,y:148.0))
p.closeSubpath()
p.move(to:CGPoint(x:172.84011230468752,y:149.439990234375))
p.addQuadCurve(to:CGPoint(x:158.88011474609374,y:147.47999267578126),control:CGPoint(x:165.5201171875,y:149.439990234375))
p.addQuadCurve(to:CGPoint(x:147.060107421875,y:141.55999755859375),control:CGPoint(x:152.2401123046875,y:145.5199951171875))
p.addQuadCurve(to:CGPoint(x:138.84010009765626,y:131.64000244140624),control:CGPoint(x:141.8801025390625,y:137.6))
p.addQuadCurve(to:CGPoint(x:135.80009765625002,y:117.6400146484375),control:CGPoint(x:135.80009765625002,y:125.6800048828125))
p.addQuadCurve(to:CGPoint(x:140.1800537109375,y:100.2801025390625),control:CGPoint(x:135.80009765625002,y:106.840087890625))
p.addQuadCurve(to:CGPoint(x:152.01993408203126,y:90.360107421875),control:CGPoint(x:144.560009765625,y:93.7201171875))
p.addQuadCurve(to:CGPoint(x:169.09976806640626,y:85.82008056640625),control:CGPoint(x:159.4798583984375,y:87.00009765625))
p.addQuadCurve(to:CGPoint(x:189.119580078125,y:84.64006347656249),control:CGPoint(x:178.719677734375,y:84.64006347656249))
p.addLine(to:CGPoint(x:204.4002197265625,y:84.64006347656249))
p.addQuadCurve(to:CGPoint(x:202.32020263671876,y:74.3198486328125),control:CGPoint(x:204.4002197265625,y:78.7599365234375))
p.addQuadCurve(to:CGPoint(x:196.02012939453127,y:67.31971435546875),control:CGPoint(x:200.240185546875,y:69.8797607421875))
p.addQuadCurve(to:CGPoint(x:185.2399658203125,y:64.75966796875),control:CGPoint(x:191.80007324218752,y:64.75966796875))
p.addQuadCurve(to:CGPoint(x:177.17987060546875,y:65.8396728515625),control:CGPoint(x:180.959912109375,y:64.75966796875))
p.addQuadCurve(to:CGPoint(x:170.839794921875,y:68.97969970703124),control:CGPoint(x:173.39982910156252,y:66.919677734375))
p.addQuadCurve(to:CGPoint(x:167.3997314453125,y:74.2397705078125),control:CGPoint(x:168.2797607421875,y:71.03972167968749))
p.addLine(to:CGPoint(x:139.000146484375,y:74.2397705078125))
p.addQuadCurve(to:CGPoint(x:144.62014160156252,y:59.17988281249999),control:CGPoint(x:140.2801513671875,y:65.47983398437499))
p.addQuadCurve(to:CGPoint(x:155.52010498046877,y:48.85996093749999),control:CGPoint(x:148.96013183593752,y:52.87993164062499))
p.addQuadCurve(to:CGPoint(x:169.9600341796875,y:42.88000488281249),control:CGPoint(x:162.080078125,y:44.839990234374994))
p.addQuadCurve(to:CGPoint(x:186.1999267578125,y:40.92001953124999),control:CGPoint(x:177.83999023437502,y:40.92001953124999))
p.addQuadCurve(to:CGPoint(x:211.5598876953125,y:46.78002929687499),control:CGPoint(x:201.63991699218752,y:40.92001953124999))
p.addQuadCurve(to:CGPoint(x:226.33983154296874,y:63.860034179687496),control:CGPoint(x:221.4798583984375,y:52.640039062499994))
p.addQuadCurve(to:CGPoint(x:231.1998046875,y:91.239990234375),control:CGPoint(x:231.1998046875,y:75.080029296875))
p.addLine(to:CGPoint(x:231.1998046875,y:148.0))
p.addLine(to:CGPoint(x:205.96025390625002,y:148.0))
p.addLine(to:CGPoint(x:205.56022949218752,y:134.360009765625))
p.addQuadCurve(to:CGPoint(x:194.30025634765627,y:144.6399658203125),control:CGPoint(x:200.6802490234375,y:141.4399658203125))
p.addQuadCurve(to:CGPoint(x:182.140234375,y:148.63997802734374),control:CGPoint(x:187.920263671875,y:147.8399658203125))
p.addQuadCurve(to:CGPoint(x:172.84011230468752,y:149.439990234375),control:CGPoint(x:176.360205078125,y:149.439990234375))
p.closeSubpath()
p.move(to:CGPoint(x:179.23991699218752,y:127.240283203125))
p.addQuadCurve(to:CGPoint(x:191.9801025390625,y:124.420263671875),control:CGPoint(x:186.24003906250002,y:127.240283203125))
p.addQuadCurve(to:CGPoint(x:201.18018798828126,y:116.76018066406249),control:CGPoint(x:197.720166015625,y:121.600244140625))
p.addQuadCurve(to:CGPoint(x:204.6402099609375,y:105.9599853515625),control:CGPoint(x:204.6402099609375,y:111.9201171875))
p.addLine(to:CGPoint(x:204.6402099609375,y:103.3998779296875))
p.addLine(to:CGPoint(x:181.119970703125,y:103.3998779296875))
p.addQuadCurve(to:CGPoint(x:175.09989013671876,y:103.85987548828125),control:CGPoint(x:178.23994140625,y:103.3998779296875))
p.addQuadCurve(to:CGPoint(x:169.37978515625002,y:105.51988525390624),control:CGPoint(x:171.9598388671875,y:104.31987304687499))
p.addQuadCurve(to:CGPoint(x:165.19969482421877,y:108.99993896484375),control:CGPoint(x:166.79973144531252,y:106.71989746093749))
p.addQuadCurve(to:CGPoint(x:163.59965820312502,y:115.120068359375),control:CGPoint(x:163.59965820312502,y:111.27998046875))
p.addQuadCurve(to:CGPoint(x:165.739697265625,y:121.86019287109374),control:CGPoint(x:163.59965820312502,y:119.200146484375))
p.addQuadCurve(to:CGPoint(x:171.47979736328125,y:125.88026123046876),control:CGPoint(x:167.879736328125,y:124.5202392578125))
p.addQuadCurve(to:CGPoint(x:179.23991699218752,y:127.240283203125),control:CGPoint(x:175.07985839843752,y:127.240283203125))
p.closeSubpath()
p.move(to:CGPoint(x:308.9996826171875,y:149.439990234375))
p.addQuadCurve(to:CGPoint(x:298.1595825195312,y:148.4599609375),control:CGPoint(x:303.839599609375,y:149.439990234375))
p.addQuadCurve(to:CGPoint(x:286.97958984375,y:144.57991943359377),control:CGPoint(x:292.4795654296875,y:147.479931640625))
p.addQuadCurve(to:CGPoint(x:276.6796630859375,y:136.2799560546875),control:CGPoint(x:281.4796142578125,y:141.6799072265625))
p.addLine(to:CGPoint(x:276.3596435546875,y:148.0))
p.addLine(to:CGPoint(x:249.00009765625,y:148.0))
p.addLine(to:CGPoint(x:249.00009765625,y:6.480004882812494))
p.addLine(to:CGPoint(x:277.0396484375,y:6.480004882812494))
p.addLine(to:CGPoint(x:277.0396484375,y:54.9201171875))
p.addQuadCurve(to:CGPoint(x:291.9396484375,y:44.280053710937494),control:CGPoint(x:283.0796142578125,y:47.7600830078125))
p.addQuadCurve(to:CGPoint(x:310.39970703125,y:40.80002441406249),control:CGPoint(x:300.7996826171875,y:40.80002441406249))
p.addQuadCurve(to:CGPoint(x:335.9397338867187,y:47.90002441406249),control:CGPoint(x:325.9197265625,y:40.80002441406249))
p.addQuadCurve(to:CGPoint(x:350.8597412109375,y:67.22001953124999),control:CGPoint(x:345.9597412109375,y:55.000024414062494))
p.addQuadCurve(to:CGPoint(x:355.7597412109375,y:95.1199951171875),control:CGPoint(x:355.7597412109375,y:79.4400146484375))
p.addQuadCurve(to:CGPoint(x:350.73973388671874,y:122.8999755859375),control:CGPoint(x:355.7597412109375,y:110.5999755859375))
p.addQuadCurve(to:CGPoint(x:335.4197143554687,y:142.31998291015623),control:CGPoint(x:345.7197265625,y:135.1999755859375))
p.addQuadCurve(to:CGPoint(x:308.9996826171875,y:149.439990234375),control:CGPoint(x:325.1197021484375,y:149.439990234375))
p.closeSubpath()
p.move(to:CGPoint(x:303.0399169921875,y:124.4803955078125))
p.addQuadCurve(to:CGPoint(x:318.1400512695312,y:120.08035888671876),control:CGPoint(x:312.7199951171875,y:124.4803955078125))
p.addQuadCurve(to:CGPoint(x:325.82014160156245,y:108.800244140625),control:CGPoint(x:323.560107421875,y:115.680322265625))
p.addQuadCurve(to:CGPoint(x:328.08017578125,y:94.5600341796875),control:CGPoint(x:328.08017578125,y:101.920166015625))
p.addQuadCurve(to:CGPoint(x:325.6401489257812,y:80.65980224609375),control:CGPoint(x:328.08017578125,y:87.1198974609375))
p.addQuadCurve(to:CGPoint(x:317.70006103515624,y:70.25965576171875),control:CGPoint(x:323.2001220703125,y:74.19970703125))
p.addQuadCurve(to:CGPoint(x:302.99990234375,y:66.3196044921875),control:CGPoint(x:312.2,y:66.3196044921875))
p.addQuadCurve(to:CGPoint(x:288.659765625,y:70.4396728515625),control:CGPoint(x:294.51982421875,y:66.3196044921875))
p.addQuadCurve(to:CGPoint(x:279.8396728515625,y:81.21983642578124),control:CGPoint(x:282.79970703125,y:74.5597412109375))
p.addQuadCurve(to:CGPoint(x:276.879638671875,y:95.360009765625),control:CGPoint(x:276.879638671875,y:87.87993164062499))
p.addQuadCurve(to:CGPoint(x:279.5796630859375,y:109.62020263671874),control:CGPoint(x:276.879638671875,y:102.9201171875))
p.addQuadCurve(to:CGPoint(x:288.0797485351562,y:120.40034179687501),control:CGPoint(x:282.2796875,y:116.3202880859375))
p.addQuadCurve(to:CGPoint(x:303.0399169921875,y:124.4803955078125),control:CGPoint(x:293.8798095703125,y:124.4803955078125))
p.closeSubpath()
p.move(to:CGPoint(x:403.2401123046875,y:149.439990234375))
p.addQuadCurve(to:CGPoint(x:389.2801147460938,y:147.47999267578126),control:CGPoint(x:395.9201171875,y:149.439990234375))
p.addQuadCurve(to:CGPoint(x:377.460107421875,y:141.55999755859375),control:CGPoint(x:382.64011230468753,y:145.5199951171875))
p.addQuadCurve(to:CGPoint(x:369.2401000976563,y:131.64000244140624),control:CGPoint(x:372.2801025390625,y:137.6))
p.addQuadCurve(to:CGPoint(x:366.20009765625,y:117.6400146484375),control:CGPoint(x:366.20009765625,y:125.6800048828125))
p.addQuadCurve(to:CGPoint(x:370.5800537109375,y:100.2801025390625),control:CGPoint(x:366.20009765625,y:106.840087890625))
p.addQuadCurve(to:CGPoint(x:382.41993408203126,y:90.360107421875),control:CGPoint(x:374.960009765625,y:93.7201171875))
p.addQuadCurve(to:CGPoint(x:399.4997680664063,y:85.82008056640625),control:CGPoint(x:389.87985839843753,y:87.00009765625))
p.addQuadCurve(to:CGPoint(x:419.51958007812505,y:84.64006347656249),control:CGPoint(x:409.11967773437505,y:84.64006347656249))
p.addLine(to:CGPoint(x:434.80021972656255,y:84.64006347656249))
p.addQuadCurve(to:CGPoint(x:432.7202026367188,y:74.3198486328125),control:CGPoint(x:434.80021972656255,y:78.7599365234375))
p.addQuadCurve(to:CGPoint(x:426.4201293945313,y:67.31971435546875),control:CGPoint(x:430.64018554687505,y:69.8797607421875))
p.addQuadCurve(to:CGPoint(x:415.6399658203125,y:64.75966796875),control:CGPoint(x:422.2000732421875,y:64.75966796875))
p.addQuadCurve(to:CGPoint(x:407.5798706054688,y:65.8396728515625),control:CGPoint(x:411.35991210937505,y:64.75966796875))
p.addQuadCurve(to:CGPoint(x:401.23979492187505,y:68.97969970703124),control:CGPoint(x:403.7998291015625,y:66.919677734375))
p.addQuadCurve(to:CGPoint(x:397.79973144531255,y:74.2397705078125),control:CGPoint(x:398.6797607421875,y:71.03972167968749))
p.addLine(to:CGPoint(x:369.400146484375,y:74.2397705078125))
p.addQuadCurve(to:CGPoint(x:375.0201416015625,y:59.17988281249999),control:CGPoint(x:370.68015136718753,y:65.47983398437499))
p.addQuadCurve(to:CGPoint(x:385.92010498046875,y:48.85996093749999),control:CGPoint(x:379.3601318359375,y:52.87993164062499))
p.addQuadCurve(to:CGPoint(x:400.36003417968755,y:42.88000488281249),control:CGPoint(x:392.48007812500003,y:44.839990234374994))
p.addQuadCurve(to:CGPoint(x:416.5999267578125,y:40.92001953124999),control:CGPoint(x:408.239990234375,y:40.92001953124999))
p.addQuadCurve(to:CGPoint(x:441.95988769531255,y:46.78002929687499),control:CGPoint(x:432.0399169921875,y:40.92001953124999))
p.addQuadCurve(to:CGPoint(x:456.7398315429688,y:63.860034179687496),control:CGPoint(x:451.87985839843753,y:52.640039062499994))
p.addQuadCurve(to:CGPoint(x:461.5998046875,y:91.239990234375),control:CGPoint(x:461.5998046875,y:75.080029296875))
p.addLine(to:CGPoint(x:461.5998046875,y:148.0))
p.addLine(to:CGPoint(x:436.36025390625,y:148.0))
p.addLine(to:CGPoint(x:435.9602294921875,y:134.360009765625))
p.addQuadCurve(to:CGPoint(x:424.70025634765625,y:144.6399658203125),control:CGPoint(x:431.08024902343755,y:141.4399658203125))
p.addQuadCurve(to:CGPoint(x:412.540234375,y:148.63997802734374),control:CGPoint(x:418.320263671875,y:147.8399658203125))
p.addQuadCurve(to:CGPoint(x:403.2401123046875,y:149.439990234375),control:CGPoint(x:406.760205078125,y:149.439990234375))
p.closeSubpath()
p.move(to:CGPoint(x:409.6399169921875,y:127.240283203125))
p.addQuadCurve(to:CGPoint(x:422.38010253906253,y:124.420263671875),control:CGPoint(x:416.6400390625,y:127.240283203125))
p.addQuadCurve(to:CGPoint(x:431.5801879882813,y:116.76018066406249),control:CGPoint(x:428.12016601562505,y:121.600244140625))
p.addQuadCurve(to:CGPoint(x:435.04020996093755,y:105.9599853515625),control:CGPoint(x:435.04020996093755,y:111.9201171875))
p.addLine(to:CGPoint(x:435.04020996093755,y:103.3998779296875))
p.addLine(to:CGPoint(x:411.519970703125,y:103.3998779296875))
p.addQuadCurve(to:CGPoint(x:405.4998901367188,y:103.85987548828125),control:CGPoint(x:408.63994140625005,y:103.3998779296875))
p.addQuadCurve(to:CGPoint(x:399.77978515625,y:105.51988525390624),control:CGPoint(x:402.35983886718753,y:104.31987304687499))
p.addQuadCurve(to:CGPoint(x:395.5996948242188,y:108.99993896484375),control:CGPoint(x:397.1997314453125,y:106.71989746093749))
p.addQuadCurve(to:CGPoint(x:393.999658203125,y:115.120068359375),control:CGPoint(x:393.999658203125,y:111.27998046875))
p.addQuadCurve(to:CGPoint(x:396.13969726562505,y:121.86019287109374),control:CGPoint(x:393.999658203125,y:119.200146484375))
p.addQuadCurve(to:CGPoint(x:401.8797973632812,y:125.88026123046876),control:CGPoint(x:398.279736328125,y:124.5202392578125))
p.addQuadCurve(to:CGPoint(x:409.6399169921875,y:127.240283203125),control:CGPoint(x:405.4798583984375,y:127.240283203125))
p.closeSubpath()
p.move(to:CGPoint(x:479.40009765625,y:148.0))
p.addLine(to:CGPoint(x:479.40009765625,y:42.599999999999994))
p.addLine(to:CGPoint(x:505.51970214843755,y:42.599999999999994))
p.addLine(to:CGPoint(x:507.03967285156256,y:54.760156249999994))
p.addQuadCurve(to:CGPoint(x:517.1396362304688,y:46.30010986328124),control:CGPoint(x:511.479638671875,y:49.3201416015625))
p.addQuadCurve(to:CGPoint(x:528.7196655273438,y:42.04005126953124),control:CGPoint(x:522.7996337890626,y:43.28007812499999))
p.addQuadCurve(to:CGPoint(x:539.4797607421875,y:40.80002441406249),control:CGPoint(x:534.639697265625,y:40.80002441406249))
p.addQuadCurve(to:CGPoint(x:563.0997802734375,y:47.44001464843749),control:CGPoint(x:554.519775390625,y:40.80002441406249))
p.addQuadCurve(to:CGPoint(x:575.3197875976564,y:65.15999755859374),control:CGPoint(x:571.6797851562501,y:54.08000488281249))
p.addQuadCurve(to:CGPoint(x:578.9597900390626,y:89.8),control:CGPoint(x:578.9597900390626,y:76.239990234375))
p.addLine(to:CGPoint(x:578.9597900390626,y:148.0))
p.addLine(to:CGPoint(x:550.9202392578126,y:148.0))
p.addLine(to:CGPoint(x:550.9202392578126,y:93.4400390625))
p.addQuadCurve(to:CGPoint(x:550.1402343750001,y:83.73985595703124),control:CGPoint(x:550.9202392578126,y:88.5599365234375))
p.addQuadCurve(to:CGPoint(x:547.260205078125,y:74.959716796875),control:CGPoint(x:549.3602294921875,y:78.91977539062499))
p.addQuadCurve(to:CGPoint(x:541.3601318359375,y:68.61962890625),control:CGPoint(x:545.1601806640625,y:70.999658203125))
p.addQuadCurve(to:CGPoint(x:531.3199951171875,y:66.23959960937499),control:CGPoint(x:537.5600830078125,y:66.23959960937499))
p.addQuadCurve(to:CGPoint(x:518.059814453125,y:70.23967285156249),control:CGPoint(x:523.4398925781251,y:66.23959960937499))
p.addQuadCurve(to:CGPoint(x:510.05969238281256,y:80.97987060546875),control:CGPoint(x:512.679736328125,y:74.23974609375))
p.addQuadCurve(to:CGPoint(x:507.43964843750007,y:96.0801513671875),control:CGPoint(x:507.43964843750007,y:87.7199951171875))
p.addLine(to:CGPoint(x:507.43964843750007,y:148.0))
p.closeSubpath()
return p.applying(CGAffineTransform(translationX:0,y:2).concatenating(CGAffineTransform(scaleX:rect.width/589.4,y:rect.height/152)))
 }
}

struct ReferenceCheckboxStyle:ToggleStyle {
    func makeBody(configuration:Configuration)->some View {
        Button{configuration.isOn.toggle()}label:{HStack(spacing:5){ZStack{RoundedRectangle(cornerRadius:3).fill(configuration.isOn ? Color(hex:0x0a7aff):.clear);if configuration.isOn{Image(systemName:"checkmark").font(.system(size:9,weight:.bold)).foregroundStyle(.white)}}.frame(width:13,height:13).overlay(RoundedRectangle(cornerRadius:3).stroke(configuration.isOn ? Color.clear:Color.gray.opacity(0.3),lineWidth:1));configuration.label}}.buttonStyle(.plain).accessibilityValue(configuration.isOn ? "включено":"выключено")
    }
}
extension ToggleStyle where Self==ReferenceCheckboxStyle {static var referenceCheckbox:Self{.init()}}
