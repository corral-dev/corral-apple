#if os(iOS)
import SwiftUI

struct TerminalGridView: View {
    @Bindable var store: TerminalStore
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var magnifyBy: CGFloat = 1
    @GestureState private var dragOffset: CGSize = .zero

    private let cellWidth: CGFloat = 8
    private let cellHeight: CGFloat = 16

    var body: some View {
        Group {
            if let loadError = store.loadError, !store.hasFrame {
                ContentUnavailableView {
                    Label("terminal.load_failed.title", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("action.retry") {
                        Task { await store.retry() }
                    }
                }
            } else if store.isLoading, !store.hasFrame {
                ProgressView()
            } else {
                terminalCanvas
            }
        }
    }

    private var terminalCanvas: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                Canvas { context, _ in
                    let fontSize: CGFloat = 13
                    for (rowIndex, row) in store.cells.enumerated() {
                        for (colIndex, cell) in row.enumerated() {
                            var fg = cell.fg.swiftUIColor(isForeground: true)
                            var bg = cell.bg.swiftUIColor(isForeground: false)
                            if cell.reverse { swap(&fg, &bg) }
                            if cell.dim { fg = fg.opacity(0.65) }

                            let x = CGFloat(colIndex) * cellWidth
                            let y = CGFloat(rowIndex) * cellHeight
                            let rect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
                            if cell.needsBackgroundFill {
                                context.fill(Path(rect), with: .color(bg))
                            }

                            if cell.needsGlyphDraw {
                                let font: Font = cell.bold
                                    ? .system(size: fontSize, weight: .bold, design: .monospaced)
                                    : .system(size: fontSize, design: .monospaced)
                                let text = Text(String(cell.char))
                                    .font(font)
                                    .foregroundColor(fg)
                                context.draw(text, at: CGPoint(x: rect.minX, y: rect.minY), anchor: .topLeading)
                            }
                            if cell.underline {
                                var path = Path()
                                path.move(to: CGPoint(x: rect.minX, y: rect.maxY - 1))
                                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 1))
                                context.stroke(path, with: .color(fg), lineWidth: 1)
                            }
                        }
                    }
                    if store.cursorVisible,
                       store.cursorY < store.rows,
                       store.cursorX < store.cols {
                        let x = CGFloat(store.cursorX) * cellWidth
                        let y = CGFloat(store.cursorY) * cellHeight
                        let rect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
                        context.stroke(Path(rect), with: .color(.white.opacity(0.85)), lineWidth: 1)
                    }
                }
                .frame(
                    width: max(CGFloat(store.cols) * cellWidth, geo.size.width),
                    height: max(CGFloat(store.rows) * cellHeight, geo.size.height)
                )
                .background(Palette.terminalBackground)
                .scaleEffect(scale * magnifyBy, anchor: .topLeading)
                .offset(
                    x: offset.width + dragOffset.width,
                    y: offset.height + dragOffset.height
                )
                .gesture(
                    MagnificationGesture()
                        .updating($magnifyBy) { value, state, _ in state = value }
                        .onEnded { value in scale = min(max(scale * value, 0.5), 3) }
                )
                .simultaneousGesture(
                    DragGesture()
                        .updating($dragOffset) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            offset.width += value.translation.width
                            offset.height += value.translation.height
                        }
                )
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }
}

private extension TerminalColor {
    func swiftUIColor(isForeground: Bool) -> Color {
        if raw == -1 {
            return isForeground ? Color(white: 0.88) : Color(red: 0.08, green: 0.09, blue: 0.12)
        }
        // 真彩色：0x1000000 | r<<16 | g<<8 | b
        if raw & 0x1000000 != 0 {
            let r = Double((raw >> 16) & 0xFF) / 255
            let g = Double((raw >> 8) & 0xFF) / 255
            let b = Double(raw & 0xFF) / 255
            return Color(red: r, green: g, blue: b)
        }
        // 256 色：简单分档，够用即可
        switch raw {
        case 0: return Color(red: 0.12, green: 0.12, blue: 0.14)
        case 1: return .red
        case 2: return .green
        case 3: return .yellow
        case 4: return .blue
        case 5: return .purple
        case 6: return .cyan
        case 7: return Color(white: 0.85)
        case 8: return Color(white: 0.45)
        case 9: return Color(red: 1, green: 0.4, blue: 0.4)
        case 10: return Color(red: 0.4, green: 1, blue: 0.4)
        case 11: return Color(red: 1, green: 1, blue: 0.4)
        case 12: return Color(red: 0.4, green: 0.6, blue: 1)
        case 13: return Color(red: 1, green: 0.4, blue: 1)
        case 14: return Color(red: 0.4, green: 1, blue: 1)
        case 15: return .white
        default:
            let level = max(0, min(255, raw))
            let gray = Double(level) / 255
            return Color(white: gray)
        }
    }
}
#endif
