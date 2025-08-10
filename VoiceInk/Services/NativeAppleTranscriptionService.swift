import Foundation
import AVFoundation
import os

#if canImport(Speech)
import Speech
#endif

/// Transcription service using Apple's native Speech framework (SFSpeechRecognizer).
/// This avoids newer APIs (SpeechAnalyzer / SpeechTranscriber) to ensure broad SDK compatibility.
class NativeAppleTranscriptionService: TranscriptionService {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "NativeAppleTranscriptionService")
    
    /// Maps simple language codes to Apple's BCP-47 locale format
    private func mapToAppleLocale(_ simpleCode: String) -> String {
        let mapping = [
            "en": "en-US",
            "es": "es-ES",
            "fr": "fr-FR",
            "de": "de-DE",
            "ar": "ar-SA",
            "it": "it-IT",
            "ja": "ja-JP",
            "ko": "ko-KR",
            "pt": "pt-BR",
            "yue": "yue-CN",
            "zh": "zh-CN"
        ]
        return mapping[simpleCode] ?? "en-US"
    }
    
    enum ServiceError: Error, LocalizedError {
        case invalidModel
        case permissionDenied
        case localeNotSupported
        case recognizerUnavailable
        case transcriptionFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .invalidModel:
                return "Invalid model type provided for Native Apple transcription."
            case .permissionDenied:
                return "Speech recognition permission was denied."
            case .localeNotSupported:
                return "The selected language is not supported by SFSpeechRecognizer."
            case .recognizerUnavailable:
                return "The speech recognizer is currently unavailable."
            case .transcriptionFailed(let reason):
                return "Transcription failed: \(reason)"
            }
        }
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        guard model is NativeAppleModel else {
            throw ServiceError.invalidModel
        }
        
        #if canImport(Speech)
        // Request authorization
        let auth = await requestSpeechAuthorization()
        guard auth == .authorized else {
            logger.error("Speech authorization denied or restricted: \(String(describing: auth.rawValue))")
            throw ServiceError.permissionDenied
        }
        
        // Determine locale
        let selectedLanguage = UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "en"
        let appleLocale = mapToAppleLocale(selectedLanguage)
        let locale = Locale(identifier: appleLocale)
        
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            logger.error("Locale not supported by SFSpeechRecognizer: \(locale.identifier)")
            throw ServiceError.localeNotSupported
        }
        guard recognizer.isAvailable else {
            logger.error("SFSpeechRecognizer is unavailable")
            throw ServiceError.recognizerUnavailable
        }
        
        logger.notice("Starting native Apple transcription via SFSpeechRecognizer. Locale=\(locale.identifier, privacy: .public)")
        
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true // Prefer on-device when available
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        
        let transcript: String = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    continuation.resume(throwing: ServiceError.transcriptionFailed(error.localizedDescription))
                    return
                }
                if let result = result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
            // Safety: if task ends without final result, emit a failure after a timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
                if task.state != .completed {
                    task.cancel()
                    continuation.resume(throwing: ServiceError.transcriptionFailed("Timed out waiting for final result"))
                }
            }
        }
        
        var finalTranscription = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if UserDefaults.standard.object(forKey: "IsTextFormattingEnabled") as? Bool ?? true {
            finalTranscription = WhisperTextFormatter.format(finalTranscription)
        }
        
        logger.notice("Native transcription successful. Length: \(finalTranscription.count, privacy: .public) characters.")
        return finalTranscription
        #else
        throw ServiceError.transcriptionFailed("Speech framework not available on this platform.")
        #endif
    }
    
    #if canImport(Speech)
    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
    #endif
}
