import SwiftUI

struct ReferenceQuotaBars: View {
    let theme: ReferenceTheme
    var compact = false
    var unknown = false
    var cm:Double? = 46
    var om:Double? = 100
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(spacing:6){Label("Квота Cursor",systemImage:"gauge.with.dots.needle.50percent").font(.system(size:11));ReferenceChip(title:"неофициально",theme:theme)}.foregroundStyle(theme.secondary)
            ForEach(["Cm","Om"],id:\.self){pool in
                HStack(spacing:6){Text(pool).font(.system(size:10,weight:.bold)).foregroundStyle(theme.secondary).frame(width:22,alignment:.leading)
                    GeometryReader{g in
                        ZStack(alignment:.leading){RoundedRectangle(cornerRadius:4).fill(theme.control);if !unknown,let percent=pool=="Cm" ? cm:om {RoundedRectangle(cornerRadius:4).fill(theme.status(pool=="Cm" ? "gating":"waiting").0).frame(width:g.size.width * percent/100);theme.text.opacity(0.55).frame(width:1.5,height:13).offset(x:g.size.width * 0.57);theme.status("waiting").0.frame(width:1,height:13).offset(x:g.size.width * 0.9)}}.overlay(RoundedRectangle(cornerRadius:4).stroke(theme.line,style:StrokeStyle(lineWidth:0.5,dash:unknown ? [3,2]:[])))
                    }.frame(height:7)
                    Text(unknown || (pool=="Cm" ? cm:om)==nil ? "нет данных":"\(Int((pool=="Cm" ? cm:om) ?? 0))% · 13д 13ч").font(.system(size:10.5,weight:pool=="Om" ? .semibold:.regular)).foregroundStyle(pool=="Om" && !unknown ? theme.status("waiting").2:theme.secondary).frame(width:compact ? 87:120,alignment:.trailing)
                }
            }
            HStack{Text("┃цикл  ┆порог 10%");Spacer();Text(unknown ? "—":"2 мин назад")}.font(.system(size:9.5)).foregroundStyle(theme.faint)
        }
    }
}
