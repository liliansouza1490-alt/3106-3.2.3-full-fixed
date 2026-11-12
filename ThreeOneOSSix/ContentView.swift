import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var patchDraftCoordinator: PatchDraftCoordinator
    @EnvironmentObject private var patchStore: PatchProjectStore
    @EnvironmentObject private var repositoryStore: PackageRepositoryStore
    @State private var tabNavigation: AppTabNavigationState
    @State private var showSettings = false
    @State private var showLogs = false
    @State private var showAppGroupAlert = false
    @StateObject private var scanCoordinator = ScanCoordinator()

    init() {
#if targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        let initialTab: Int
        if arguments.contains("--simulate-new-tab")
            || arguments.contains("--simulate-sources-tab")
            || arguments.contains("--simulate-installed-tab")
            || arguments.contains("--simulate-patch-tab")
            || arguments.contains("--simulate-features-tab") {
            initialTab = 0
        } else if arguments.contains("--simulate-files-tab") {
            initialTab = 4
        } else if arguments.contains("--simulate-search-tab") {
            initialTab = 5
        } else if arguments.contains("--simulate-cleaner-tab") {
            initialTab = 6
        } else if arguments.contains("--simulate-wallpaper-tab") {
            initialTab = 7
        } else {
            initialTab = 0
        }
        _tabNavigation = State(initialValue: AppTabNavigationState(selectedTab: initialTab))
        _showSettings = State(
            initialValue: arguments.contains("--simulate-settings")
        )
#else
        _tabNavigation = State(initialValue: AppTabNavigationState())
#endif
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .tint(AppTheme.accent)
        .imageScale(.small)
        .onChange(of: patchDraftCoordinator.request?.id) { requestID in
            if requestID != nil { tabNavigation.select(AppSection.installed.rawValue) }
        }
        .onChange(of: patchDraftCoordinator.importRequest?.id) { requestID in
            if requestID != nil { tabNavigation.select(AppSection.installed.rawValue) }
        }
        .onAppear {
            tabNavigation.reconcileSelection(with: featureVisibility)
#if !targetEnvironment(simulator)
            if SandboxAccess.needsWorseQuery, SandboxAccess.appGroup == nil {
                showAppGroupAlert = true
            }
#endif
        }
        .alert(language.text("appgroup.title"), isPresented: $showAppGroupAlert) {
            Button(language.text("common.ok")) {}
        } message: {
            Text(language.text("appgroup.message"))
        }
        .environmentObject(scanCoordinator)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showLogs) { LogView() }
        .sheet(isPresented: $scanCoordinator.isPresented) {
            ScanProgressSheet()
                .environmentObject(scanCoordinator)
                .environment(\.appLanguage, language)
        }
        .overlay(alignment: .bottom) {
            if scanCoordinator.isRunning && !scanCoordinator.isPresented {
                ScanRunningBanner()
                    .environmentObject(scanCoordinator)
                    .environment(\.appLanguage, language)
            }
        }
        .patchStorePresentation(patchStore)
        .repositoryStorePresentation(repositoryStore, patchStore: patchStore)
    }

    private var compactLayout: some View {
        TabView(selection: tabSelection) {
            ForEach(featureVisibility.visibleSections) { section in
                sectionContent(section)
                    .tabItem {
                        CompactTabLabel(
                            title: language.text(section.titleKey),
                            systemImage: section.systemImage
                        )
                    }
                    .tag(section.rawValue)
            }
        }
    }

    private var regularLayout: some View {
        NavigationSplitView {
            List {
                ForEach(featureVisibility.visibleSections) { section in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            tabNavigation.select(section.rawValue)
                        }
                    } label: {
                        Label(language.text(section.titleKey), systemImage: section.systemImage)
                            .fontWeight(section.rawValue == tabNavigation.selectedTab ? .semibold : .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        section.rawValue == tabNavigation.selectedTab
                            ? AppTheme.accent.opacity(0.14)
                            : Color.clear
                    )
                    .accessibilityAddTraits(
                        section.rawValue == tabNavigation.selectedTab ? .isSelected : []
                    )
                }
            }
            .navigationTitle("3106")
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            sectionContent(selectedVisibleSection)
                .id(selectedVisibleSection.rawValue)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func sectionContent(_ section: AppSection) -> some View {
        switch section {
        case .home:
            FeatureHubView(
                onSelectTab: { section in
                    tabNavigation.select(section.rawValue)
                },
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .new:
            RepositoryNewView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .sources:
            RepositorySourcesView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .installed:
            PatchProjectsView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .files:
            AppDataBrowserView(
                tabSession: filesTabSession,
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .search:
            RepositorySearchView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .cleaner:
            CleanerView(onOpenSettings: openSettings)
        case .backup:
            BackupTabView()
        case .wallpapers:
            WallpaperLabView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        }
    }

    private var tabSelection: Binding<Int> {
        Binding(
            get: { tabNavigation.selectedTab },
            set: { tabNavigation.select($0) }
        )
    }

    private var filesTabSession: Binding<FilesTabSession> {
        Binding(
            get: { tabNavigation.filesTabs },
            set: { tabNavigation.setFilesTabs($0) }
        )
    }

    private var featureVisibility: FeatureVisibility {
        FeatureVisibility(
            selectedSections: [.home, .files, .search, .cleaner, .wallpapers],
            wallpapersSupported: WallpaperFeatureSupportPolicy.isSupported(
                major: AppInfo.versionTuple.major
            ),
            developerModeEnabled: true
        )
    }

    private var selectedVisibleSection: AppSection {
        let selected = AppSection(rawValue: tabNavigation.selectedTab)
        return selected.flatMap {
            featureVisibility.isVisible($0) ? $0 : nil
        } ?? .home
    }

    private func openSettings() {
        showSettings = true
    }

    private func openLogs() {
        showLogs = true
    }
}

private struct CompactTabLabel: View {
    let title: String
    let systemImage: String

    @ViewBuilder
    var body: some View {
        if let image = UIImage(
            systemName: systemImage,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        )?.withRenderingMode(.alwaysTemplate) {
            Image(uiImage: image)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
        }
        Text(title)
    }
}

