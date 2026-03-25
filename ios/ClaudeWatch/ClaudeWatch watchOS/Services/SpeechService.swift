import Foundation
import Speech
import SwiftUI

// MARK: - SpeechService

/// Wraps SFSpeechRecognizer for on-device transcription on watchOS.
class SpeechService: ObservableObject {

    @Published var isRecording = false
    @Published var transcribedText = ""
    @Published var error: String? = nil

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    #if os(watchOS)
    // watchOS does not use AVAudioEngine for speech; it uses the built-in
    // dictation or an audio session approach. For V1 we use the simplified path.
    #endif

    // MARK: - Permissions

    private func requestPermissions(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    completion(true)
                case .denied:
                    self.error = "Speech recognition denied. Enable in Settings."
                    completion(false)
                case .restricted:
                    self.error = "Speech recognition restricted on this device."
                    completion(false)
                case .notDetermined:
                    self.error = "Speech recognition not determined."
                    completion(false)
                @unknown default:
                    self.error = "Unknown speech authorization status."
                    completion(false)
                }
            }
        }
    }

    // MARK: - Recording

    func startRecording() {
        // Reset state
        transcribedText = ""
        error = nil

        requestPermissions { [weak self] authorized in
            guard let self, authorized else { return }
            self.beginRecognition()
        }
    }

    private func beginRecognition() {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            error = "Speech recognizer unavailable."
            return
        }

        // Cancel any existing task
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        // Prefer on-device recognition when available
        if speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        recognitionRequest = request

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            DispatchQueue.main.async {
                if let result {
                    self.transcribedText = result.bestTranscription.formattedString

                    if result.isFinal {
                        self.isRecording = false
                        self.cleanupRecognition()
                    }
                }

                if let error {
                    // Ignore cancellation errors
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                        // "All" recognition request was canceled -- expected on stop
                        return
                    }
                    self.error = error.localizedDescription
                    self.isRecording = false
                    self.cleanupRecognition()
                }
            }
        }

        isRecording = true
    }

    func stopRecording() {
        recognitionRequest?.endAudio()
        isRecording = false
    }

    private func cleanupRecognition() {
        recognitionRequest = nil
        recognitionTask = nil
    }
}
