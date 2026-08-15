import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Address/PSBT QR via CoreImage's CIQRCodeGenerator.
struct QRCodeView: View {
    let content: String

    private var image: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else {
            ContentUnavailableView("QR unavailable", systemImage: "qrcode")
        }
    }
}

/// A scrollable monospaced blob (address, descriptor, PSBT) with copy/share.
struct CopyableTextBlock: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            HStack {
                Button("Copy") { UIPasteboard.general.string = text }
                ShareLink(item: text)
            }
            .buttonStyle(.bordered)
        }
    }
}

/// A bundled design paper, rendered as plain text so Settings can open it offline.
struct DesignPaperView: View {
    let resource: String
    let title: String

    private var text: String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "The bundled copy of docs/\(resource).md could not be loaded." }
        return text
    }

    var body: some View {
        ScrollView {
            Text(text)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The bundled design paper (docs/read-side.md), rendered as plain text so
/// the esplora opt-in warning can link to it offline.
struct ReadSideDocumentView: View {
    var body: some View {
        NavigationStack {
            DesignPaperView(resource: "read-side", title: "The Read Side")
        }
    }
}

/// Index of the bundled design papers (docs/).
struct DesignPapersView: View {
    private struct Paper: Identifiable {
        var id: String { resource }
        let resource: String
        let title: String
        let blurb: String
    }

    private let papers: [Paper] = [
        Paper(resource: "mobile", title: "A phone wallet",
              blurb: "What the device forces, and what the product refuses."),
        Paper(resource: "read-side", title: "The read side",
              blurb: "How the phone learns which coins are its own."),
        Paper(resource: "write-side", title: "The write side",
              blurb: "Build, price, sign, and get a transaction out."),
        Paper(resource: "vaults", title: "Vaults",
              blurb: "Shared custody without a coordinator server."),
        Paper(resource: "import", title: "Import",
              blurb: "The bundle is the history. There is no back-scan."),
    ]

    var body: some View {
        NavigationStack {
            List(papers) { paper in
                NavigationLink {
                    DesignPaperView(resource: paper.resource, title: paper.title)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(paper.title)
                        Text(paper.blurb)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Design papers")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Sats with thousands separators plus the unit.
func satsText(_ amount: Int64) -> String {
    "\(amount.formatted()) sats"
}

/// A double sat/vB rate, trimmed of trailing zeros.
func feeRateText(_ rate: Double) -> String {
    "\(rate.formatted(.number.precision(.fractionLength(0 ... 2)))) sat/vB"
}
