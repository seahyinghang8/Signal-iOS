//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

extension MessageBackup {

    /// Represents message content "types" as they are represented in iOS code, after
    /// being mapped from their representation in the backup proto. For example, normal
    /// text messages and quoted replies are a single "type" in the proto, but have separate
    /// class structures in the iOS code.
    ///
    /// This object will be passed back into the ``MessageBackupTSMessageContentsArchiver`` class
    /// after the TSMessage has been created, so that downstream objects that require the TSMessage exist
    /// can be created afterwards. Anything needed for that step, but not needed to create the TSMessage,
    /// should be made a fileprivate variable in these structs.
    enum RestoredMessageContents {
        struct Text {
            let body: MessageBody
            let quotedMessage: TSQuotedMessage?
            let linkPreview: OWSLinkPreview?

            fileprivate let reactions: [BackupProto_Reaction]
            fileprivate let bodyAttachments: [BackupProto_MessageAttachment]
            fileprivate let quotedMessageThumbnail: BackupProto_MessageAttachment?
            fileprivate let linkPreviewImage: BackupProto_FilePointer?
        }

        struct Payment {
            enum Status {
                case success(BackupProto_PaymentNotification.TransactionDetails.Transaction.Status)
                case failure(BackupProto_PaymentNotification.TransactionDetails.FailedTransaction.FailureReason)
            }

            let amount: String?
            let fee: String?
            let note: String?

            fileprivate let status: Status
            fileprivate let payment: BackupProto_PaymentNotification.TransactionDetails.Transaction?
        }

        case archivedPayment(Payment)
        case text(Text)
        case remoteDeleteTombstone
    }
}

class MessageBackupTSMessageContentsArchiver: MessageBackupProtoArchiver {

    typealias ChatItemType = MessageBackup.InteractionArchiveDetails.ChatItemType

    typealias ArchiveInteractionResult = MessageBackup.ArchiveInteractionResult
    typealias RestoreInteractionResult = MessageBackup.RestoreInteractionResult

    private typealias ArchiveFrameError = MessageBackup.ArchiveFrameError<MessageBackup.InteractionUniqueId>
    private typealias RestoreFrameError = MessageBackup.RestoreFrameError<MessageBackup.ChatItemId>

    private let interactionStore: InteractionStore
    private let archivedPaymentStore: ArchivedPaymentStore
    private let attachmentsArchiver: MessageBackupMessageAttachmentArchiver
    private let reactionArchiver: MessageBackupReactionArchiver

    init(
        interactionStore: InteractionStore,
        archivedPaymentStore: ArchivedPaymentStore,
        attachmentsArchiver: MessageBackupMessageAttachmentArchiver,
        reactionArchiver: MessageBackupReactionArchiver
    ) {
        self.interactionStore = interactionStore
        self.archivedPaymentStore = archivedPaymentStore
        self.attachmentsArchiver = attachmentsArchiver
        self.reactionArchiver = reactionArchiver
    }

    // MARK: - Archiving

    func archiveMessageContents(
        _ message: TSMessage,
        context: MessageBackup.RecipientArchivingContext,
        tx: DBReadTransaction
    ) -> ArchiveInteractionResult<ChatItemType> {
        if let paymentMessage = message as? OWSPaymentMessage {
            return archivePaymentMessageContents(
                paymentMessage,
                uniqueInteractionId: message.uniqueInteractionId,
                context: context,
                tx: tx
            )
        } else if let archivedPayment = message as? OWSArchivedPaymentMessage {
            return archivePaymentArchiveContents(
                archivedPayment,
                uniqueInteractionId: message.uniqueInteractionId,
                context: context,
                tx: tx
            )
        } else if let messageBody = message.body {
            return archiveStandardMessageContents(
                message,
                messageBody: messageBody,
                context: context,
                tx: tx
            )
        } else if message.wasRemotelyDeleted {
            let remoteDeletedMessage = BackupProto_RemoteDeletedMessage()
            return .success(.remoteDeletedMessage(remoteDeletedMessage))
        } else {
            // TODO: [Backups] Handle non-standard messages.
            return .notYetImplemented
        }
    }

    // MARK: -

