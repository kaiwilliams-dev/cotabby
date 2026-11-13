import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Lets the writer take back an automatic typo fix with the very next key. `applyAutomaticCorrection`
/// records the fix in `AutoCorrectionUndoState`; every later key event passes through
/// `noteInputForAutoCorrectionUndo` first, so the decision is made on the first key after the fix and
/// never later (a fix the writer typed past is theirs to keep).
///
/// Two gestures revert it:
/// - **Backspace**: the host deletes the delimiter as usual, then Cotabby swaps the corrected word
///   back for the letters the writer typed. This mirrors iOS: Backspace after autocorrect gives the
///   original word back with the caret still at its end, ready to be edited by hand.
/// - **Cmd+Z**: the host runs its own undo (Cotabby cannot swallow the key from the listen-only tap);
///   Cotabby only records the rejection so the next prediction cycle does not instantly re-apply the
///   same fix to the restored text.
///
/// Either gesture adds the typo to the session's rejected set, so that exact misspelling is offered
/// (green, Tab to accept) instead of rewritten for the rest of the session.
extension SuggestionCoordinator {
    func noteInputForAutoCorrectionUndo(_ event: CapturedInputEvent) {
        guard autoCorrectionUndo.pending != nil else { return }
        guard let entry = autoCorrectionUndo.undoableEntry(at: ProcessInfo.processInfo.systemUptime) else {
            autoCorrectionUndo.settle()
            return
        }

        let isPlainBackspace = event.keyCode == 51
            && !event.flags.contains(.maskCommand) && !event.flags.contains(.maskAlternate)
        let isUndoShortcut = event.keyCode == 6
            && event.flags.contains(.maskCommand) && !event.flags.contains(.maskShift)

        if isPlainBackspace {
            revertAutomaticCorrection(entry)
        } else if isUndoShortcut {
            autoCorrectionUndo.recordRejection(of: entry.typo)
            CotabbyLogger.suggestion.debug("Automatic correction undone by Cmd+Z; typo will no longer auto-fix")
        } else {
            autoCorrectionUndo.settle()
        }
    }

    /// Swaps the corrected word back for the typed one after the host has handled the Backspace.
    ///
    /// The delay lets the host apply the real Backspace first (it removed the last delimiter
    /// character), so the text then reads `corrected + delimiter.dropLast()`. Replacing that run with
    /// `typo + delimiter.dropLast()` leaves the writer exactly where they were before the fix, minus
    /// the character their Backspace removed.
    private func revertAutomaticCorrection(_ entry: AutoCorrectionUndoState.Entry) {
        autoCorrectionUndo.recordRejection(of: entry.typo)
        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: false)
        hideOverlay(reason: "Overlay hidden because the automatic correction was undone.")

        let remainingDelimiter = String(entry.delimiter.dropLast())
        let deletingUTF16Count = (entry.correction + remainingDelimiter).utf16.count
        let restored = entry.typo + remainingDelimiter
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self else { return }
            if suggestionInserter.replace(deletingUTF16Count: deletingUTF16Count, with: restored) {
                focusModel.invalidateTransientCaretCaches()
                CotabbyLogger.suggestion.debug("Automatic correction undone by Backspace")
            } else {
                CotabbyLogger.suggestion.error("Could not restore the typed word after Backspace")
            }
        }
    }
}

extension SuggestionCoordinator {
    /// The settings a *request* is built from: the live snapshot plus a short note of the writer's own
    /// names, jargon and repeated phrases (`PersonalVocabulary.promptNote`). Added here rather than in
    /// the stored snapshot so the snapshot's equality (which drives settings-change resets) is
    /// untouched and a changed vocabulary file is picked up on the next request.
    var requestSettings: SuggestionSettingsSnapshot {
        guard let note = spellChecker.personalVocabulary().promptNote() else { return settingsSnapshot }
        var augmented = settingsSnapshot
        augmented.extendedContext = augmented.extendedContext.isEmpty
            ? note : augmented.extendedContext + "\n" + note
        return augmented
    }
}
