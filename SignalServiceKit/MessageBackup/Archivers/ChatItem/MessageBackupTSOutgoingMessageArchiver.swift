//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient

class MessageBackupTSOutgoingMessageArchiver {
    private typealias ArchiveFrameError = MessageBackup.ArchiveFrameError<MessageBackup.InteractionUniqueId>
    private typealias RestoreFrameError = MessageBackup.RestoreFrameError<MessageBackup.ChatItemId>

    private let contentsArchiver: MessageBackupTSMessageContentsArchiver
    private let editHistoryArchiver: MessageBackupTSMessageEditHistoryArchiver<TSOutgoingMessage>
    private let interactionStore: InteractionStore

    init(
        contentsArchiver: MessageBackupTSMessageContentsArchiver,
        editMessageStore: EditMessageStore,
        interactionStore: InteractionStore
    ) {
        self.contentsArchiver = contentsArchiver
        self.editHistoryArchiver = MessageBackupTSMessageEditHistoryArchiver(
            editMessageStore: editMessageStore
        )
        self.interactionStore = interactionStore
    }

    // MARK: - Archiving

    func archiveOutgoingMessage(
        _ outgoingMessage: TSOutgoingMessage,
        thread: TSThread,
        context: MessageBackup.ChatArchivingContext,
        tx: DBReadTransaction
    ) -> MessageBackup.ArchiveInteractionResult<Details> {
        var partialErrors = [ArchiveFrameError]()

        let outgoingMessageDetails: Details
        switch editHistoryArchiver.archiveMessageAndEditHistory(
            outgoingMessage,
            thread: thread,
            context: context,
            builder: self,
            tx: tx
        ).bubbleUp(Details.self, partialErrors: &partialErrors) {
        case .continue(let _outgoingMessageDetails):
            outgoingMessageDetails = _outgoingMessageDetails
        case .bubbleUpError(let errorResult):
            return errorResult
        }

        if partialErrors.isEmpty {
            return .success(outgoingMessageDetails)
        } else {
            return .partialFailure(outgoingMessageDetails, partialErrors)
        }
    }

    // MARK: - Restoring

    func restoreChatItem(
        _ topLevelChatItem: BackupProto_ChatItem,
        chatThread: MessageBackup.ChatThread,
        context: MessageBackup.ChatRestoringContext,
        tx: DBWriteTransaction
    ) -> MessageBackup.RestoreInteractionResult<Void> {
        var partialErrors = [RestoreFrameError]()

        guard
            editHistoryArchiver.restoreMessageAndEditHistory(
                topLevelChatItem,
                chatThread: chatThread,
                context: context,
                builder: self,
                tx: tx
            ).unwrap(partialErrors: &partialErrors)
        else {
            return .messageFailure(partialErrors)
        }

        if partialErrors.isEmpty {
            return .success(())
        } else {
            return .partialRestore((), partialErrors)
        }
    }
}

// MARK: -

private extension MessageBackup {
    /// Maps cases in ``BackupProto_SendStatus/Failed/FailureReason`` to raw
    /// error codes used in ``TSOutgoingMessageRecipientState/errorCode``.
    enum SendStatusFailureErrorCode: Int {
        /// Derived from ``OWSErrorCode/untrustedIdentity``, which is itself
        /// used in ``UntrustedIdentityError``.
        case identityKeyMismatch = 777427

        /// ``TSOutgoingMessageRecipientState/errorCode`` can contain literally
        /// the error code of any error thrown during message sending. To that
        /// end, we don't know what persisted error codes refer, now or in the
        /// past, to a network error. However, we want to be able to export
        /// network errors that we previously restored from a backup.
        ///
        /// This case serves as a sentinel value for network errors restored
        /// from a backup, so we can round-trip export them as network errors.
        ///
        /// - SeeAlso ``MessageSender``
        case networkError = 123456

        /// Derived from ``OWSErrorCode/genericFailure``.
        case unknown = 32

        /// Non-failable init where unknown raw values are coerced into
        /// `.unknown`.
        init(rawValue: Int) {
            switch rawValue {
            case SendStatusFailureErrorCode.identityKeyMismatch.rawValue:
                self = .identityKeyMismatch
            case SendStatusFailureErrorCode.networkError.rawValue:
                self = .networkError
            default:
                self = .unknown
            }
        }
    }
}