    private func archivePaymentArchiveContents(
        _ archivedPaymentMessage: OWSArchivedPaymentMessage,
        uniqueInteractionId: MessageBackup.InteractionUniqueId,
        context: MessageBackup.RecipientArchivingContext,
        tx: DBReadTransaction
    ) -> MessageBackup.ArchiveInteractionResult<ChatItemType> {
        guard let historyItem = archivedPaymentStore.fetch(for: archivedPaymentMessage, tx: tx) else {
            return .messageFailure([.archiveFrameError(.missingPaymentInformation, uniqueInteractionId)])
        }

        var paymentNotificationProto = BackupProto_PaymentNotification()
        if let amount = archivedPaymentMessage.archivedPaymentInfo.amount {
            paymentNotificationProto.amountMob = amount
        }
        if let fee = archivedPaymentMessage.archivedPaymentInfo.fee {
            paymentNotificationProto.feeMob = fee
        }
        if let note = archivedPaymentMessage.archivedPaymentInfo.note {
            paymentNotificationProto.note = note
        }
        paymentNotificationProto.transactionDetails = historyItem.toTransactionDetailsProto()

        return .success(.paymentNotification(paymentNotificationProto))
    }

    private func archivePaymentMessageContents(
        _ message: OWSPaymentMessage,
        uniqueInteractionId: MessageBackup.InteractionUniqueId,
        context: MessageBackup.RecipientArchivingContext,
        tx: DBReadTransaction
    ) -> MessageBackup.ArchiveInteractionResult<ChatItemType> {
        guard
            let paymentNotification = message.paymentNotification,
            let model = PaymentFinder.paymentModels(
                forMcReceiptData: paymentNotification.mcReceiptData,
                transaction: SDSDB.shimOnlyBridge(tx)
            ).first
        else {
            return .messageFailure([.archiveFrameError(.missingPaymentInformation, uniqueInteractionId)])
        }

        var paymentNotificationProto = BackupProto_PaymentNotification()

        if
            let amount = model.paymentAmount,
            let amountString = PaymentsFormat.format(
                picoMob: amount.picoMob,
                isShortForm: true
            )
        {
            paymentNotificationProto.amountMob = amountString
        }
        if
            let fee = model.mobileCoin?.feeAmount,
            let feeString = PaymentsFormat.format(
                picoMob: fee.picoMob,
                isShortForm: true
            )
        {
            paymentNotificationProto.feeMob = feeString
        }
        if let memoMessage = paymentNotification.memoMessage {
            paymentNotificationProto.note = memoMessage
        }
        paymentNotificationProto.transactionDetails = model.asArchivedPayment().toTransactionDetailsProto()

        return .success(.paymentNotification(paymentNotificationProto))
    }

    // MARK: -

    private func archiveStandardMessageContents(
        _ message: TSMessage,
        messageBody: String,
        context: MessageBackup.RecipientArchivingContext,
        tx: DBReadTransaction
    ) -> ArchiveInteractionResult<ChatItemType> {
        var standardMessage = BackupProto_StandardMessage()
        var partialErrors = [ArchiveFrameError]()

        let text: BackupProto_Text
        let textResult = archiveText(
            MessageBody(text: messageBody, ranges: message.bodyRanges ?? .empty),
            interactionUniqueId: message.uniqueInteractionId
        )
        switch textResult.bubbleUp(ChatItemType.self, partialErrors: &partialErrors) {
        case .continue(let value):
            text = value
        case .bubbleUpError(let errorResult):
            return errorResult
        }
        standardMessage.text = text

        if let quotedMessage = message.quotedMessage {
            let quote: BackupProto_Quote
            let quoteResult = archiveQuote(
                quotedMessage,
                interactionUniqueId: message.uniqueInteractionId,
                context: context
            )
            switch quoteResult.bubbleUp(ChatItemType.self, partialErrors: &partialErrors) {
            case .continue(let _quote):
                quote = _quote
            case .bubbleUpError(let errorResult):
                return errorResult
            }

            standardMessage.quote = quote
        }

        let reactions: [BackupProto_Reaction]
        let reactionsResult = reactionArchiver.archiveReactions(
            message,
            context: context,
            tx: tx
        )
        switch reactionsResult.bubbleUp(ChatItemType.self, partialErrors: &partialErrors) {
        case .continue(let values):
            reactions = values
        case .bubbleUpError(let errorResult):
            return errorResult
        }
        standardMessage.reactions = reactions

        if partialErrors.isEmpty {
            return .success(.standardMessage(standardMessage))
        } else {
            return .partialFailure(.standardMessage(standardMessage), partialErrors)
        }
    }

