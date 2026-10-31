//  Session+LookMatch.swift — pick a reference scan, fit Layer 2, write the
//  sidecar's grade, save that grade as a style.
//
//  Apply goes through `layerAdjustments`, which is the Post-Dev setter: on a
//  single frame it writes `sidecar.adjustments` and `scheduleSave()`; on a
//  half-frame pair it writes the picked frame's grade. It does not go through
//  the settings clipboard, and it does not touch `FilmParams`. While a batch
//  export is running the calls are no-ops, same as every other edit that
//  would move a frame out from under the writer (trap 34) — a grade written
//  mid-export is that frame's file with another frame's timing.

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum LookCompare: String, CaseIterable, Identifiable, Sendable {
    case split, overlay, histogram
    var id: String { rawValue }
}

@MainActor
@Observable
final class LookMatchController {
    var referenceName: String?
    var referenceSamples: [LookSample] = []
    var frameSamples: [LookSample] = []
    var frameBins: [Float] = []
    var referenceBins: [Float] = []
    var frameLuma: LookLumaImage?
    var referenceLuma: LookLumaImage?
    var overlayLuma: LookLumaImage?
    var proposal: LookAlignProposal?
    var status: String?
    var matchWhiteBalance = true
    var compare: LookCompare = .split
    var presets: [StylePreset] = []
    var presetName = ""

    var referenceGrid: LookFrameSampler.Grid?
    var frameGrid: LookFrameSampler.Grid?

    let storeURL: URL

    init(storeURL: URL = StylePresetStore.defaultURL) {
        self.storeURL = storeURL
        presets = StylePresetStore.load(from: storeURL)
    }

    func storeReference(_ grid: LookFrameSampler.Grid, name: String) {
        referenceGrid = grid
        referenceName = name
        referenceSamples = grid.samples
        referenceBins = LookMatch.histogramBins(referenceSamples)
        referenceLuma = LookFrameSampler.lumaImage(grid: grid, geometry: Geometry(), maxEdge: 160)
        proposal = nil
        refreshOverlay()
    }

    func storeFrame(_ grid: LookFrameSampler.Grid?, geometry: Geometry) {
        frameGrid = grid
        resampleFrame(geometry: geometry)
    }

    func resampleFrame(geometry: Geometry) {
        guard let grid = frameGrid else {
            frameSamples = []
            frameBins = []
            frameLuma = nil
            overlayLuma = nil
            return
        }
        // 24k is enough for three percentiles. A crop drag re-samples from the
        // grid already in memory; the texture is read again on Align.
        frameSamples = LookFrameSampler.samples(in: grid, geometry: geometry, maxSamples: 24_000)
        frameBins = LookMatch.histogramBins(frameSamples)
        frameLuma = LookFrameSampler.lumaImage(grid: grid, geometry: geometry, maxEdge: 160)
        refreshOverlay()
    }

    func clearReference() {
        referenceName = nil
        referenceGrid = nil
        referenceSamples = []
        referenceBins = []
        referenceLuma = nil
        overlayLuma = nil
        proposal = nil
        status = nil
    }

    private func refreshOverlay() {
        guard let frame = frameLuma, let reference = referenceLuma else { overlayLuma = nil; return }
        overlayLuma = LookMatch.averageLuma(frame, reference, width: 160, height: 100)
    }

    func remember(_ preset: StylePreset) throws {
        presets.append(preset)
        do { try StylePresetStore.save(presets, to: storeURL) }
        catch {
            presets.removeAll { $0.id == preset.id }
            throw error
        }
    }

    func removePreset(id: UUID) {
        let previous = presets
        presets.removeAll { $0.id == id }
        if (try? StylePresetStore.save(presets, to: storeURL)) == nil {
            presets = previous
        }
    }
}

extension Session {
    func chooseReferenceScan() {
        guard !batchExporting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadReferenceScan(from: url)
    }

    func loadReferenceScan(from url: URL) {
        guard !batchExporting else { return }
        do {
            let image = try ReferenceScan.load(url)
            lookMatch.storeReference(image.grid, name: url.lastPathComponent)
            lookMatch.status = nil
            refreshLookMatchFrame()
        } catch {
            lookMatch.status = L("Could not read that scan into the working space. Use a JPEG or TIFF.",
                                 zh: "无法把这张扫描读进工作色彩空间。请使用 JPEG 或 TIFF。")
        }
    }

    /// Re-read the print Layer 2 is about to grade, then sample it through
    /// the current crop. Called when the section appears, the frame changes,
    /// or Align is pressed — a crop drag only re-samples (`resampleLookMatchFrame`).
    func refreshLookMatchFrame() {
        guard let texture = renderer.graded, let grid = LookFrameSampler.read(texture) else {
            lookMatch.storeFrame(nil, geometry: geometry)
            return
        }
        lookMatch.storeFrame(grid, geometry: geometry)
    }

    func resampleLookMatchFrame() {
        lookMatch.resampleFrame(geometry: geometry)
    }

    func alignLookToReference() {
        guard !batchExporting else { return }
        guard selection != nil else {
            lookMatch.status = L("Open a frame first.", zh: "请先打开一张照片。")
            return
        }
        guard !lookMatch.referenceSamples.isEmpty else {
            lookMatch.status = L("Choose a reference scan first.", zh: "请先选择一张参考扫描。")
            return
        }
        refreshLookMatchFrame()
        guard lookMatch.frameSamples.count >= LookMatch.minimumSamples else {
            lookMatch.status = L("The print is not on the canvas yet, so there is nothing to align.",
                                 zh: "画布上还没有印片，无法对齐。")
            return
        }
        guard let proposal = LookMatch.propose(source: lookMatch.frameSamples,
                                               reference: lookMatch.referenceSamples,
                                               matchWhiteBalance: lookMatch.matchWhiteBalance) else {
            lookMatch.status = L("Not enough pixels to align.", zh: "像素不足以对齐。")
            return
        }
        lookMatch.proposal = proposal
        lookMatch.status = nil
    }

    /// Write the proposal into the open frame's Post-Dev grade and persist it.
    func applyLookProposal() {
        guard !batchExporting, selection != nil, let proposal = lookMatch.proposal else { return }
        layerAdjustments = proposal.applied(to: layerAdjustments)
    }

    /// The grade a new style should store: the proposal on top of the current
    /// grade when one is showing, otherwise the grade itself.
    func adjustmentsForStyle() -> Adjustments {
        if let proposal = lookMatch.proposal { return proposal.applied(to: layerAdjustments) }
        return layerAdjustments
    }

    func saveLookStyle() {
        guard !batchExporting, selection != nil else { return }
        guard let preset = StylePreset.make(name: lookMatch.presetName, adjustments: adjustmentsForStyle()) else {
            lookMatch.status = L("Name the style first.", zh: "请先为风格命名。")
            return
        }
        do {
            try lookMatch.remember(preset)
            lookMatch.presetName = ""
            lookMatch.status = nil
        } catch {
            lookMatch.status = L("Could not save the style.", zh: "无法保存风格。")
        }
    }

    func applyStylePreset(_ preset: StylePreset) {
        guard !batchExporting, selection != nil else { return }
        layerAdjustments = preset.adjustments
    }
}
