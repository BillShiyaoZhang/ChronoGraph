import Foundation
import Combine
import BackgroundTasks

@MainActor
final class SharedCalendarManager: ObservableObject {
    static let backgroundTaskID = "com.shiyao-zhang.ChronoGraph.shared-calendar-refresh"
    @Published private(set) var profiles: [SharedCalendarProfile] = []
    @Published private(set) var calendars: [SharedCalendarOption] = []
    @Published private(set) var accounts: [SharedCalendarAccount] = []
    @Published private(set) var inventoryIsAvailable = false
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    private var coordinator: MirrorSyncCoordinator?
    private var activeCommands = 0
    private var scheduledRefresh: Task<Void, Never>?
    private var automaticRunning = false
    private var needsAnotherPass = false
    private var recordsManagedCalendars = true
    private(set) var isUsingPreviewFixtures = false

    init(coordinator injectedCoordinator: MirrorSyncCoordinator? = nil) {
        do {
            #if DEBUG
            let testProcess = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
                ProcessInfo.processInfo.arguments.contains("-sharing-ui-testing")
            #else
            let testProcess = false
            #endif
            let coordinator: MirrorSyncCoordinator
            if let injectedCoordinator {
                coordinator = injectedCoordinator
                recordsManagedCalendars = false
            } else {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-sharing-home-fixtures") {
                    coordinator = try SharedCalendarPreviewFixtures.makeCoordinator()
                    isUsingPreviewFixtures = true
                    recordsManagedCalendars = false
                } else {
                    recordsManagedCalendars = !testProcess
                    coordinator = try MirrorSyncCoordinator(repository: SharedCalendarRepository(inMemory: testProcess),
                        store: EventKitCalendarStore(), knownManagedCalendarIDs: Set(UserDefaults.standard.stringArray(forKey: CalendarSelectionPolicy.managedCalendarIDsDefaultsKey) ?? []))
                }
                #else
                coordinator = try MirrorSyncCoordinator(repository: SharedCalendarRepository(), store: EventKitCalendarStore(),
                    knownManagedCalendarIDs: Set(UserDefaults.standard.stringArray(forKey: CalendarSelectionPolicy.managedCalendarIDsDefaultsKey) ?? []))
                #endif
            }
            self.coordinator = coordinator
            profiles = coordinator.state.profiles
            recordManagedCalendarIDs()
            coordinator.onChange = { [weak self] state in
                self?.profiles = state.profiles
                self?.recordManagedCalendarIDs()
            }
        } catch { errorMessage = SharedCalendarError.unavailableStorage.localizedDescription }
    }

    private func recordManagedCalendarIDs() {
        guard recordsManagedCalendars, let coordinator else { return }
        let key = CalendarSelectionPolicy.managedCalendarIDsDefaultsKey
        let previous = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        UserDefaults.standard.set(Array(previous.union(coordinator.managedIDs)), forKey: key)
    }

    private func requireCoordinator() throws -> MirrorSyncCoordinator {
        guard let coordinator else { throw SharedCalendarError.unavailableStorage }
        return coordinator
    }

    private func command<T>(_ action: () async throws -> T) async throws -> T {
        activeCommands += 1
        isBusy = true
        defer {
            activeCommands -= 1
            isBusy = activeCommands > 0
        }
        do {
            let result = try await action()
            errorMessage = nil
            return result
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            throw error
        }
    }

    func refresh() {
        Task { await refreshInventory() }
    }

    func refreshInventory() async {
        do {
            let inventory = try await requireCoordinator().inventory()
            calendars = inventory.calendars
            accounts = inventory.accounts
            inventoryIsAvailable = true
            if errorMessage == SharedCalendarError.permission.localizedDescription { errorMessage = nil }
        } catch {
            calendars = []
            accounts = []
            inventoryIsAvailable = false
            errorMessage = error.localizedDescription
        }
    }

    func create(_ profile: SharedCalendarProfile) async throws {
        try await command { try await requireCoordinator().create(profile) }
        await refreshInventory()
        scheduleBackgroundRefresh()
    }

    func update(_ profile: SharedCalendarProfile) async throws {
        try await command { try await requireCoordinator().update(profile) }
        await refreshInventory()
        scheduleBackgroundRefresh()
    }

    /// Commits confirmed sharing rules. Local home browsing uses SharingWorkspace instead.
    func updateRange(profileID: UUID, range: SharedCalendarRange) async throws {
        guard var profile = profiles.first(where: { $0.id == profileID }) else { throw SharedCalendarError.staleConfiguration }
        profile.range = range
        try await update(profile)
    }

    func updatePrivacyMode(profileID: UUID, privacyMode: PrivacyMode) async throws {
        guard var profile = profiles.first(where: { $0.id == profileID }) else { throw SharedCalendarError.staleConfiguration }
        profile.privacyMode = privacyMode
        try await update(profile)
    }

    func updateSources(profileID: UUID, sourceCalendarIDs: Set<String>) async throws {
        guard var profile = profiles.first(where: { $0.id == profileID }) else { throw SharedCalendarError.staleConfiguration }
        let forbidden = Set(calendars.filter(\.isManaged).map(\.id))
        guard sourceCalendarIDs.isDisjoint(with: forbidden) else { throw SharedCalendarError.managedSource }
        profile.sourceCalendarIDs = sourceCalendarIDs
        try await update(profile)
    }

    func sync(profileID: UUID) async throws {
        try await command { try await requireCoordinator().sync(profileID: profileID) }
    }

    func setPaused(profileID: UUID, paused: Bool) async throws {
        try await command { try await requireCoordinator().setPaused(profileID: profileID, paused: paused) }
        scheduleBackgroundRefresh()
    }

    func delete(profileID: UUID) async throws {
        try await command { try await requireCoordinator().delete(profileID: profileID) }
        await refreshInventory()
        scheduleBackgroundRefresh()
    }

    func recreateTarget(profileID: UUID) async throws {
        try await command { try await requireCoordinator().recreateTarget(profileID: profileID) }
        await refreshInventory()
        scheduleBackgroundRefresh()
    }

    func preview(profileID: UUID) async throws -> [SharedEventPreview] {
        try await requireCoordinator().preview(profileID: profileID)
    }

    func browsePreview(profileID: UUID, range: SharedCalendarRange, sourceCalendarIDs: Set<String>,
                       displayMode: PrivacyMode? = nil) async throws -> [SharedEventPreview] {
        try await requireCoordinator().browsePreview(profileID: profileID, range: range,
            sourceCalendarIDs: sourceCalendarIDs, displayMode: displayMode)
    }

    func review(_ draft: SharedCalendarDraft) async throws -> SharedRuleReview {
        try await requireCoordinator().review(draft)
    }

    func setVisibility(profileID: UUID, event: SharedEventPreview, visibility: SharedVisibility?, entireSeries: Bool,
                       expectedRevision: Int? = nil) async throws {
        try await command {
            try await requireCoordinator().setVisibility(profileID: profileID, event: event, visibility: visibility,
                entireSeries: entireSeries, expectedRevision: expectedRevision)
        }
    }

    func foregroundRefresh() {
        refresh()
        requestAutomaticRefresh()
        scheduleBackgroundRefresh()
    }

    func requestAutomaticRefresh() {
        if automaticRunning { needsAnotherPass = true; return }
        scheduledRefresh?.cancel()
        scheduledRefresh = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) }
            catch { return }
            guard let self else { return }
            self.automaticRunning = true
            repeat {
                self.needsAnotherPass = false
                _ = await self.performAutomaticRefresh()
            } while self.needsAnotherPass && !Task.isCancelled
            self.automaticRunning = false
        }
    }

    @discardableResult
    func performAutomaticRefresh() async -> Bool {
        guard let coordinator else { return false }
        var successful = true
        // Pending deletions were already explicitly confirmed by the owner.
        for profile in coordinator.state.profiles {
            if Task.isCancelled { return false }
            do {
                if profile.pendingDeletion { try await delete(profileID: profile.id) }
                else if !profile.isPaused { try await sync(profileID: profile.id) }
            } catch { successful = false }
        }
        return successful
    }

    func scheduleBackgroundRefresh() {
        guard !isUsingPreviewFixtures else { return }
        guard profiles.contains(where: { !$0.isPaused || $0.pendingDeletion }) else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskID)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        // Lack of background execution is not an error in foreground publishing.
        try? BGTaskScheduler.shared.submit(request)
    }
}

@MainActor
final class SharedCalendarBackgroundRegistration {
    static func register(manager: SharedCalendarManager) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: SharedCalendarManager.backgroundTaskID, using: .main) { task in
            let work = Task { @MainActor in
                manager.scheduleBackgroundRefresh()
                let success = await manager.performAutomaticRefresh()
                task.setTaskCompleted(success: success && !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
    }
}