    private func archiveText(
        _ messageBody: MessageBody,
        interactionUniqueId: MessageBackup.InteractionUniqueId
    ) -> ArchiveInteractionResult<BackupProto_Text> {
        var text = BackupProto_Text()
        text.body = messageBody.text

        for bodyRangeParam in messageBody.ranges.toProtoBodyRanges() {
            var bodyRange = BackupProto_BodyRange()
            bodyRange.start = bodyRangeParam.start
            bodyRange.length = bodyRangeParam.length

            if let mentionAci = Aci.parseFrom(aciString: bodyRangeParam.mentionAci) {
                bodyRange.associatedValue = .mentionAci(
                    mentionAci.serviceIdBinary.asData
                )
            } else if let style = bodyRangeParam.style {
                let backupProtoStyle: BackupProto_BodyRange.Style = {
                    switch style {
                    case .none: return .none
                    case .bold: return .bold
                    case .italic: return .italic
                    case .spoiler: return .spoiler
                    case .strikethrough: return .strikethrough
                    case .monospace: return .monospace
                    }
                }()

                bodyRange.associatedValue = .style(backupProtoStyle)
            }

            text.bodyRanges.append(bodyRange)
        }

        return .success(text)
    }

    private func archiveQuote(
        _ quotedMessage: TSQuotedMessage,
        interactionUniqueId: MessageBackup.InteractionUniqueId,
        context: MessageBackup.RecipientArchivingContext
    ) -> ArchiveInteractionResult<BackupProto_Quote> {
        var partialErrors = [ArchiveFrameError]()

        guard let authorAddress = quotedMessage.authorAddress.asSingleServiceIdBackupAddress() else {
            // Fail the whole message if we fail archiving a quote.
            return .messageFailure([.archiveFrameError(.invalidQuoteAuthor, interactionUniqueId)])
        }
        guard let authorId = context[.contact(authorAddress)] else {
            // Fail the whole message if we fail archiving a quote.
            return .messageFailure([.archiveFrameError(
                .referencedRecipientIdMissing(.contact(authorAddress)),
                interactionUniqueId
            )])
        }

        var quote = BackupProto_Quote()
        quote.authorID = authorId.value
        quote.type = quotedMessage.isGiftBadge ? .giftbadge : .normal
        if let targetSentTimestamp = quotedMessage.timestampValue?.uint64Value {
            quote.targetSentTimestamp = targetSentTimestamp
        }

        if let body = quotedMessage.body {
            let textResult = archiveText(
                MessageBody(text: body, ranges: quotedMessage.bodyRanges ?? .empty),
                interactionUniqueId: interactionUniqueId
            )
            let text: BackupProto_Text
            switch textResult.bubbleUp(BackupProto_Quote.self, partialErrors: &partialErrors) {
            case .continue(let value):
                text = value
            case .bubbleUpError(let errorResult):
                return errorResult
            }

            quote.text = { () -> BackupProto_Text in
                var quoteText = BackupProto_Text()
                quoteText.body = text.body
                quoteText.bodyRanges = text.bodyRanges
                return quoteText
            }()
        }

        // TODO: [Backups] Set attachments on the quote

        return .success(quote)
    }

    // MARK: - Restoring

    /// Parses the proto structure of message contents into
    /// into ``MessageBackup.RestoredMessageContents``, which map more directly
    /// to the ``TSMessage`` values in our database.
    ///
    /// Does NOT create the ``TSMessage``; callers are expected to utilize the
    /// restored contents to construct and insert the message.
    ///
    /// Callers MUST call ``restoreDownstreamObjects`` after creating and
    /// inserting the ``TSMessage``.
    func restoreContents(
        _ chatItemType: ChatItemType,
        chatItemId: MessageBackup.ChatItemId,
        chatThread: MessageBackup.ChatThread,
        context: MessageBackup.ChatRestoringContext,
        tx: DBWriteTransaction
    ) -> RestoreInteractionResult<MessageBackup.RestoredMessageContents> {
        switch chatItemType {
        case .paymentNotification(let paymentNotification):
            return restorePaymentNotification(
                paymentNotification,
                chatItemId: chatItemId,
                thread: chatThread,
                context: context,
                tx: tx
            )
        case .standardMessage(let standardMessage):
            return restoreStandardMessage(
                standardMessage,
                chatItemId: chatItemId,
                chatThread: chatThread,
                context: context,
                tx: tx
            )
        case .remoteDeletedMessage(_):
            return .success(.remoteDeleteTombstone)
        case .contactMessage, .stickerMessage, .giftBadge:
            // Other types not supported yet.
            return .messageFailure([.restoreFrameError(
                .unimplemented,
                chatItemId
            )])
        case .updateMessage:
            return .messageFailure([.restoreFrameError(
                .developerError(OWSAssertionError("Chat update has no contents to restore!")),
                chatItemId
            )])
        }
    }

