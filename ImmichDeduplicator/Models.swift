import Foundation
import Photos

struct AppSettings {
    var serverURL: String
    var apiKey: String

    var isReady: Bool {
        URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil &&
            !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct ImmichDuplicateGroup: Decodable, Identifiable {
    let assets: [ImmichAsset]
    let duplicateId: String
    let suggestedKeepAssetIds: [String]

    var id: String { duplicateId }
}

struct ImmichAsset: Decodable, Identifiable {
    let checksum: String?
    let duplicateId: String?
    let exifInfo: ImmichExifInfo?
    let fileCreatedAt: String?
    let height: Int?
    let id: String
    let localDateTime: String?
    let originalFileName: String
    let originalMimeType: String?
    let originalPath: String?
    let type: String
    let width: Int?

    var fileSize: Int64 {
        exifInfo?.fileSizeInByte ?? 0
    }
}

struct ImmichExifInfo: Decodable {
    let dateTimeOriginal: String?
    let exifImageHeight: Int?
    let exifImageWidth: Int?
    let fileSizeInByte: Int64?
}

struct DuplicateResolveRequest: Encodable {
    let groups: [DuplicateResolveGroup]
}

struct DuplicateResolveGroup: Encodable {
    let duplicateId: String
    let keepAssetIds: [String]
    let trashAssetIds: [String]
}

struct LocalAssetRecord: Identifiable, Hashable {
    let localIdentifier: String
    let filename: String
    let mediaKind: MediaKind
    let creationDate: Date?
    let modificationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let fileSize: Int64?

    var id: String { localIdentifier }
}

enum MediaKind: String, Hashable {
    case image
    case video
    case other

    init(assetMediaType: PHAssetMediaType) {
        switch assetMediaType {
        case .image:
            self = .image
        case .video:
            self = .video
        default:
            self = .other
        }
    }

    init(immichType: String) {
        switch immichType.lowercased() {
        case "image":
            self = .image
        case "video":
            self = .video
        default:
            self = .other
        }
    }
}

struct ServerCleanupPlan: Identifiable {
    let duplicateId: String
    let keepAssetIds: [String]
    let trashAssets: [ImmichAsset]
    let matchedLocalTrashIds: [String]

    var id: String { duplicateId }
}

struct LocalCleanupPlan: Identifiable {
    let id: String
    let keepLocalIdentifier: String
    let deleteLocalIdentifiers: [String]
}

struct CleanupPlan {
    let serverPlans: [ServerCleanupPlan]
    let localPlans: [LocalCleanupPlan]
    let totalServerDuplicateGroups: Int
    let totalServerDuplicateAssets: Int
    let totalLocalAssetCount: Int
    let skippedServerTrashAssets: Int

    var serverAssetsToRemove: Int {
        serverPlans.reduce(0) { $0 + $1.trashAssets.count }
    }

    var localAssetsToDelete: Int {
        Set(localPlans.flatMap(\.deleteLocalIdentifiers) + serverPlans.flatMap(\.matchedLocalTrashIds)).count
    }

    var totalDuplicateGroups: Int {
        totalServerDuplicateGroups + localPlans.count
    }

    static let empty = CleanupPlan(
        serverPlans: [],
        localPlans: [],
        totalServerDuplicateGroups: 0,
        totalServerDuplicateAssets: 0,
        totalLocalAssetCount: 0,
        skippedServerTrashAssets: 0
    )
}

enum CleanupError: LocalizedError {
    case invalidServerURL
    case photosAccessDenied
    case emptyCleanupPlan
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Enter a valid Immich server URL."
        case .photosAccessDenied:
            return "Full Photos access is required to scan and delete duplicate assets."
        case .emptyCleanupPlan:
            return "No duplicate candidates were found."
        case let .serverError(status, body):
            return "Immich returned HTTP \(status): \(body)"
        }
    }
}