// MARK: - MessageBackupTSMessageEditHistoryBuilder

extension MessageBackupTSOutgoingMessageArchiver: MessageBackupTSMessageEditHistoryBuilder {
    typealias EditHistoryMessageType = TSOutgoingMessage

    // MARK: - Archiving

    func buildMessageArchiveDetails(
        message outgoingMessage: EditHistoryMessageType,
        editRecord: EditRecord?,
        context: MessageBackup.ChatArchivingContext,
        tx: any DBReadTransaction
    ) -> MessageBackup.ArchiveInteractionResult<Details> {
        var partialErrors = [ArchiveFrameError]()

        let wasAnySendSealedSender: Bool
        let outgoingDetails: BackupProto_ChatItem.OutgoingMessageDetails
        switch buildOutgoingMessageDetails(
            outgoingMessage,
            recipientContext: context.recipientContext
        ).bubbleUp(Details.self, partialErrors: &partialErrors) {
        case .continue(let (_outgoingDetails, _wasAnySendSealedSender)):
            outgoingDetails = _outgoingDetails
            wasAnySendSealedSender = _wasAnySendSealedSender
        case .bubbleUpError(let errorResult):
            return errorResult
        }

        let chatItemType: MessageBackup.InteractionArchiveDetails.ChatItemType
        switch contentsArchiver.archiveMessageContents(
            outgoingMessage,
            context: context.recipientContext,
            tx: tx
        ).bubbleUp(Details.self, partialErrors: &partialErrors) {
        case .continue(let t):
            chatItemType = t
        case .bubbleUpError(let errorResult):
            return errorResult
        }

        let details = Details(
            author: context.recipientContext.localRecipientId,
            directionalDetails: .outgoing(outgoingDetails),
            dateCreated: outgoingMessage.timestamp,
            expireStartDate: outgoingMessage.expireStartedAt,
            expiresInMs: UInt64(outgoingMessage.expiresInSeconds) * 1000,
            isSealedSender: wasAnySendSealedSender,
            chatItemType: chatItemType
        )

        if partialErrors.isEmpty {
            return .success(details)
        } else {
            return .partialFailure(details, partialErrors)
        }
    }