    /// After a caller creates a ``TSMessage`` from the results of ``restoreContents``, they MUST call this method
    /// to create and insert all "downstream" objects: those that reference the ``TSMessage`` and require it for their own creation.
    ///
    /// This method will create and insert all necessary objects (e.g. reactions).
    func restoreDownstreamObjects(
        message: TSMessage,
        thread: MessageBackup.ChatThread,
        chatItemId: MessageBackup.ChatItemId,
        restoredContents: MessageBackup.RestoredMessageContents,
        context: MessageBackup.ChatRestoringContext,
        tx: DBWriteTransaction
    ) -> RestoreInteractionResult<Void> {
        guard let messageRowId = message.sqliteRowId else {
            return .messageFailure([.restoreFrameError(
                .databaseModelMissingRowId(modelClass: type(of: message)),
                chatItemId
            )])
        }

        var downstreamObjectResults = [RestoreInteractionResult<Void>]()
        switch restoredContents {
        case .archivedPayment(let archivedPayment):
            downstreamObjectResults.append(restoreArchivedPaymentContents(
                archivedPayment,
                chatItemId: chatItemId,
                thread: thread,
                message: message,
                tx: tx
            ))
        case .text(let text):
            downstreamObjectResults.append(reactionArchiver.restoreReactions(
                text.reactions,
                chatItemId: chatItemId,
                message: message,
                context: context.recipientContext,
                tx: tx
            ))
            downstreamObjectResults.append(attachmentsArchiver.restoreBodyAttachments(
                text.bodyAttachments,
                chatItemId: chatItemId,
                messageRowId: messageRowId,
                message: message,
                thread: thread,
                tx: tx
            ))
            if let quotedMessageThumbnail = text.quotedMessageThumbnail {
                downstreamObjectResults.append(attachmentsArchiver.restoreQuotedReplyThumbnailAttachment(
                    quotedMessageThumbnail,
                    chatItemId: chatItemId,
                    messageRowId: messageRowId,
                    message: message,
                    thread: thread,
                    tx: tx
                ))
            }
            if let linkPreviewImage = text.linkPreviewImage {
                downstreamObjectResults.append(attachmentsArchiver.restoreLinkPreviewAttachment(
                    linkPreviewImage,
                    chatItemId: chatItemId,
                    messageRowId: messageRowId,
                    message: message,
                    thread: thread,
                    tx: tx
                ))
            }
        case .remoteDeleteTombstone:
            // Nothing downstream to restore for a tombstone.
            downstreamObjectResults.append(.success(()))
        }

        return downstreamObjectResults.reduce(.success(()), {
            $0.combine($1)
        })
    }

    // MARK: -

    private func restoreArchivedPaymentContents(
        _ transaction: MessageBackup.RestoredMessageContents.Payment,
        chatItemId: MessageBackup.ChatItemId,
        thread: MessageBackup.ChatThread,
        message: TSMessage,
        tx: DBWriteTransaction
    ) -> MessageBackup.RestoreInteractionResult<Void> {
        let senderOrRecipientAci: Aci? = {
            switch thread.threadType {
            case .contact(let thread):
                // Payments only supported for 1:1 chats
                return thread.contactAddress.aci
            case .groupV2:
                return nil
            }
        }()

        let direction: ArchivedPayment.Direction
        switch message {
        case message as TSIncomingMessage:
            direction = .incoming
        case message as TSOutgoingMessage:
            direction = .outgoing
        default:
            return .messageFailure([.restoreFrameError(
                .developerError(OWSAssertionError("Invalid message type passed in for paymentRestore")),
                chatItemId
            )])
        }
        guard
            let senderOrRecipientAci,
            let archivedPayment = ArchivedPayment.fromBackup(
                transaction,
                senderOrRecipientAci: senderOrRecipientAci,
                direction: direction,
                interactionUniqueId: message.uniqueId
        ) else {
            return .messageFailure([.restoreFrameError(
                .invalidProtoData(.unrecognizedPaymentTransaction),
                chatItemId
            )])
        }
        archivedPaymentStore.insert(archivedPayment, tx: tx)
        return .success(())
    }

