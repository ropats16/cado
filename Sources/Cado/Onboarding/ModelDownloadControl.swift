import Combine

/// What onboarding's model step drives: the same in-app downloads Settings
/// runs (`SettingsViewModel+ModelDownloads.swift`), so a download started in
/// either shows in both and Cancel works from either. A port, so the
/// onboarding view model is testable with a fake.
@MainActor
protocol ModelDownloadControl: AnyObject {
    /// Downloads under way, or the last one that failed, by engine and model.
    var modelDownloads: [ModelDownloadKey: ModelDownloadState] { get }
    var modelDownloadsPublisher: AnyPublisher<[ModelDownloadKey: ModelDownloadState], Never> { get }
    /// Its engine downloads in-app, it isn't installed and isn't downloading.
    func canDownloadModel(_ key: ModelDownloadKey) -> Bool
    /// The task ends when the download settles; nil when nothing started.
    @discardableResult func downloadModel(_ key: ModelDownloadKey) -> Task<Void, Never>?
    /// What arrived is kept, so the next download resumes.
    func cancelModelDownload(_ key: ModelDownloadKey)
    /// A stopped download left files to resume from ("Resume", not "Download").
    func hasPartialDownload(_ key: ModelDownloadKey) -> Bool
}

extension SettingsViewModel: ModelDownloadControl {
    var modelDownloadsPublisher: AnyPublisher<[ModelDownloadKey: ModelDownloadState], Never> {
        $modelDownloads.eraseToAnyPublisher()
    }
}
