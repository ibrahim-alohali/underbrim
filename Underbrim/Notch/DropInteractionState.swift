//
//  DropInteractionState.swift
//  Underbrim
//

import Observation

@Observable
final class DropInteractionState {
    var dragDetectorTargeting = false
    var dropZoneTargeting = false
    var dropEvent = false
    /// A file drag came near the notch and hasn't ended: stay open for all of it.
    var dragSession = false

    var anyDropZoneTargeting: Bool {
        dragDetectorTargeting || dropZoneTargeting
    }
}