    private func restorePaymentNotification(
        _ paymentNotification: BackupProto_PaymentNotification,
        chatItemId: MessageBackup.ChatItemId,
        thread: MessageBackup.ChatThread,
        context: MessageBackup.ChatRestoringContext,
        tx: DBReadTransaction
    ) -> RestoreInteractionResult<MessageBackup.RestoredMessageContents> {
        let status: MessageBackup.RestoredMessageContents.Payment.Status
        let paymentTransaction: BackupProto_PaymentNotification.TransactionDetails.Transaction?
        if
            paymentNotification.hasTransactionDetails,
            let paymentDetails = paymentNotification.transactionDetails.payment
        {
            switch paymentDetails {
            case .failedTransaction(let failedTransaction):
                status = .failure(failedTransaction.reason)
                paymentTransaction = nil
            case .transaction(let payment):
                status = .success(payment.status)
                paymentTransaction = payment
            }
        } else {
            // Default to 'success' if there is no included information
            status = .success(.successful)
            paymentTransaction = nil
        }

        return .success(.archivedPayment(MessageBackup.RestoredMessageContents.Payment(
            amount: paymentNotification.amountMob,
            fee: paymentNotification.feeMob,
            note: paymentNotification.note,
            status: status,
            payment: paymentTransaction
        )))
    }

    // MARK: -

    private func restoreStandardMessage(
        _ standardMessage: BackupProto_StandardMessage,
        chatItemId: MessageBackup.ChatItemId,
        chatThread: MessageBackup.ChatThread,
        context: MessageBackup.ChatRestoringContext,
        tx: DBReadTransaction
    ) -> RestoreInteractionResult<MessageBackup.RestoredMessageContents> {
        var partialErrors = [RestoreFrameError]()

        let quotedMessage: TSQuotedMessage?
        let quotedMessageThumbnail: BackupProto_MessageAttachment?
        if standardMessage.hasQuote {
            guard
                let quoteResult = restoreQuote(
                    standardMessage.quote,
                    chatItemId: chatItemId,
                    thread: chatThread,
                    context: context,
                    tx: tx
                ).unwrap(partialErrors: &partialErrors)
            else {
                return .messageFailure(partialErrors)
            }
            (quotedMessage, quotedMessageThumbnail) = quoteResult
        } else {
            quotedMessage = nil
            quotedMessageThumbnail = nil
        }

        let linkPreview: OWSLinkPreview?
        let linkPreviewAttachment: BackupProto_FilePointer?
        if let linkPreviewProto = standardMessage.linkPreview.first {
            guard
                let linkPreviewResult = restoreLinkPreview(
                    linkPreviewProto,
                    standardMessage: standardMessage,
                    chatItemId: chatItemId,
                    tx: tx
                ).unwrap(partialErrors: &partialErrors)
            else {
                return .messageFailure(partialErrors)
            }
            (linkPreview, linkPreviewAttachment) = linkPreviewResult
        } else {
            linkPreview = nil
            linkPreviewAttachment = nil
        }

        guard standardMessage.hasText else {
            // TODO: [Backups] Support messages with no text
            return .messageFailure([.restoreFrameError(.unimplemented, chatItemId)])
        }
        let text = standardMessage.text

        let messageBodyResult = restoreMessageBody(text, chatItemId: chatItemId)
        switch messageBodyResult {
        case .success(let body):
            return .success(.text(.init(
                body: body,
                quotedMessage: quotedMessage,
                linkPreview: linkPreview,
                reactions: standardMessage.reactions,
                bodyAttachments: standardMessage.attachments,
                quotedMessageThumbnail: quotedMessageThumbnail,
                linkPreviewImage: linkPreviewAttachment
            )))
        case .partialRestore(let body, let partialErrors):
            return .partialRestore(
                .text(.init(
                    body: body,
                    quotedMessage: quotedMessage,
                    linkPreview: linkPreview,
                    reactions: standardMessage.reactions,
                    bodyAttachments: standardMessage.attachments,
                    quotedMessageThumbnail: quotedMessageThumbnail,
                    linkPreviewImage: linkPreviewAttachment
                )),
                partialErrors
            )
        case .messageFailure(let errors):
            return .messageFailure(errors)
        }
    }

