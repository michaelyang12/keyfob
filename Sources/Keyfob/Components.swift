import SwiftUI

struct Monogram: View {
    let name: String
    var size: CGFloat = 28

    private static let palette: [Color] = [
        .blue, .purple, .pink, .red, .orange, .yellow, .green, .mint, .teal, .cyan, .indigo, .brown,
    ]

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Self.color(for: name).gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(name.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.12), radius: size * 0.04, y: size * 0.02)
    }

    static func color(for name: String) -> Color {
        var h: UInt32 = 5381
        for byte in name.lowercased().utf8 { h = (h &<< 5) &+ h &+ UInt32(byte) }
        return palette[Int(h % UInt32(palette.count))]
    }
}

extension Token.Expiry {
    var tint: Color {
        self == .expired ? .red : .orange
    }
}
