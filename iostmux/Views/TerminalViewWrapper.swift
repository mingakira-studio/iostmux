import SwiftUI
import SwiftTerm

struct TerminalViewWrapper: UIViewRepresentable {
    let onTerminalCreated: (TerminalView) -> Void
    var onUserInput: (([UInt8]) -> Void)?
    var onSizeChanged: ((Int, Int) -> Void)?

    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.nativeForegroundColor = .white
        tv.nativeBackgroundColor = .black
        tv.terminalDelegate = context.coordinator
        onTerminalCreated(tv)
        return tv
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.onUserInput = onUserInput
        c.onSizeChanged = onSizeChanged
        return c
    }

    class Coordinator: NSObject, TerminalViewDelegate {
        var onUserInput: (([UInt8]) -> Void)?
        var onSizeChanged: ((Int, Int) -> Void)?

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onUserInput?(Array(data))
        }

        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func bell(source: TerminalView) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            onSizeChanged?(newCols, newRows)
        }

        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    }
}