    private func restoreMessageBody(
        _ text: BackupProto_Text,
        chatItemId: MessageBackup.ChatItemId
    ) -> RestoreInteractionResult<MessageBody> {
        return restoreMessageBody(
            text: text.body,
            bodyRangeProtos: text.bodyRanges,
            chatItemId: chatItemId
        )
    }

    private func restoreMessageBody(
        text: String,
        bodyRangeProtos: [BackupProto_BodyRange],
        chatItemId: MessageBackup.ChatItemId
    ) -> RestoreInteractionResult<MessageBody> {
        var partialErrors = [RestoreFrameError]()
        var bodyMentions = [NSRange: Aci]()
        var bodyStyles = [NSRangedValue<MessageBodyRanges.SingleStyle>]()
        for bodyRange in bodyRangeProtos {
            guard bodyRange.hasStart, bodyRange.hasLength else {
                continue
            }
            let bodyRangeStart = bodyRange.start
            let bodyRangeLength = bodyRange.length

            let range = NSRange(location: Int(bodyRangeStart), length: Int(bodyRangeLength))
            switch bodyRange.associatedValue {
            case .mentionAci(let aciData):
                guard let mentionAci = try? Aci.parseFrom(serviceIdBinary: aciData) else {
                    partialErrors.append(.restoreFrameError(
                        .invalidProtoData(.invalidAci(protoClass: BackupProto_BodyRange.self)),
                        chatItemId
                    ))
                    continue
                }
                bodyMentions[range] = mentionAci
            case .style(let protoBodyRangeStyle):
                let swiftStyle: MessageBodyRanges.SingleStyle
                switch protoBodyRangeStyle {
                case .none, .UNRECOGNIZED:
                    partialErrors.append(.restoreFrameError(
                        .invalidProtoData(.unrecognizedBodyRangeStyle),
                        chatItemId
                    ))
                    continue
                case .bold:
                    swiftStyle = .bold
                case .italic:
                    swiftStyle = .italic
                case .monospace:
                    swiftStyle = .monospace
                case .spoiler:
                    swiftStyle = .spoiler
                case .strikethrough:
                    swiftStyle = .strikethrough
                }
                bodyStyles.append(.init(swiftStyle, range: range))
            case nil:
                partialErrors.append(.restoreFrameError(
                    .invalidProtoData(.invalidAci(protoClass: BackupProto_BodyRange.self)),
                    chatItemId
                ))
                continue
            }
        }
        let bodyRanges = MessageBodyRanges(mentions: bodyMentions, styles: bodyStyles)
        let body = MessageBody(text: text, ranges: bodyRanges)
        if partialErrors.isEmpty {
            return .success(body)
        } else {
            // We still get text, albeit without any mentions or styles, if
            // we have these failures. So count as a partial restore, not
            // complete failure.
            return .partialRestore(body, partialErrors)
        }
    }

