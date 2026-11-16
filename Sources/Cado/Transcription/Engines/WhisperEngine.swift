import Foundation

/// whisper.cpp as an `EngineDescriptor`: the catalog, auto-pick and
/// checksums. A catalog model downloads in Settings (one file,
/// `inAppDownload`) or by `make model`. Runs on every Mac (Metal on Apple
/// Silicon, CPU on Intel) and every language, so it's the fallback.
struct WhisperEngine: EngineDescriptor {
    let kind = EngineKind.whisper

    var models: [EngineModelOption] {
        ModelCatalog.models.map { EngineModelOption(id: $0.id, label: $0.label) }
    }

    /// `ModelSelection.resolve(model:modelPath:…)`: a hand-set `modelPath`,
    /// else the named model, else the hardware auto-pick.
    func resolve(_ choice: ModelChoice, in context: ModelContext) -> ModelSpec {
        ModelSelection.resolve(model: choice, modelPath: context.customPath, language: context.language,
                               hardware: context.hardware, modelsDir: context.modelsDir,
                               presentFilenames: context.presentFilenames)
    }

    /// Catalog files in the models folder, by name (no per-model stat).
    func installedModelIDs(in context: ModelContext) -> Set<String> {
        Set(ModelCatalog.models.filter { context.presentFilenames.contains($0.filename) }.map(\.id))
    }

    /// Settings' Download, or `make model`, for a catalog file in the
    /// models folder; nil for a custom file (nothing to fetch).
    func downloadHint(for spec: ModelSpec) -> ModelDownloadHint? {
        ModelSelection.downloadCommand(for: spec).map { .inApp(command: $0) }
    }

    /// A catalog model's file, from where `make model` fetches it, into the
    /// file `resolve` names: `<models>/ggml-<id>.bin`.
    func inAppDownload(of id: String, in modelsDir: URL) -> ModelDownload? {
        ModelCatalog.model(id: id).map { model in
            .file(modelID: id, model.pinnedFile,
                  destination: modelsDir.appendingPathComponent(model.filename, isDirectory: false))
        }
    }

    /// Verified against the catalog checksum when it's a catalog file.
    func spec(forModelArgument argument: String, language: String) -> ModelSpec {
        .file(argument, language: language)
    }

    func makeAdapter(_ options: EngineOptions) -> (ModelSpec) throws -> TranscriptionAdapter {
        TranscriptionEngine.whisperAdapter(threads: options.threads, tuning: options.whisper)
    }

    let acknowledgement = """
        whisper.cpp and ggml by Georgi Gerganov and contributors (MIT). \
        Whisper models by OpenAI (MIT), in ggml format from huggingface.co/ggerganov/whisper.cpp.
        """
}
