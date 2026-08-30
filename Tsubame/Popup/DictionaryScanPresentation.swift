import Foundation
import Observation
import TsubameCore

struct DictionaryScanSection: Sendable, Equatable, Identifiable {
    let group: DictionaryScanGroup
    let alternatives: [DictionaryScanGroup]

    var id: UTF8TextRange { group.sourceRange }
}

struct DictionaryScanPresentation: Sendable, Equatable {
    let sections: [DictionaryScanSection]

    init(result: DictionaryScanResult) {
        let orderedGroups = result.groups
            .filter { $0.sourceRange.start < $0.sourceRange.end && !$0.entries.isEmpty }
            .sorted(by: Self.groupOrder)
        var primaryGroups: [DictionaryScanGroup] = []
        var coveredUntil: Int?

        for group in orderedGroups {
            if let coveredUntil, group.sourceRange.start < coveredUntil {
                continue
            }
            primaryGroups.append(group)
            coveredUntil = group.sourceRange.end
        }

        let primaryRanges = Set(primaryGroups.map(\.sourceRange))
        var alternativesByPrimaryRange: [UTF8TextRange: [DictionaryScanGroup]] = [:]
        for group in orderedGroups where !primaryRanges.contains(group.sourceRange) {
            guard let primary = primaryGroups.max(by: {
                let lhsOverlap = overlapLength($0.sourceRange, group.sourceRange)
                let rhsOverlap = overlapLength($1.sourceRange, group.sourceRange)
                if lhsOverlap != rhsOverlap { return lhsOverlap < rhsOverlap }
                return $0.sourceRange.start > $1.sourceRange.start
            }), overlapLength(primary.sourceRange, group.sourceRange) > 0 else {
                continue
            }
            alternativesByPrimaryRange[primary.sourceRange, default: []].append(group)
        }

        sections = primaryGroups.map { group in
            DictionaryScanSection(
                group: group,
                alternatives: alternativesByPrimaryRange[group.sourceRange] ?? []
            )
        }
    }

    var entryCount: Int {
        sections.lazy.map(\.group.entries.count).reduce(0, +)
    }

    var isEmpty: Bool {
        sections.isEmpty
    }

    private static func groupOrder(
        _ lhs: DictionaryScanGroup,
        _ rhs: DictionaryScanGroup
    ) -> Bool {
        if lhs.sourceRange.start != rhs.sourceRange.start {
            return lhs.sourceRange.start < rhs.sourceRange.start
        }
        return lhs.sourceRange.end > rhs.sourceRange.end
    }
}

@MainActor
@Observable
final class DictionaryScanDeckModel {
    private(set) var requestID: UInt64?
    private(set) var selectedSectionID: UTF8TextRange?

    func begin(requestID: UInt64, scan: DictionaryScanPresentation) {
        let isNewRequest = self.requestID != requestID
        self.requestID = requestID
        if isNewRequest || !scan.sections.contains(where: { $0.id == selectedSectionID }) {
            selectedSectionID = scan.sections.first?.id
        }
    }

    func select(
        _ sectionID: UTF8TextRange,
        in scan: DictionaryScanPresentation
    ) {
        guard scan.sections.contains(where: { $0.id == sectionID }) else { return }
        selectedSectionID = sectionID
    }

    func move(by offset: Int, in scan: DictionaryScanPresentation) {
        guard !scan.sections.isEmpty else {
            selectedSectionID = nil
            return
        }
        let currentIndex = selectedIndex(in: scan) ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), scan.sections.count - 1)
        selectedSectionID = scan.sections[nextIndex].id
    }

    func selectedIndex(in scan: DictionaryScanPresentation) -> Int? {
        guard let selectedSectionID else { return nil }
        return scan.sections.firstIndex { $0.id == selectedSectionID }
    }
}

private func overlapLength(_ lhs: UTF8TextRange, _ rhs: UTF8TextRange) -> Int {
    max(0, min(lhs.end, rhs.end) - max(lhs.start, rhs.start))
}
