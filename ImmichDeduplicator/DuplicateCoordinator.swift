import Foundation

@MainActor
final class DuplicateCoordinator: ObservableObject {
    @Published var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
    @Published var apiKey = UserDefaults.standard.string(forKey: "apiKey") ?? ""
    @Published private(set) var plan: CleanupPlan = .empty
    @Published private(set) var statusText = "Enter your Immich server and API key, then scan."
    @Published private(set) var isWorking = false
    @Published private(set) var lastDeletedLocalCount = 0
    @Published private(set) var lastResolvedServerGroupCount = 0
    @Published var errorMessage: String?

    private let photoLibrary = PhotoLibraryService()

    var canScan: Bool {
        !isWorking && AppSettings(serverURL: serverURL, apiKey: apiKey).isReady
    }

    var canClean: Bool {
        !isWorking && (plan.localAssetsToDelete > 0 || !plan.serverPlans.isEmpty)
    }

    func scan() async {
        await run {
            saveSettings()
            statusText = "Loading Immich duplicate groups..."
            lastDeletedLocalCount = 0
            lastResolvedServerGroupCount = 0

            let api = try ImmichAPI(settings: currentSettings)
            async let serverGroups = api.fetchDuplicates()
            async let localAssets = photoLibrary.scanLocalAssets { scanned, total in
                self.statusText = "Scanning Photos library: \(scanned.formatted()) / \(total.formatted())"
            }

            let (groups, assets) = try await (serverGroups, localAssets)
            statusText = "Building cleanup plan..."
            plan = DuplicatePlanner.build(serverGroups: groups, localAssets: assets)

            if plan.totalDuplicateGroups == 0 {
                statusText = "No duplicate candidates found."
            } else {
                statusText = "Ready. Review the counts, then run cleanup."
            }
        }
    }

    func clean() async {
        await run {
            guard plan.localAssetsToDelete > 0 || !plan.serverPlans.isEmpty else {
                throw CleanupError.emptyCleanupPlan
            }

            saveSettings()
            let localIds = Set(plan.localPlans.flatMap(\.deleteLocalIdentifiers) + plan.serverPlans.flatMap(\.matchedLocalTrashIds))

            statusText = "Deleting \(localIds.count.formatted()) local Photos assets..."
            let deletedLocal = try await photoLibrary.deleteAssets(localIdentifiers: Array(localIds))
            lastDeletedLocalCount = deletedLocal

            statusText = "Resolving \(plan.serverPlans.count.formatted()) Immich duplicate groups..."
            let api = try ImmichAPI(settings: currentSettings)
            let resolveGroups = plan.serverPlans.map {
                DuplicateResolveGroup(
                    duplicateId: $0.duplicateId,
                    keepAssetIds: $0.keepAssetIds,
                    trashAssetIds: $0.trashAssets.map(\.id)
                )
            }
            try await api.resolveDuplicates(resolveGroups)
            lastResolvedServerGroupCount = resolveGroups.count

            statusText = "Cleanup complete. Rescan to verify."
            plan = .empty
        }
    }

    private var currentSettings: AppSettings {
        AppSettings(serverURL: serverURL, apiKey: apiKey)
    }

    private func saveSettings() {
        UserDefaults.standard.set(serverURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "serverURL")
        UserDefaults.standard.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "apiKey")
    }

    private func run(_ operation: @escaping () async throws -> Void) async {
        guard !isWorking else {
            return
        }

        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
            statusText = "Stopped."
        }
    }
}

enum DuplicatePlanner {
    static func build(serverGroups: [ImmichDuplicateGroup], localAssets: [LocalAssetRecord]) -> CleanupPlan {
        let localIndex = LocalAssetMatcher(records: localAssets)
        let serverPlans = buildServerPlans(serverGroups: serverGroups, localIndex: localIndex)
        let serverMatchedIds = Set(serverPlans.flatMap(\.matchedLocalTrashIds))
        let localPlans = buildLocalPlans(localAssets: localAssets, excluding: serverMatchedIds)
        let skippedServerTrashAssets = serverPlans.reduce(0) { partial, plan in
            partial + max(0, plan.trashAssets.count - plan.matchedLocalTrashIds.count)
        }

        return CleanupPlan(
            serverPlans: serverPlans,
            localPlans: localPlans,
            totalServerDuplicateGroups: serverGroups.count,
            totalServerDuplicateAssets: serverGroups.reduce(0) { $0 + $1.assets.count },
            totalLocalAssetCount: localAssets.count,
            skippedServerTrashAssets: skippedServerTrashAssets
        )
    }

    private static func buildServerPlans(serverGroups: [ImmichDuplicateGroup], localIndex: LocalAssetMatcher) -> [ServerCleanupPlan] {
        var claimedLocalIds = Set<String>()

        return serverGroups.compactMap { group in
            let keepIds = keepAssetIds(for: group)
            let trashAssets = group.assets.filter { !keepIds.contains($0.id) }
            guard !trashAssets.isEmpty else {
                return nil
            }

            var matchedLocalIds: [String] = []
            for asset in trashAssets {
                if let match = localIndex.bestMatch(for: asset, excluding: claimedLocalIds) {
                    matchedLocalIds.append(match.localIdentifier)
                    claimedLocalIds.insert(match.localIdentifier)
                }
            }

            return ServerCleanupPlan(
                duplicateId: group.duplicateId,
                keepAssetIds: Array(keepIds),
                trashAssets: trashAssets,
                matchedLocalTrashIds: matchedLocalIds
            )
        }
    }