    private func restoreQuote(
        _ quote: BackupProto_Quote,
        chatItemId: MessageBackup.ChatItemId,
        thread: MessageBackup.ChatThread,
        context: MessageBackup.ChatRestoringContext,
        tx: DBReadTransaction
    ) -> RestoreInteractionResult<(TSQuotedMessage, BackupProto_MessageAttachment?)> {
        let authorAddress: MessageBackup.InteropAddress
        switch context.recipientContext[quote.authorRecipientId] {
        case .none:
            return .messageFailure([.restoreFrameError(
                .invalidProtoData(.recipientIdNotFound(quote.authorRecipientId)),
                chatItemId
            )])
        case .localAddress:
            authorAddress = context.recipientContext.localIdentifiers.aciAddress
        case .group, .distributionList, .releaseNotesChannel:
            // Groups and distritibution lists cannot be an authors of a message!
            return .messageFailure([.restoreFrameError(
                .invalidProtoData(.incomingMessageNotFromAciOrE164),
                chatItemId
            )])
        case .contact(let contactAddress):
            guard contactAddress.aci != nil || contactAddress.e164 != nil else {
                return .messageFailure([.restoreFrameError(
                    .invalidProtoData(.incomingMessageNotFromAciOrE164),
                    chatItemId
                )])
            }
            authorAddress = contactAddress.asInteropAddress()
        }

        var partialErrors = [RestoreFrameError]()

        let targetMessageTimestamp: NSNumber?
        if
            quote.hasTargetSentTimestamp,
            SDS.fitsInInt64(quote.targetSentTimestamp)
        {
            targetMessageTimestamp = NSNumber(value: quote.targetSentTimestamp)
        } else {
            targetMessageTimestamp = nil
        }

        // Try and find the targeted message, and use that as the source.
        // If this turns out to be a big perf hit, maybe we skip this and just
        // always use the contents of the proto?
        let targetMessage = findTargetMessageForQuote(quote: quote, thread: thread, tx: tx)

        let quoteBody: MessageBody?
        let bodySource: TSQuotedMessageContentSource
        if let targetMessage {
            bodySource = .local

            if let text = targetMessage.body {
                quoteBody = .init(text: text, ranges: targetMessage.bodyRanges ?? .empty)
            } else {
                quoteBody = nil
            }
        } else {
            bodySource = .remote

            if quote.hasText {
                guard let bodyResult = restoreMessageBody(
                    text: quote.text.body,
                    bodyRangeProtos: quote.text.bodyRanges,
                    chatItemId: chatItemId
                )
                    .unwrap(partialErrors: &partialErrors)
                else {
                    return .messageFailure(partialErrors)
                }
                quoteBody = bodyResult
            } else {
                quoteBody = nil
            }
        }

        let isGiftBadge: Bool
        switch quote.type {
        case .UNRECOGNIZED, .unknown, .normal:
            isGiftBadge = false
        case .giftbadge:
            isGiftBadge = true
        }

        let quotedAttachmentInfo: OWSAttachmentInfo?
        let quotedAttachmentThumbnail: BackupProto_MessageAttachment?
        if let quotedAttachmentProto = quote.attachments.first {
            if quotedAttachmentProto.hasThumbnail {
                quotedAttachmentInfo = .init(forV2ThumbnailReference: ())
                quotedAttachmentThumbnail = quotedAttachmentProto.thumbnail
            } else {
                let mimeType = quotedAttachmentProto.contentType.nilIfEmpty
                    ?? MimeType.applicationOctetStream.rawValue
                let sourceFilename = quotedAttachmentProto.fileName.nilIfEmpty
                quotedAttachmentInfo = .init(
                    stubWithMimeType: mimeType,
                    sourceFilename: sourceFilename
                )
                quotedAttachmentThumbnail = nil
            }
        } else {
            quotedAttachmentInfo = nil
            quotedAttachmentThumbnail = nil
        }

        guard quoteBody != nil || quotedAttachmentThumbnail != nil || isGiftBadge else {
            return .messageFailure([.restoreFrameError(
                .invalidProtoData(.quotedMessageEmptyContent),
                chatItemId
            )])
        }

        let quotedMessage = TSQuotedMessage(
            targetMessageTimestamp: targetMessageTimestamp,
            authorAddress: authorAddress,
            body: quoteBody?.text,
            bodyRanges: quoteBody?.ranges,
            bodySource: bodySource,
            quotedAttachmentInfo: quotedAttachmentInfo,
            isGiftBadge: isGiftBadge
        )

        if partialErrors.isEmpty {
            return .success((quotedMessage, quotedAttachmentThumbnail))
        } else {
            return .partialRestore((quotedMessage, quotedAttachmentThumbnail), partialErrors)
        }
    }

    private func findTargetMessageForQuote(
        quote: BackupProto_Quote,
        thread: MessageBackup.ChatThread,
        tx: DBReadTransaction
    ) -> TSMessage? {
        guard
            quote.hasTargetSentTimestamp,
            SDS.fitsInInt64(quote.targetSentTimestamp)
        else { return nil }

        let messageCandidates: [TSInteraction] = (try? interactionStore
            .interactions(
                withTimestamp: quote.targetSentTimestamp,
                tx: tx
            )
        ) ?? []

        let filteredMessages = messageCandidates
            .lazy
            .compactMap { $0 as? TSMessage }
            .filter { $0.uniqueThreadId == thread.tsThread.uniqueId }

        if filteredMessages.count > 1 {
            // We found more than one matching message. We don't know which
            // to use, so lets just use whats in the quote proto.
            return nil
        } else {
            return filteredMessages.first
        }
    }

