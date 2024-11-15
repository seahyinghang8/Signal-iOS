//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

enum MessageBackupKeyMaterialError: Error {
    case invalidKeyInfo
    case missingMasterKey
    case notRegistered
    case invalidEncryptionKey
}

public enum MediaEncryptionType {
    case attachment
    case thumbnail
}

public struct MediaEncryptionMetadata {
    let type: MediaEncryptionType
    let mediaId: Data
    let hmacKey: Data
    let encryptionKey: Data
    let iv: Data
}

public protocol MessageBackupKeyMaterial {

    /// Backup ID material derived from a combination of the backup key and the
    /// local ACI.  This ID is used both as the salt for the backup encryption and
    /// to create the anonymous credentials for interacting with server stored backups
    func backupID(localAci: Aci, tx: DBReadTransaction) throws -> Data

    /// Private key derived from the BackupKey + ACI that is used for signing backup auth presentations.
    func backupPrivateKey(localAci: Aci, tx: DBReadTransaction) throws -> PrivateKey

    /// LibSignal.BackupAuthCredentialRequestContext derived from the ACI and BackupKey and used primarily
    /// for building backup credentials.
    func backupAuthRequestContext(localAci: Aci, tx: DBReadTransaction) throws -> BackupAuthCredentialRequestContext

    func messageBackupKey(localAci: Aci, tx: DBReadTransaction) throws -> MessageBackupKey

    func mediaEncryptionMetadata(
        localAci: Aci,
        mediaName: String,
        type: MediaEncryptionType,
        tx: any DBReadTransaction
    ) throws -> MediaEncryptionMetadata

    /// Builds an encrypting StreamTransform object derived from the backup master key and the backupID
    func createEncryptingStreamTransform(localAci: Aci, tx: DBReadTransaction) throws -> EncryptingStreamTransform

    func createDecryptingStreamTransform(localAci: Aci, tx: DBReadTransaction) throws -> DecryptingStreamTransform

    func createHmacGeneratingStreamTransform(localAci: Aci, tx: DBReadTransaction) throws -> HmacStreamTransform

    func createHmacValidatingStreamTransform(localAci: Aci, tx: DBReadTransaction) throws -> HmacStreamTransform
}