    private static func keepAssetIds(for group: ImmichDuplicateGroup) -> Set<String> {
        if !group.suggestedKeepAssetIds.isEmpty {
            return Set(group.suggestedKeepAssetIds)
        }

        guard let largest = group.assets.max(by: { $0.fileSize < $1.fileSize }) else {
            return []
        }

        return [largest.id]
    }

    private static func buildLocalPlans(localAssets: [LocalAssetRecord], excluding excludedIds: Set<String>) -> [LocalCleanupPlan] {
        let candidates = localAssets.filter {
            !excludedIds.contains($0.localIdentifier) &&
                $0.mediaKind != .other &&
                $0.creationDate != nil &&
                $0.fileSize != nil
        }
        let grouped = Dictionary(grouping: candidates, by: localDuplicateKey)

        return grouped.compactMap { key, records in
            guard records.count > 1 else {
                return nil
            }

            let fileSizes = Set(records.compactMap(\.fileSize))
            guard fileSizes.count > 1 else {
                return nil
            }

            let sorted = records.sorted {
                let lhsSize = $0.fileSize ?? 0
                let rhsSize = $1.fileSize ?? 0
                if lhsSize == rhsSize {
                    return $0.localIdentifier > $1.localIdentifier
                }

                return lhsSize > rhsSize
            }
            guard let keep = sorted.first else {
                return nil
            }

            let deleteIds = sorted.dropFirst().map(\.localIdentifier)
            guard !deleteIds.isEmpty else {
                return nil
            }

            return LocalCleanupPlan(
                id: key,
                keepLocalIdentifier: keep.localIdentifier,
                deleteLocalIdentifiers: Array(deleteIds)
            )
        }
    }

    private static func localDuplicateKey(for record: LocalAssetRecord) -> String {
        let seconds = Int(record.creationDate?.timeIntervalSince1970.rounded() ?? 0)
        let duration = Int(record.duration.rounded())
        return [
            record.mediaKind.rawValue,
            String(record.pixelWidth),
            String(record.pixelHeight),
            String(seconds),
            String(duration)
        ].joined(separator: ":")
    }
}

struct LocalAssetMatcher {
    private let records: [LocalAssetRecord]

    init(records: [LocalAssetRecord]) {
        self.records = records
    }

    func bestMatch(for asset: ImmichAsset, excluding excludedIds: Set<String>) -> LocalAssetRecord? {
        let scored = records
            .filter { !excludedIds.contains($0.localIdentifier) }
            .map { record in (record, score(asset: asset, record: record)) }
            .filter { $0.1 >= 70 }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return (lhs.0.fileSize ?? 0) > (rhs.0.fileSize ?? 0)
                }
                return lhs.1 > rhs.1
            }

        return scored.first?.record
    }

    private func score(asset: ImmichAsset, record: LocalAssetRecord) -> Int {
        var score = 0

        if MediaKind(immichType: asset.type) == record.mediaKind {
            score += 15
        }

        if filenamesMatch(asset.originalFileName, record.filename) {
            score += 35
        }

        if dimensionsMatch(asset: asset, record: record) {
            score += 25
        }

        if datesMatch(assetDate: asset.bestDate, localDate: record.creationDate) {
            score += 20
        }

        if fileSizesMatch(serverSize: asset.fileSize, localSize: record.fileSize) {
            score += 20
        }

        return score
    }

    private func filenamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizeFilename(lhs) == normalizeFilename(rhs)
    }

    private func normalizeFilename(_ filename: String) -> String {
        filename.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func dimensionsMatch(asset: ImmichAsset, record: LocalAssetRecord) -> Bool {
        let assetWidth = asset.width ?? asset.exifInfo?.exifImageWidth
        let assetHeight = asset.height ?? asset.exifInfo?.exifImageHeight

        guard let assetWidth, let assetHeight else {
            return false
        }

        return (assetWidth == record.pixelWidth && assetHeight == record.pixelHeight) ||
            (assetWidth == record.pixelHeight && assetHeight == record.pixelWidth)
    }

    private func datesMatch(assetDate: Date?, localDate: Date?) -> Bool {
        guard let assetDate, let localDate else {
            return false
        }

        return abs(assetDate.timeIntervalSince(localDate)) <= 60
    }

    private func fileSizesMatch(serverSize: Int64, localSize: Int64?) -> Bool {
        guard serverSize > 0, let localSize, localSize > 0 else {
            return false
        }

        let difference = abs(serverSize - localSize)
        let tolerance = max(Int64(8192), serverSize / 100)
        return difference <= tolerance
    }
}

private extension ImmichAsset {
    var bestDate: Date? {
        Self.parseDate(localDateTime) ??
            Self.parseDate(exifInfo?.dateTimeOriginal) ??
            Self.parseDate(fileCreatedAt)
    }

    static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: value) {
            return date
        }

        isoFormatter.formatOptions = [.withInternetDateTime]
        return isoFormatter.date(from: value)
    }
}
