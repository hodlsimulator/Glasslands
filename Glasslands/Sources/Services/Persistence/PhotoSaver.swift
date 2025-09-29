//
//  PhotoSaver.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import UIKit
import Photos

enum PhotoSaverError: Error { case notAuthorized, saveFailed }

enum PhotoSaver {
    private static func requestAddOnlyAccess() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                if status == .authorized { c.resume() }
                else { c.resume(throwing: PhotoSaverError.notAuthorized) }
            }
        }
    }

    static func saveImageToPhotos(_ image: UIImage) async throws {
        try await requestAddOnlyAccess()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }, completionHandler: { success, error in
                if let error { c.resume(throwing: error) }
                else if success { c.resume() }
                else { c.resume(throwing: PhotoSaverError.saveFailed) }
            })
        }
    }
}
