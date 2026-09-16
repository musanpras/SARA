import SwiftUI
import SARACore

/// Composition root for the UI.
///
/// The app target owns process lifecycle only. Start-up is asynchronous because
/// stored preferences shape how the pipeline is wired, so the environment is
/// built once the local store has been read.
public struct SARARootView: View {
    @State private var viewModel: ConversationViewModel?

    public init() {}

    public var body: some View {
        ZStack {
            SARATheme.Palette.background.ignoresSafeArea()

            if let viewModel {
                HomeView(viewModel: viewModel)
            } else {
                ProgressView()
                    .tint(SARATheme.Palette.secondaryText)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            guard viewModel == nil else { return }
            viewModel = await Self.makeViewModel()
        }
    }

    @MainActor
    private static func makeViewModel() async -> ConversationViewModel {
        let environment = await AppEnvironment.bootstrap()
        await environment.restore()

        return ConversationViewModel(
            handler: environment.conversation,
            speech: environment.speech,
            voice: environment.voice,
            memory: environment.memory,
            preferences: environment.preferences,
            startupWarning: environment.storageWarning
        )
    }
}