    private func buildOutgoingMessageDetails(
        _ message: TSOutgoingMessage,
        recipientContext: MessageBackup.RecipientArchivingContext
    ) -> MessageBackup.ArchiveInteractionResult<(
        outgoingDetails: BackupProto_ChatItem.OutgoingMessageDetails,
        wasAnySendSealedSender: Bool
    )> {
        var perRecipientErrors = [ArchiveFrameError]()

        var wasAnySendSealedSender = false
        var outgoingDetails = BackupProto_ChatItem.OutgoingMessageDetails()

        for (address, sendState) in message.recipientAddressStates ?? [:] {
            guard let recipientAddress = address.asSingleServiceIdBackupAddress()?.asArchivingAddress() else {
                perRecipientErrors.append(.archiveFrameError(
                    .invalidOutgoingMessageRecipient,
                    message.uniqueInteractionId
                ))
                continue
            }
            guard let recipientId = recipientContext[recipientAddress] else {
                perRecipientErrors.append(.archiveFrameError(
                    .referencedRecipientIdMissing(recipientAddress),
                    message.uniqueInteractionId
                ))
                continue
            }

            let deliveryStatus: BackupProto_SendStatus.OneOf_DeliveryStatus
            let statusTimestamp: UInt64
            switch sendState.state {
            case OWSOutgoingMessageRecipientState.sent:
                if let readTimestamp = sendState.readTimestamp {
                    var readStatus = BackupProto_SendStatus.Read()
                    readStatus.sealedSender = sendState.wasSentByUD

                    deliveryStatus = .read(readStatus)
                    statusTimestamp = readTimestamp.uint64Value
                } else if let viewedTimestamp = sendState.viewedTimestamp {
                    var viewedStatus = BackupProto_SendStatus.Viewed()
                    viewedStatus.sealedSender = sendState.wasSentByUD

                    deliveryStatus = .viewed(viewedStatus)
                    statusTimestamp = viewedTimestamp.uint64Value
                } else if let deliveryTimestamp = sendState.deliveryTimestamp {
                    var deliveredStatus = BackupProto_SendStatus.Delivered()
                    deliveredStatus.sealedSender = sendState.wasSentByUD

                    deliveryStatus = .delivered(deliveredStatus)
                    statusTimestamp = deliveryTimestamp.uint64Value
                } else {
                    var sentStatus = BackupProto_SendStatus.Sent()
                    sentStatus.sealedSender = sendState.wasSentByUD

                    deliveryStatus = .sent(sentStatus)
                    statusTimestamp = message.timestamp
                }
            case OWSOutgoingMessageRecipientState.failed:
                var failedStatus = BackupProto_SendStatus.Failed()
                failedStatus.reason = { () -> BackupProto_SendStatus.Failed.FailureReason in
                    guard let errorCode = sendState.errorCode?.intValue else {
                        return .unknown
                    }

                    switch MessageBackup.SendStatusFailureErrorCode(rawValue: errorCode) {
                    case .unknown:
                        return .unknown
                    case .networkError:
                        return .network
                    case .identityKeyMismatch:
                        return .identityKeyMismatch
                    }
                }()

                deliveryStatus = .failed(failedStatus)
                statusTimestamp = message.timestamp
            case OWSOutgoingMessageRecipientState.sending, OWSOutgoingMessageRecipientState.pending:
                deliveryStatus = .pending(BackupProto_SendStatus.Pending())
                statusTimestamp = message.timestamp
            case OWSOutgoingMessageRecipientState.skipped:
                deliveryStatus = .skipped(BackupProto_SendStatus.Skipped())
                statusTimestamp = message.timestamp
            }

            var sendStatus = BackupProto_SendStatus()
            sendStatus.recipientID = recipientId.value
            sendStatus.timestamp = statusTimestamp
            sendStatus.deliveryStatus = deliveryStatus

            outgoingDetails.sendStatus.append(sendStatus)

            // TODO: [Backups] I think this check is inverted
            if sendState.wasSentByUD.negated {
                wasAnySendSealedSender = true
            }
        }

        if perRecipientErrors.isEmpty {
            return .success((
                outgoingDetails: outgoingDetails,
                wasAnySendSealedSender: wasAnySendSealedSender
            ))
        } else {
            return .partialFailure(
                (
                    outgoingDetails: outgoingDetails,
                    wasAnySendSealedSender: wasAnySendSealedSender
                ),
                perRecipientErrors
            )
        }
    }

    // MARK: - Restoring

    /// An error representing a `TSMessage` failing to insert, since
    /// ``TSMessage/anyInsert`` fails silently.
    private struct MessageInsertionError: Error {}

    func restoreMessage(
        _ chatItem: BackupProto_ChatItem,
        isPastRevision: Bool,
        hasPastRevisions: Bool,
        chatThread: MessageBackup.ChatThread,
        context: MessageBackup.ChatRestoringContext,
        tx: any DBWriteTransaction
    ) -> MessageBackup.RestoreInteractionResult<EditHistoryMessageType> {
        guard let chatItemType = chatItem.item else {
            // Unrecognized item type!
            return .messageFailure([.restoreFrameError(
                .invalidProtoData(.chatItemMissingItem),
                chatItem.id
            )])
        }

        let outgoingDetails: BackupProto_ChatItem.OutgoingMessageDetails
        switch chatItem.directionalDetails {
        case .outgoing(let _outgoingDetails):
            outgoingDetails = _outgoingDetails
        case nil, .incoming, .directionless:
            return .messageFailure([.restoreFrameError(
                .invalidProtoData(.revisionOfOutgoingMessageMissingOutgoingDetails),
                chatItem.id
            )])
        }

        var partialErrors = [RestoreFrameError]()

        guard
            let contents = contentsArchiver.restoreContents(
                chatItemType,
                chatItemId: chatItem.id,
                chatThread: chatThread,
                context: context,
                tx: tx
            ).unwrap(partialErrors: &partialErrors)
        else {
            return .messageFailure(partialErrors)
        }

        let editState: TSEditState = {
            if isPastRevision {
                return .pastRevision
            } else if hasPastRevisions {
                // Outgoing messages are implicitly read.
                return .latestRevisionRead
            } else {
                return .none
            }
        }()

        guard
            let outgoingMessage = restoreAndInsertOutgoingMessage(
                chatItem: chatItem,
                contents: contents,
                outgoingDetails: outgoingDetails,
                editState: editState,
                context: context,
                chatThread: chatThread,
                tx: tx
            ).unwrap(partialErrors: &partialErrors)
        else {
            return .messageFailure(partialErrors)
        }

        guard
            contentsArchiver.restoreDownstreamObjects(
                message: outgoingMessage,
                thread: chatThread,
                chatItemId: chatItem.id,
                restoredContents: contents,
                context: context,
                tx: tx
            ).unwrap(partialErrors: &partialErrors)
        else {
            return .messageFailure(partialErrors)
        }

        if partialErrors.isEmpty {
            return .success(outgoingMessage)
        } else {
            return .partialRestore(outgoingMessage, partialErrors)
        }
    }

