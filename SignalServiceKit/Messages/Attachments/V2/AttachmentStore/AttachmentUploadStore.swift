//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// AttachmentStore + mutations needed for upload handling.
public protocol AttachmentUploadStore: AttachmentStore {

    /// Mark the attachment as having been uploaded to the transit tier.
    func markUploadedToTransitTier(
        attachmentStream: AttachmentStream,
        info: Attachment.TransitTierInfo,
        tx: DBWriteTransaction
    ) throws

    /// Mark the attachment as having been uploaded to the media tier.
    func markUploadedToMediaTier(
        attachmentStream: AttachmentStream,
        mediaTierInfo: Attachment.MediaTierInfo,
        tx: DBWriteTransaction
    ) throws

    func upsert(
        record: AttachmentUploadRecord,
        tx: DBWriteTransaction
    ) throws

    func removeRecord(
        for attachmentId: Attachment.IDType,
        sourceType: AttachmentUploadRecord.SourceType,
        tx: DBWriteTransaction
    ) throws

    func fetchAttachmentUploadRecord(
        for attachmentId: Attachment.IDType,
        sourceType: AttachmentUploadRecord.SourceType,
        tx: DBReadTransaction
    ) throws -> AttachmentUploadRecord?
}
