//  LookMatchSection.swift — Post-Dev: match a reference scan with Layer 2.
//
//  The compare is not `CompareOverlay`. That overlay is the before/after of
//  one frame (decode against print) and both halves are sampled through the
//  frame's crop. A reference scan is a different picture; putting it in that
//  split would crop the scan with the photograph and replace Original.
//  Histograms reuse `HistogramPlot`. The split and the overlay are working-
//  space luma — encoded ProPhoto luma drawn as grey — so the compare is not
//  a ProPhoto buffer tagged as sRGB (trap 27). The caption says which.
//
//  The frame's histogram and luma are the cropped print, before Layer 2.
//  The canvas histogram still counts the uncropped print; this one does not.

import AppKit
import SwiftUI

struct LookMatchSection: View {
    @Bindable var session: Session

    var body: some View {
        let look = session.lookMatch
        PanelSection(L("Match Scan", zh: "匹配扫描"), key: "lookmatch", initiallyExpanded: false,
                     menu: { AnyView(Button(L("Clear reference", zh: "清除参考")) { session.lookMatch.clearReference() }) },
                     metrics: .right,
                     foldedNote: look.referenceName) {
            RailRows {
                Text(L("Fits black, white and mid-grey on the print with Exposure, Black and White. Film and paper are not changed.",
                       zh: "用曝光、黑场和白场把印片的黑、白、中灰对齐参考。不改胶片和相纸。"))
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                lookButton(L("Choose Reference…", zh: "选择参考…"), disabled: session.batchExporting,
                           action: { session.chooseReferenceScan() })

                if let name = look.referenceName {
                    Text(name)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if look.referenceLuma != nil || look.frameLuma != nil {
                    SegmentedSwitch(options: LookCompare.allCases,
                                    selection: Binding(get: { look.compare }, set: { session.lookMatch.compare = $0 }),
                                    title: { compareTitle($0) })
                    compareBody(look)
                    Text(L("Working-space luma (ProPhoto γ1.8), inside the crop. Not a colour preview.",
                           zh: "工作空间亮度（ProPhoto γ1.8），裁切之内。不是色彩预览。"))
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !look.frameBins.isEmpty {
                    Text(L("This frame", zh: "当前画面")).font(Theme.Font.small).foregroundStyle(Theme.Ink.secondary)
                    HistogramPlot(bins: look.frameBins, channels: [.rgb], showGrid: false, lineWidth: 1)
                        .frame(height: 48)
                }
                if !look.referenceBins.isEmpty {
                    Text(L("Reference", zh: "参考")).font(Theme.Font.small).foregroundStyle(Theme.Ink.secondary)
                    HistogramPlot(bins: look.referenceBins, channels: [.rgb], showGrid: false, lineWidth: 1)
                        .frame(height: 48)
                }

                HStack(spacing: 4) {
                    Text(L("White balance", zh: "白平衡")).font(Theme.Font.small).foregroundStyle(Theme.Ink.secondary)
                    CheckBox(isOn: Binding(get: { look.matchWhiteBalance },
                                          set: { session.lookMatch.matchWhiteBalance = $0 }))
                    Spacer(minLength: 0)
                }

                lookButton(L("Align black, white, mid-grey", zh: "对齐黑、白、中灰"),
                           disabled: session.batchExporting || look.referenceSamples.isEmpty || session.selection == nil,
                           action: { session.alignLookToReference() })

                if let proposal = look.proposal {
                    proposalReadout(proposal)
                    if LookMatch.unmodeledTone(session.layerAdjustments) {
                        Text(L("Contrast, curves, colour balance and vignette stay as they are. Reset them if the match should land on the picture you see.",
                               zh: "对比度、曲线、色彩平衡和暗角保持原样。若要让匹配落在你看到的画面上，请先重置它们。"))
                            .font(Theme.Font.meta)
                            .foregroundStyle(Theme.Ink.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if proposal.largestError > 0.03 {
                        Text(L("These three controls cannot hit black, white and mid-grey all at once. This is the closest.",
                               zh: "这三个控件无法同时命中黑、白和中灰。这是最接近的结果。"))
                            .font(Theme.Font.meta)
                            .foregroundStyle(Theme.Ink.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    lookButton(L("Apply to this frame", zh: "应用到当前画面"),
                               disabled: session.batchExporting || session.selection == nil,
                               action: { session.applyLookProposal() })
                }

                TextField(L("Style name", zh: "风格名称"), text: Binding(get: { look.presetName },
                                                                       set: { session.lookMatch.presetName = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.small)
                lookButton(L("Save style", zh: "保存风格"),
                           disabled: session.batchExporting || session.selection == nil,
                           action: { session.saveLookStyle() })

                if !look.presets.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(look.presets) { preset in
                                HStack(spacing: 6) {
                                    Text(preset.name)
                                        .font(Theme.Font.small)
                                        .foregroundStyle(Theme.Ink.primary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Button(L("Apply", zh: "应用")) { session.applyStylePreset(preset) }
                                        .controlSize(.small)
                                        .disabled(session.batchExporting || session.selection == nil)
                                    Button(L("Delete", zh: "删除")) { session.lookMatch.removePreset(id: preset.id) }
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }

                if let status = look.status {
                    Text(status)
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear { session.refreshLookMatchFrame() }
            .onChange(of: session.geometry) { _, _ in
                session.resampleLookMatchFrame()
            }
        }
        .onChange(of: session.selection) { _, _ in
            // The proposal belonged to the frame that was open. Re-read only
            // while the section is open; a collapsed section stays out of the
            // crop drag and out of the texture read.
            session.lookMatch.proposal = nil
            if Self.sectionIsOpen {
                session.refreshLookMatchFrame()
            } else {
                session.lookMatch.storeFrame(nil, geometry: session.geometry)
            }
        }
    }

    /// `PanelSection` persists this under `ui2.section.lookmatch`. Absent
    /// means collapsed, which is the initial state.
    private static var sectionIsOpen: Bool {
        (UserDefaults.standard.object(forKey: Session.uiKey + "section.lookmatch") as? Bool) ?? false
    }

    @ViewBuilder private func compareBody(_ look: LookMatchController) -> some View {
        switch look.compare {
        case .split:
            HStack(spacing: 4) {
                LumaPictureView(image: look.frameLuma)
                LumaPictureView(image: look.referenceLuma)
            }
            .frame(height: 72)
        case .overlay:
            LumaPictureView(image: look.overlayLuma)
                .frame(height: 72)
        case .histogram:
            EmptyView()
        }
    }

    private func proposalReadout(_ p: LookAlignProposal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "Exposure %+.2f", p.exposure))
            Text(String(format: "Black %.1f    White %.1f", p.blackPoint, p.whitePoint))
            if p.matchedWhiteBalance {
                Text(String(format: "Temp. %+.0f    Tint %+.0f", p.temperature, p.tint))
            }
            Text(String(format: "Δ black %.3f · mid %.3f · white %.3f", p.blackError, p.midError, p.whiteError))
        }
        .font(Theme.Font.value)
        .foregroundStyle(Theme.Ink.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A plain button whose label wraps. A bordered control reports its
    /// title's one-line width as the rail's minimum, which is what pushes
    /// the Parameters rail past its narrowest (`PanelResizeWiringTests`).
    private func lookButton(_ title: String, disabled: Bool, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.small)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Theme.Ink.tertiary : Theme.accent)
        .disabled(disabled)
    }

    private func compareTitle(_ mode: LookCompare) -> String {
        switch mode {
        case .split: L("Split", zh: "并排")
        case .overlay: L("Overlay", zh: "叠加")
        case .histogram: L("Histogram", zh: "直方图")
        }
    }
}

/// Encoded working-space luma as a grey image. The code value is the luma,
/// drawn in a grey space so the strip can be seen; it is not a colour-managed
/// preview of the print.
private struct LumaPictureView: View {
    var image: LookLumaImage?

    var body: some View {
        if let cg = image.flatMap(Self.make) {
            Image(decorative: cg, scale: 1)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            RoundedRectangle(cornerRadius: 2).fill(Theme.plot)
        }
    }

    private static func make(_ image: LookLumaImage) -> CGImage? {
        guard image.width > 0, image.height > 0, image.values.count == image.width * image.height,
              let space = CGColorSpace(name: CGColorSpace.linearGray) else { return nil }
        let bytes = Data(image.values.map { UInt8(min(255, max(0, Int(($0 * 255).rounded())))) })
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        // 8-bit gray, no alpha. The provider copies, so the Data can go.
        return CGImage(width: image.width, height: image.height,
                       bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: image.width,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
