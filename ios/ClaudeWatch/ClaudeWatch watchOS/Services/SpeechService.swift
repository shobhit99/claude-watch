import Foundation
import SwiftUI

// MARK: - SpeechService

/// Handles voice input on watchOS using the system dictation API.
/// The Speech framework (SFSpeechRecognizer) is NOT available on watchOS.
/// Instead, we use SwiftUI's `.dictationBehavior` or `WKInterfaceDevice` text input.
class SpeechService: ObservableObject {

    @Published var isRecording = false
    @Published var transcribedText = ""
    @Published var error: String? = nil

    /// Triggers watchOS system dictation via text input controller.
    /// On watchOS, voice input is handled by the OS — we present the system
    /// dictation UI and receive the transcribed text back.
    func startDictation(on device: Any? = nil) {
        isRecording = true
        transcribedText = ""
        error = nil
        // Actual dictation is triggered via the SwiftUI TextField with
        // .textContentType and the dictation button, or via
        // WKExtensionDelegate's presentTextInputController.
        // The VoiceInputView handles the UI; this service tracks state.
    }

    func finishDictation(with text: String) {
        transcribedText = text
        isRecording = false
    }

    func cancelDictation() {
        transcribedText = ""
        isRecording = false
    }

    func failDictation(message: String) {
        error = message
        isRecording = false
    }
}
