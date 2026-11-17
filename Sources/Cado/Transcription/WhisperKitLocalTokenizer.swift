import ArgmaxCore
import Foundation

/// WhisperKit loads `tokenizer.json` from the model folder, but when that
/// load fails for any reason it silently falls back to downloading a tokenizer
/// from huggingface.co (`ModelUtilities.loadTokenizer`, audit #27 F-07). Cado
/// never wants that request: the catalog folders are hash-verified, but a
/// hand-made folder (a user-picked `modelPath`) can carry a broken file.
///
/// So the adapter parses the folder's tokenizer itself first, with the same
/// loader WhisperKit uses for the local case, and refuses the model if that
/// fails. WhisperKit's own load of the same file then succeeds, and its network
/// branch is never reached.
enum WhisperKitLocalTokenizer {
    /// Throws `TranscriptionError.modelLoadFailed` unless every `tokenizer.json`
    /// WhisperKit could pick in `folder` loads, and the top-level one exists.
    /// WhisperKit searches `<folder>/models/openai/whisper-*/` before the top
    /// level (`ModelUtilities.loadTokenizer`), so those are checked too.
    /// Blocks the calling (background) queue.
    static func verify(folder: URL, load: @escaping @Sendable (URL) async throws -> Void = parse) throws {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path) else {
            throw TranscriptionError.modelLoadFailed(path: folder.path)
        }
        for dir in nestedTokenizerFolders(in: folder) + [folder] {
            do {
                try BlockingAsync.run(timeout: 60) { try await load(dir) }
            } catch {
                Log.error("WhisperKit tokenizer in \(dir.lastPathComponent) doesn't load; refusing the model instead of letting WhisperKit download one: \(error)")
                throw TranscriptionError.modelLoadFailed(path: folder.path)
            }
        }
    }

    /// `<folder>/models/openai/*` directories that hold a `tokenizer.json`.
    static func nestedTokenizerFolders(in folder: URL) -> [URL] {
        let root = folder.appendingPathComponent("models/openai", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("tokenizer.json").path) }
            .sorted { $0.path < $1.path }
    }

    /// WhisperKit's own local tokenizer loader.
    @Sendable static func parse(_ folder: URL) async throws {
        _ = try await AutoTokenizerWrapper.from(modelFolder: folder)
    }
}
