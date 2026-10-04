import SwiftUI
import KabanBoardCore

/// Approved tokens.css v0.2.1. Native system typography and materials follow macOS appearance.
enum DesignSystem {
    static let cardRadius: CGFloat = 10
    static let panelRadius: CGFloat = 14
    static func color(_ tone: CardPresentation.Tone) -> Color {
        switch tone {
        case .queued: Color(hex: 0x8e8e93)
        case .running: Color(hex: 0x0a7aff)
        case .gating: Color(hex: 0x5e5ce6)
        case .retry: Color(hex: 0xe0a800)
        case .waiting: Color(hex: 0xff8a00)
        case .review: Color(hex: 0x12a5b8)
        case .paused: Color(hex: 0x7d8796)
        case .blocked: Color(hex: 0xa2845e)
        case .incident: Color(hex: 0xe5251b)
        case .done: Color(hex: 0x30b553)
        case .cancelled: Color(hex: 0xa4a6ad)
        }
    }
}