    private func restoreAndInsertOutgoingMessage(
        chatItem: BackupProto_ChatItem,
        contents: MessageBackup.RestoredMessageContents,
        outgoingDetails: BackupProto_ChatItem.OutgoingMessageDetails,
        editState: TSEditState,
        context: MessageBackup.ChatRestoringContext,
        chatThread: MessageBackup.ChatThread,
        tx: DBWriteTransaction
    ) -> MessageBackup.RestoreInteractionResult<TSOutgoingMessage> {
        guard SDS.fitsInInt64(chatItem.dateSent), chatItem.dateSent > 0 else {
            return .messageFailure([.restoreFrameError(
                .invalidProtoData(.chatItemInvalidDateSent),
                chatItem.id
            )])
        }

        let expirationToken: VersionedDisappearingMessageToken = .token(
            forProtoExpireTimerMillis: chatItem.expiresInMs,
            // TODO: [Backups] add DM timer version to backups
            version: nil
        )

        var partialErrors = [RestoreFrameError]()

        var recipientAddressStates = [MessageBackup.InteropAddress: TSOutgoingMessageRecipientState]()
        for sendStatus in outgoingDetails.sendStatus {
            let recipientAddress: MessageBackup.InteropAddress
            let recipientID = sendStatus.destinationRecipientId
            switch context.recipientContext[recipientID] {
            case .contact(let address):
                recipientAddress = address.asInteropAddress()
            case .none:
                // Missing recipient! Fail this one recipient but keep going.
                partialErrors.append(.restoreFrameError(
                    .invalidProtoData(.recipientIdNotFound(recipientID)),
                    chatItem.id
                ))
                continue
            case .localAddress, .group, .distributionList, .releaseNotesChannel:
                // Recipients can only be contacts.
                partialErrors.append(.restoreFrameError(
                    .invalidProtoData(.outgoingNonContactMessageRecipient),
                    chatItem.id
                ))
                continue
            }

            guard
                let recipientState = recipientState(
                    for: sendStatus,
                    partialErrors: &partialErrors,
                    chatItemId: chatItem.id
                )
            else {
                continue
            }

            recipientAddressStates[recipientAddress] = recipientState
        }

        if recipientAddressStates.isEmpty && outgoingDetails.sendStatus.isEmpty.negated {
            // We put up with some failures, but if we get no recipients at all
            // fail the whole thing.
            return .messageFailure(partialErrors)
        }

        let outgoingMessage: TSOutgoingMessage = {
            /// A "base" message builder, onto which we attach the data we
            /// unwrap from `contents`.
            let outgoingMessageBuilder = TSOutgoingMessageBuilder(
                thread: chatThread.tsThread,
                timestamp: chatItem.dateSent,
                receivedAtTimestamp: nil,
                messageBody: nil,
                bodyRanges: nil,
                editState: editState,
                expiresInSeconds: expirationToken.durationSeconds,
                // Backed up messages don't set the chat timer; version is irrelevant.
                expireTimerVersion: nil,
                expireStartedAt: chatItem.expireStartDate,
                // TODO: [Backups] set true if this has a single body attachment w/ voice message flag
                isVoiceMessage: false,
                groupMetaMessage: .unspecified,
                // TODO: [Backups] pass along if this is view once after proto field is added
                isViewOnceMessage: false,
                // TODO: [Backups] always treat view-once media in Backups as viewed
                isViewOnceComplete: false,
                wasRemotelyDeleted: false,
                changeActionsProtoData: nil,
                // We never restore stories.
                storyAuthorAci: nil,
                storyTimestamp: nil,
                storyReactionEmoji: nil,
                quotedMessage: nil,
                // TODO: [Backups] restore contact shares
                contactShare: nil,
                // TODO: [Backups] restore link previews
                linkPreview: nil,
                // TODO: [Backups] restore message stickers
                messageSticker: nil,
                // TODO: [Backups] restore gift badges
                giftBadge: nil
            )

            switch contents {
            case .archivedPayment(let archivedPayment):
                return OWSOutgoingArchivedPaymentMessage(
                    outgoingArchivedPaymentMessageWith: outgoingMessageBuilder,
                    amount: archivedPayment.amount,
                    fee: archivedPayment.fee,
                    note: archivedPayment.note,
                    recipientAddressStates: recipientAddressStates
                )
            case .text(let text):
                outgoingMessageBuilder.messageBody = text.body.text
                outgoingMessageBuilder.bodyRanges = text.body.ranges
                outgoingMessageBuilder.quotedMessage = text.quotedMessage

                return TSOutgoingMessage(
                    outgoingMessageWith: outgoingMessageBuilder,
                    recipientAddressStates: recipientAddressStates
                )
            case .remoteDeleteTombstone:
                outgoingMessageBuilder.wasRemotelyDeleted = true

                return TSOutgoingMessage(
                    outgoingMessageWith: outgoingMessageBuilder,
                    recipientAddressStates: recipientAddressStates
                )
            }
        }()

        interactionStore.insertInteraction(outgoingMessage, tx: tx)
        guard outgoingMessage.sqliteRowId != nil else {
            // Failed insert!
            return .messageFailure(partialErrors + [.restoreFrameError(
                .databaseInsertionFailed(MessageInsertionError()),
                chatItem.id
            )])
        }

        if partialErrors.isEmpty {
            return .success(outgoingMessage)
        } else {
            return .partialRestore(outgoingMessage, partialErrors)
        }
    }

