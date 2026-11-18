import SwiftUI

struct Monogram: View {
    let name: String
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Self.color(for: name).gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(name.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
    }

    static func color(for name: String) -> Color {
        var h: UInt32 = 5381
        for byte in name.lowercased().utf8 { h = (h &<< 5) &+ h &+ UInt32(byte) }
        return Color(hue: Double(h % 360) / 360, saturation: 0.5, brightness: 0.78)
    }
}

struct ExpiryBadge: View {
    let expiry: Token.Expiry

    var body: some View {
        switch expiry {
        case .expired: badge("Expired", .red)
        case .soon(let days): badge(days == 0 ? "Expires today" : "\(days)d left", .orange)
        case .none, .valid: EmptyView()
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct TagChip: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }
}

struct KeyHint: View {
    let keys: String
    let label: String

    init(_ keys: String, _ label: String) {
        self.keys = keys
        self.label = label
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
        }
        .foregroundStyle(.secondary)
    }
}