    private func restoreLinkPreview(
        _ linkPreviewProto: BackupProto_LinkPreview,
        standardMessage: BackupProto_StandardMessage,
        chatItemId: MessageBackup.ChatItemId,
        tx: DBReadTransaction
    ) -> RestoreInteractionResult<(OWSLinkPreview, BackupProto_FilePointer?)> {
        guard let url = linkPreviewProto.url.nilIfEmpty else {
            return .messageFailure([.restoreFrameError(
                .invalidProtoData(.linkPreviewEmptyUrl),
                chatItemId
            )])
        }
        guard standardMessage.text.body.contains(url) else {
            return .messageFailure([.restoreFrameError(
                .invalidProtoData(.linkPreviewUrlNotInBody),
                chatItemId
            )])
        }
        let date: Date?
        if linkPreviewProto.hasDate {
            date = .init(millisecondsSince1970: linkPreviewProto.date)
        } else {
            date = nil
        }

        let metadata = OWSLinkPreview.Metadata(
            urlString: url,
            title: linkPreviewProto.title.nilIfEmpty,
            previewDescription: linkPreviewProto.description_p.nilIfEmpty,
            date: date
        )

        if linkPreviewProto.hasImage {
            let linkPreview = OWSLinkPreview.withForeignReferenceImageAttachment(
                metadata: metadata,
                ownerType: .message
            )
            return .success((linkPreview, linkPreviewProto.image))
        } else {
            let linkPreview = OWSLinkPreview.withoutImage(
                metadata: metadata,
                ownerType: .message
            )
            return .success((linkPreview, nil))
        }
    }
}

// MARK: -

private extension ArchivedPayment {
    static func fromBackup(
        _ backup: MessageBackup.RestoredMessageContents.Payment,
        senderOrRecipientAci: Aci,
        direction: Direction,
        interactionUniqueId: String?
    ) -> ArchivedPayment? {
        var archivedPayment: ArchivedPayment?
        switch backup.status {
        case .failure(let reason):
            archivedPayment = ArchivedPayment(
                amount: nil,
                fee: nil,
                note: nil,
                mobileCoinIdentification: nil,
                status: .error,
                failureReason: reason.asFailureType(),
                direction: direction,
                timestamp: nil,
                blockIndex: nil,
                blockTimestamp: nil,
                transaction: nil,
                receipt: nil,
                senderOrRecipientAci: senderOrRecipientAci,
                interactionUniqueId: interactionUniqueId
            )
        case .success(let status):
            let payment = backup.payment
            let transactionIdentifier = payment?.mobileCoinIdentification.nilIfEmpty.map {
                TransactionIdentifier(publicKey: $0.publicKey, keyImages: $0.keyImages)
            }

            archivedPayment = ArchivedPayment(
                amount: backup.amount,
                fee: backup.fee,
                note: backup.note,
                mobileCoinIdentification: transactionIdentifier,
                status: status.asStatusType(),
                failureReason: .none,
                direction: direction,
                timestamp: payment?.timestamp,
                blockIndex: payment?.blockIndex,
                blockTimestamp: payment?.blockTimestamp,
                transaction: payment?.transaction,
                receipt: payment?.receipt,
                senderOrRecipientAci: senderOrRecipientAci,
                interactionUniqueId: interactionUniqueId
            )
        }
        return archivedPayment
    }
}

private extension BackupProto_PaymentNotification.TransactionDetails.FailedTransaction.FailureReason {
    func asFailureType() -> ArchivedPayment.FailureReason {
        switch self {
        case .UNRECOGNIZED, .generic: return .genericFailure
        case .network: return .networkFailure
        case .insufficientFunds: return .insufficientFundsFailure
        }
    }
}

private extension BackupProto_PaymentNotification.TransactionDetails.Transaction.Status {
    func asStatusType() -> ArchivedPayment.Status {
        switch self {
        case .UNRECOGNIZED, .initial: return .initial
        case .submitted: return .submitted
        case .successful: return .successful
        }
    }
}

private extension BackupProto_PaymentNotification.TransactionDetails.MobileCoinTxoIdentification {
    var nilIfEmpty: Self? {
        (publicKey.isEmpty && keyImages.isEmpty) ? nil : self
    }
}
