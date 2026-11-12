import SwiftUI
import UIKit
import WebKit

// Web respring method by @neonmodder123, implemented in Swift by @skadz108
// for Erosion (GPL-3.0-or-later). See NOTICE.md.
private let respringDocument = #"""
<!DOCTYPE html>
<html>
    <body>
        <iframe id="frame" srcdoc="" sandbox="allow-forms allow-modals allow-orientation-lock allow-pointer-lock allow-popups allow-presentation allow-scripts"></iframe>
        <script>
            const frame = document.getElementById('frame');
            const respringScript = `
                <html>
                <body>
                    <script>
                        const container = document.createElement('div');
                        container.style.cssText = 'perspective: 1px; perspective-origin: 9999999% 9999999%;';
                        document.body.appendChild(container);
                        for (let i = 0; i < 500; i++) {
                            let d = document.createElement('div');
                            d.style.cssText = 'position: absolute; width: 100vw; height: 100vh; backdrop-filter: blur(100px); -webkit-backdrop-filter: blur(100px); transform: translate3d(100000px, 100000px, ' + i + 'px) rotateY(90deg);';
                            container.appendChild(d);
                        }
                        setInterval(() => {
                            navigator.share({ title: 'R', text: 'R'.repeat(100000) }).catch(() => {});
                            let x = new Uint8Array(1024 * 1024 * 10);
                            crypto.getRandomValues(x);
                        }, 0);
                    <\/script>
                </body>
                </html>
            `;
            frame.srcdoc = respringScript;
        </script>
    </body>
</html>
"""#

struct RespringHTMLView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        WKWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(respringDocument, baseURL: nil)
    }
}

struct RespringButton: View {
    @Environment(\.appLanguage) private var language
    @State private var showConfirmation = false
    @State private var isActive = false

    var body: some View {
        Button {
            showConfirmation = true
        } label: {
            Label(language.text("respring.title"), systemImage: "arrow.triangle.2.circlepath")
        }
        .alert(language.text("respring.confirm_title"), isPresented: $showConfirmation) {
            Button(language.text("respring.confirm"), role: .destructive) {
                isActive = true
            }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("respring.confirm_message"))
        }
        .fullScreenCover(isPresented: $isActive) {
            RespringHTMLView()
                .ignoresSafeArea()
                .opacity(0.02)
                .contentShape(Rectangle())
                .onTapGesture {
                    isActive = false
                }
                .onAppear {
                    // If the WebKit method is unsupported, never leave the user
                    // on an invisible full-screen cover.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        isActive = false
                    }
                }
        }
    }
}