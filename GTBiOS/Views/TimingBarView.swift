import SwiftUI

/// A 9 bines timing hisztogram sáv (FOOT vagy HAND).
///
/// Megjelenítés:
/// - 9 téglalap egymás mellett, vízszintesen
/// - Magasságuk: bin értéke pixelsorokban (1 ütés = +1pt)
/// - Színek: bal (0–3) kék (siet), közép (4) zöld (tökéletes), jobb (5–8) sárga (késik)
/// - Utolsó ütés marker: fehér keret, váltakozó vékony/vastag
struct TimingBarView: View {

    let label: String
    let histogram: [Int]
    let lastBin: Int?
    let borderThick: Bool

    /// A sáv maximális magassága
    private let maxBarHeight: CGFloat = 200

    /// Bin színe az index alapján
    private func binColor(index: Int) -> Color {
        let binCount = histogram.count
        let centerBin = binCount / 2  // 4

        if index < centerBin {
            return .blue   // siet (bal oldal)
        } else if index == centerBin {
            return .green  // tökéletes (közép)
        } else {
            return .yellow // késik (jobb oldal)
        }
    }

    /// Bin magassága: a bin értéke pixelsorokban, max-ra clampelve
    private func barHeight(for value: Int) -> CGFloat {
        let height = CGFloat(value)
        return min(height, maxBarHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Sáv neve
            Text(label)
                .font(.headline)
                .foregroundColor(.white)

            // Hisztogram
            GeometryReader { geometry in
                let binCount = histogram.count
                let spacing: CGFloat = 2
                let totalSpacing = spacing * CGFloat(binCount - 1)
                let binWidth = (geometry.size.width - totalSpacing) / CGFloat(binCount)

                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(0..<binCount, id: \.self) { index in
                        let value = index < histogram.count ? histogram[index] : 0
                        let height = barHeight(for: value)
                        let isLastBin = (lastBin == index)

                        Rectangle()
                            .fill(binColor(index: index).opacity(0.8))
                            .frame(width: binWidth, height: max(height, 2))
                            .overlay(
                                // Fehér keret a legutolsó ütés bin-jén
                                Group {
                                    if isLastBin {
                                        RoundedRectangle(cornerRadius: 1)
                                            .stroke(Color.white, lineWidth: borderThick ? 3 : 1.5)
                                    }
                                }
                            )
                    }
                }
                .frame(height: geometry.size.height, alignment: .bottom)
            }
            .frame(height: maxBarHeight)

            // Skála jelzése
            HStack {
                Text("-50ms")
                    .font(.caption2)
                    .foregroundColor(.blue)
                Spacer()
                Text("0")
                    .font(.caption2)
                    .foregroundColor(.green)
                Spacer()
                Text("+50ms")
                    .font(.caption2)
                    .foregroundColor(.yellow)
            }
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - Preview

struct TimingBarView_Previews: PreviewProvider {
    static var previews: some View {
        TimingBarView(
            label: "FOOT",
            histogram: [2, 5, 8, 12, 20, 15, 10, 3, 1],
            lastBin: 4,
            borderThick: true
        )
        .background(Color.black)
        .previewLayout(.sizeThatFits)
    }
}
