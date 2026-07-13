import Foundation
import Photos

struct PhotoLibraryService {
    func requestFullAccess() async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized {
            return
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else {
            throw CleanupError.photosAccessDenied
        }
    }

    func scanLocalAssets(progress: @escaping @MainActor (Int, Int) -> Void) async throws -> [LocalAssetRecord] {
        try await requestFullAccess()

        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let fetchResult = PHAsset.fetchAssets(with: options)
        let total = fetchResult.count
        var records: [LocalAssetRecord] = []
        records.reserveCapacity(total)

        for index in 0..<total {
            let asset = fetchResult.object(at: index)
            if let record = makeRecord(from: asset) {
                records.append(record)
            }

            if index % 100 == 0 || index == total - 1 {
                await progress(index + 1, total)
            }
        }

        return records
    }

    func deleteAssets(localIdentifiers: [String]) async throws -> Int {
        let uniqueIdentifiers = Array(Set(localIdentifiers))
        guard !uniqueIdentifiers.isEmpty else {
            return 0
        }

        try await requestFullAccess()
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: uniqueIdentifiers, options: nil)
        guard fetchResult.count > 0 else {
            return 0
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(fetchResult)
        }

        return fetchResult.count
    }

    private func makeRecord(from asset: PHAsset) -> LocalAssetRecord? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = preferredResource(from: resources) else {
            return nil
        }

        return LocalAssetRecord(
            localIdentifier: asset.localIdentifier,
            filename: resource.originalFilename,
            mediaKind: MediaKind(assetMediaType: asset.mediaType),
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            fileSize: resourceFileSize(resource)
        )
    }

    private func preferredResource(from resources: [PHAssetResource]) -> PHAssetResource? {
        let preferredTypes: [PHAssetResourceType] = [
            .fullSizePhoto,
            .photo,
            .fullSizeVideo,
            .video,
            .alternatePhoto,
            .pairedVideo
        ]

        for type in preferredTypes {
            if let resource = resources.first(where: { $0.type == type }) {
                return resource
            }
        }

        return resources.first
    }

    private func resourceFileSize(_ resource: PHAssetResource) -> Int64? {
        if let value = resource.value(forKey: "fileSize") as? NSNumber {
            return value.int64Value
        }

        if let value = resource.value(forKey: "fileSize") as? Int64 {
            return value
        }

        return nil
    }
}
