import Foundation
import Testing
@testable import PaellaCore

private func proc(_ pid: Int32, _ path: String, cpu: Double, gpu: Double? = 0) -> ProcessSample {
    ProcessSample(key: ProcessKey(pid: pid, start: 1), name: (path as NSString).lastPathComponent, path: path, cpu: cpu, gpu: gpu)
}


@Test func groupsHelpersWithOutermostAppAndAppliesExclusions() {
    let samples = [
        proc(1, "/Applications/LM Studio.app/Contents/MacOS/LM Studio", cpu: 0.3),
        proc(2, "/Applications/LM Studio.app/Contents/Frameworks/LM Studio Helper.app/Contents/MacOS/LM Studio Helper", cpu: 0.6),
        proc(3, "/opt/homebrew/bin/ffmpeg", cpu: 3.5),
        proc(4, "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", cpu: 2), // protected
        proc(5, "/Applications/Safari.app/Contents/MacOS/Safari", cpu: 1.5),             // frontmost
        proc(6, "/usr/local/bin/ollama", cpu: 0.1, gpu: 0.7),                              // GPU-heavy
        proc(7, "/usr/bin/python3", cpu: 0.5),                                             // below threshold
    ]
    var p = SelectionPolicy()
    p.excludedBundlePaths = ["/Applications/Safari.app"]
    let groups = TargetSelector.groups(samples)
    #expect(groups.first?.name == "ffmpeg") // most demanding first
    #expect(groups.first { $0.name == "Finder" }?.isProtected == true)
    var names = Set(TargetSelector.select(groups, policy: p).map(\.name))
    #expect(names == ["LM Studio", "ffmpeg", "ollama"])

    p.exclusions = ["FFMPEG", "ollama"]
    names = Set(TargetSelector.select(groups, policy: p).map(\.name))
    #expect(names == ["LM Studio"])
}

@Test func throttledGroupsAreSticky() {
    let starved = [proc(3, "/opt/homebrew/bin/ffmpeg", cpu: 0.01)]
    var p = SelectionPolicy()
    let groups = TargetSelector.groups(starved)
    #expect(TargetSelector.select(groups, policy: p).isEmpty)
    p.activeGroups = ["3-1"]
    #expect(TargetSelector.select(groups, policy: p).map(\.name) == ["ffmpeg"])
}