    private func recipientState(
        for sendStatus: BackupProto_SendStatus,
        partialErrors: inout [RestoreFrameError],
        chatItemId: MessageBackup.ChatItemId
    ) -> TSOutgoingMessageRecipientState? {
        guard let deliveryStatus = sendStatus.deliveryStatus else {
            partialErrors.append(.restoreFrameError(
                .invalidProtoData(.unrecognizedMessageSendStatus),
                chatItemId
            ))
            return nil
        }

        guard let recipientState = TSOutgoingMessageRecipientState() else {
            partialErrors.append(.restoreFrameError(
                .databaseInsertionFailed(OWSAssertionError("Unable to create recipient state!")),
                chatItemId
            ))
            return nil
        }

        switch deliveryStatus {
        case .pending(_):
            recipientState.state = .pending
        case .sent(let sent):
            recipientState.state = .sent
            recipientState.wasSentByUD = sent.sealedSender
        case .delivered(let delivered):
            recipientState.state = .sent
            recipientState.deliveryTimestamp = NSNumber(value: sendStatus.timestamp)
            recipientState.wasSentByUD = delivered.sealedSender
        case .read(let read):
            recipientState.state = .sent
            recipientState.readTimestamp = NSNumber(value: sendStatus.timestamp)
            recipientState.wasSentByUD = read.sealedSender
        case .viewed(let viewed):
            recipientState.state = .sent
            recipientState.viewedTimestamp = NSNumber(value: sendStatus.timestamp)
            recipientState.wasSentByUD = viewed.sealedSender
        case .skipped(_):
            recipientState.state = .skipped
        case .failed(let failed):
            let failureErrorCode: MessageBackup.SendStatusFailureErrorCode = {
                switch failed.reason {
                case .UNRECOGNIZED, .unknown: return .unknown
                case .identityKeyMismatch: return .identityKeyMismatch
                case .network: return .networkError
                }
            }()

            recipientState.state = .failed
            recipientState.errorCode = NSNumber(value: failureErrorCode.rawValue)
        }

        return recipientState
    }
}
