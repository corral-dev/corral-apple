// swift-tools-version: 6.0
// Portable SPM validation entry: macOS `swift test` runs Foundation-only product-logic
// regressions over Shared/Core. App shells and SwiftUI views (Shared/UI, iOS, macOS)
// stay on the Xcode path (project.yml); this manifest is never used by the Xcode build.
import PackageDescription

let package = Package(
    name: "Corral",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "Corral", targets: ["Corral"]),
    ],
    targets: [
        .target(
            name: "Corral",
            // Shared/Core is the Foundation-only layer compiled into every Apple
            // client (iOS and macOS app targets); SwiftUI shells and views stay on
            // the Xcode path (project.yml).
            path: "Shared/Core",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-default-isolation", "MainActor"], .when(platforms: [.iOS, .macOS])),
            ]
        ),
        .testTarget(
            name: "CorralTests",
            dependencies: ["Corral"],
            path: "Tests",
            exclude: [
                // Xcode-only tests (UIKit/SwiftUI/AppModel/iOS-gated sources).
                // AppModelIdentityTests drives the real AppModel and runs
                // under Xcode only.
                "AppModelIdentityTests.swift",
                "ChatActivityStateTests.swift",
                "ChatKeyboardLayoutTests.swift",
                "ChatMarkdownTests.swift",
                "ChatScrollMomentumTests.swift",
                "ChatTopAlignmentLayoutTests.swift",
                "ChatWorkingLayoutTests.swift",
                "HostConnectionTests.swift",
                "MessageBubbleLayoutTests.swift",
                "RuntimeLogoTests.swift",
                "SessionActionsMenuTests.swift",
                "SessionHeaderPresentationTests.swift",
                "SessionTextSizeTests.swift",
            ],
            sources: [
                "ChatComposerPolicyTests.swift",
                "HapticFeedbackPolicyTests.swift",
                "ChatHistoryPullTests.swift",
                "ChatJumpPlanTests.swift",
                "ChatImageReferenceTests.swift",
                "ConversationProvisionalWorkingTests.swift",
                "ConversationSendCoordinatorTests.swift",
                "ComposerDraftStoreTests.swift",
                "ConversationTailCacheTests.swift",
                "ConversationTimelineTests.swift",
                "ConversationTimePolicyTests.swift",
                "DataReviewSafetyTests.swift",
                "HandshakeRaceTests.swift",
                "HostCustomNameTests.swift",
                "LanDiscoveryTests.swift",
                "NativeQuestionTests.swift",
                "NotificationLedgerTests.swift",
                "NotificationPreviewTests.swift",
                "NotificationReplyTests.swift",
                "NotificationTapRoutingTests.swift",
                "OneShotThrowingContinuationTests.swift",
                "PendingCommandStoreTests.swift",
                "PushEnvironmentTests.swift",
                "RecentSessionComboStoreTests.swift",
                "NewSessionOptionsTests.swift",
                "SessionCreationCoordinatorTests.swift",
                "RemoteClientLifecycleTests.swift",
                "ConnectionRecoveryTests.swift",
                "RemoteConnectionStabilityTests.swift",
                "RemoteCryptoTests.swift",
                "SessionListStoreTests.swift",
                "SessionListFilteringTests.swift",
                "SessionPresentationTests.swift",
                "DesktopSidebarProjectionTests.swift",
                "SessionUserPromptsTests.swift",
                "ComposerHistoryTests.swift",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
