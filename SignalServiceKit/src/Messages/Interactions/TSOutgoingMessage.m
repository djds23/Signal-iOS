//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "TSOutgoingMessage.h"
#import "NSDate+OWS.h"
#import "OWSMessageSender.h"
#import "OWSOutgoingSyncMessage.h"
#import "OWSSignalServiceProtos.pb.h"
#import "ProtoBuf+OWS.h"
#import "SignalRecipient.h"
#import "TSAttachmentStream.h"
#import "TSContactThread.h"
#import "TSGroupThread.h"
#import "TSQuotedMessage.h"
#import "TextSecureKitEnv.h"
#import <YapDatabase/YapDatabase.h>
#import <YapDatabase/YapDatabaseTransaction.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TSOutgoingMessageState) {
    // The message is either:
    // a) Enqueued for sending.
    // b) Waiting on attachment upload(s).
    // c) Being sent to the service.
    TSOutgoingMessageStateAttemptingOut,
    // The failure state.
    TSOutgoingMessageStateUnsent,
    // These two enum values have been combined into TSOutgoingMessageStateSentToService.
    TSOutgoingMessageStateSent_OBSOLETE,
    TSOutgoingMessageStateDelivered_OBSOLETE,
    // The message has been sent to the service.
    TSOutgoingMessageStateSentToService,
};

NSString *const kTSOutgoingMessageSentRecipientAll = @"kTSOutgoingMessageSentRecipientAll";

@interface TSOutgoingMessageRecipientState ()

@property (atomic) OWSOutgoingMessageState state;
@property (atomic, nullable) NSNumber *deliveredTimestamp;
@property (atomic, nullable) NSNumber *readTimestamp;

@end

#pragma mark -

@implementation TSOutgoingMessageRecipientState

@end

#pragma mark -

@interface TSOutgoingMessage ()

//@property (atomic) TSOutgoingMessageState messageState;
@property (atomic) BOOL hasSyncedTranscript;
@property (atomic) NSString *customMessage;
@property (atomic) NSString *mostRecentFailureText;
//@property (atomic) BOOL wasDelivered;
@property (atomic) NSString *singleGroupRecipient;
@property (atomic) BOOL isFromLinkedDevice;

// For outgoing, non-legacy group messages sent from this client, this
// contains the list of recipients to whom the message has been sent.
//
// This collection can also be tested to avoid repeat delivery to the
// same recipient.
//@property (atomic) NSArray<NSString *> *sentRecipients;

@property (atomic) TSGroupMetaMessage groupMetaMessage;

//@property (atomic) NSDictionary<NSString *, NSNumber *> *recipientDeliveryMap;
//
//@property (atomic) NSDictionary<NSString *, NSNumber *> *recipientReadMap;

@property (atomic, nullable) NSDictionary<NSString *, TSOutgoingMessageRecipientState *> *recipientStateMap;
//
//@property (atomic, nullable) NSSet<NSString *> *intendedRecipientIds;

@end

#pragma mark -

@implementation TSOutgoingMessage

//@synthesize sentRecipients = _sentRecipients;

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];

    if (self) {
        if (!_attachmentFilenameMap) {
            _attachmentFilenameMap = [NSMutableDictionary new];
        }
        
        if (!self.recipientStateMap) {
            [self migrateRecipientStateMapWithCoder:coder];
            OWSAssert(self.recipientStateMap);
        }
    }

    return self;
}

- (void)migrateRecipientStateMapWithCoder:(NSCoder *)coder
{
    OWSAssert(!self.recipientStateMap);
    OWSAssert(coder);

    // Migrate message state.
    TSOutgoingMessageState oldMessageState = TSOutgoingMessageStateUnsent;
    NSNumber *_Nullable messageStateValue = [coder decodeObjectForKey:@"messageState"];
    if (messageStateValue) {
        oldMessageState = (TSOutgoingMessageState) messageStateValue.intValue;
    }
    
    OWSOutgoingMessageState defaultState;
    switch (oldMessageState) {
        case TSOutgoingMessageStateUnsent:
            defaultState = OWSOutgoingMessageStateFailed;
            break;
        case TSOutgoingMessageStateAttemptingOut:
            defaultState = OWSOutgoingMessageStateSending;
            break;
        case TSOutgoingMessageStateSentToService:
        case TSOutgoingMessageStateSent_OBSOLETE:
        case TSOutgoingMessageStateDelivered_OBSOLETE:
            // Convert legacy values.
            defaultState = OWSOutgoingMessageStateSentToService;
            break;
    }
    
    NSDictionary<NSString *, NSNumber *> *_Nullable recipientDeliveryMap = [coder decodeObjectForKey:@"recipientDeliveryMap"];
    NSDictionary<NSString *, NSNumber *> *_Nullable recipientReadMap = [coder decodeObjectForKey:@"recipientReadMap"];
    
    NSMutableDictionary<NSString *, TSOutgoingMessageRecipientState *> *recipientStateMap = [NSMutableDictionary new];
    NSArray<NSString *> *recipientIds = [self.thread recipientIdentifiers];
    for (NSString *recipientId in recipientIds) {
        TSOutgoingMessageRecipientState *recipientState = [TSOutgoingMessageRecipientState new];
        
        NSNumber *_Nullable readTimestamp = recipientReadMap[recipientId];
        NSNumber *_Nullable deliveredTimestamp = recipientDeliveryMap[recipientId];
        if (readTimestamp) {
            recipientState.state = OWSOutgoingMessageStateReadByRecipient;
            recipientState.readTimestamp = readTimestamp;
        } else if (deliveredTimestamp) {
            recipientState.state = OWSOutgoingMessageStateDeliveredToRecipient;
            recipientState.deliveredTimestamp = deliveredTimestamp;
        } else {
            recipientState.state = defaultState;
        }
        
        recipientStateMap[recipientId] = recipientState;
    }
    self.recipientStateMap = [recipientStateMap copy];
}

+ (instancetype)outgoingMessageInThread:(nullable TSThread *)thread
                            messageBody:(nullable NSString *)body
                           attachmentId:(nullable NSString *)attachmentId
{
    return [self outgoingMessageInThread:thread
                             messageBody:body
                            attachmentId:attachmentId
                        expiresInSeconds:0
                           quotedMessage:nil];
}

+ (instancetype)outgoingMessageInThread:(nullable TSThread *)thread
                            messageBody:(nullable NSString *)body
                           attachmentId:(nullable NSString *)attachmentId
                       expiresInSeconds:(uint32_t)expiresInSeconds
{
    return [self outgoingMessageInThread:thread
                             messageBody:body
                            attachmentId:attachmentId
                        expiresInSeconds:expiresInSeconds
                           quotedMessage:nil];
}

+ (instancetype)outgoingMessageInThread:(nullable TSThread *)thread
                            messageBody:(nullable NSString *)body
                           attachmentId:(nullable NSString *)attachmentId
                       expiresInSeconds:(uint32_t)expiresInSeconds
                          quotedMessage:(nullable TSQuotedMessage *)quotedMessage
{
    NSMutableArray<NSString *> *attachmentIds = [NSMutableArray new];
    if (attachmentId) {
        [attachmentIds addObject:attachmentId];
    }

    TSGroupMetaMessage groupMetaMessage =
        [thread isKindOfClass:TSGroupThread.class] ? TSGroupMessageDeliver : TSGroupMessageNone;

    return [[TSOutgoingMessage alloc] initOutgoingMessageWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                                              inThread:thread
                                                           messageBody:body
                                                         attachmentIds:attachmentIds
                                                      expiresInSeconds:expiresInSeconds
                                                       expireStartedAt:0
                                                        isVoiceMessage:NO
                                                      groupMetaMessage:groupMetaMessage
                                                         quotedMessage:quotedMessage];
}

+ (instancetype)outgoingMessageInThread:(nullable TSThread *)thread
                       groupMetaMessage:(TSGroupMetaMessage)groupMetaMessage
{
    return [[TSOutgoingMessage alloc] initOutgoingMessageWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                                              inThread:thread
                                                           messageBody:nil
                                                         attachmentIds:[NSMutableArray new]
                                                      expiresInSeconds:0
                                                       expireStartedAt:0
                                                        isVoiceMessage:NO
                                                      groupMetaMessage:groupMetaMessage
                                                         quotedMessage:nil];
}

- (instancetype)initOutgoingMessageWithTimestamp:(uint64_t)timestamp
                                        inThread:(nullable TSThread *)thread
                                     messageBody:(nullable NSString *)body
                                   attachmentIds:(NSMutableArray<NSString *> *)attachmentIds
                                expiresInSeconds:(uint32_t)expiresInSeconds
                                 expireStartedAt:(uint64_t)expireStartedAt
                                  isVoiceMessage:(BOOL)isVoiceMessage
                                groupMetaMessage:(TSGroupMetaMessage)groupMetaMessage
                                   quotedMessage:(nullable TSQuotedMessage *)quotedMessage
{
    self = [super initMessageWithTimestamp:timestamp
                                  inThread:thread
                               messageBody:body
                             attachmentIds:attachmentIds
                          expiresInSeconds:expiresInSeconds
                           expireStartedAt:expireStartedAt
                             quotedMessage:quotedMessage];
    if (!self) {
        return self;
    }

    _hasSyncedTranscript = NO;
    _groupMetaMessage = groupMetaMessage;
    _isVoiceMessage = isVoiceMessage;

    _attachmentFilenameMap = [NSMutableDictionary new];

    NSMutableDictionary<NSString *, TSOutgoingMessageRecipientState *> *recipientStateMap = [NSMutableDictionary new];
    NSArray<NSString *> *recipientIds = [self.thread recipientIdentifiers];
    for (NSString *recipientId in recipientIds) {
        TSOutgoingMessageRecipientState *recipientState = [TSOutgoingMessageRecipientState new];
        recipientState.state = OWSOutgoingMessageStateSending;
        recipientStateMap[recipientId] = recipientState;
    }
    self.recipientStateMap = [recipientStateMap copy];

    return self;
}

- (BOOL)shouldBeSaved
{
    if (!(self.groupMetaMessage == TSGroupMessageDeliver || self.groupMetaMessage == TSGroupMessageNone)) {
        DDLogDebug(@"%@ Skipping save for group meta message.", self.logTag);
        return NO;
    }

    return YES;
}

- (void)saveWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    if (!self.shouldBeSaved) {
        // There's no need to save this message, since it's not displayed to the user.
        //
        // Should we find a need to save this in the future, we need to exclude any non-serializable properties.
        return;
    }

    [super saveWithTransaction:transaction];
}

- (OWSOutgoingMessageState)maxMessageState
{
    OWSOutgoingMessageState result = OWSOutgoingMessageStateMin;
    for (TSOutgoingMessageRecipientState *recipientState in self.recipientStateMap.allValues) {
        result = MAX(recipientState.state, result);
    }
    return result;
}

- (OWSOutgoingMessageState)minMessageState
{
    OWSOutgoingMessageState result = OWSOutgoingMessageStateMax;
    for (TSOutgoingMessageRecipientState *recipientState in self.recipientStateMap.allValues) {
        result = MIN(recipientState.state, result);
    }
    return result;
}

- (BOOL)shouldStartExpireTimer:(YapDatabaseReadTransaction *)transaction
{
    // It's not clear if we should wait until _all_ recipients have reached "sent or later"
    // (which could never occur if one group member is unregistered) or only wait until
    // the first recipient has reached "sent or later" (which could cause partially delivered
    // messages to expire).  For now, we'll do the latter.
    //
    // TODO: Revisit this decision.
    
    if (!self.isExpiringMessage) {
        return NO;
    } else if (self.recipientStateMap.count < 1) {
        return YES;
    } else {
        return self.maxMessageState >= OWSOutgoingMessageStateSentToService;
    }
}

- (BOOL)isSilent
{
    return NO;
}

- (OWSInteractionType)interactionType
{
    return OWSInteractionType_OutgoingMessage;
}

#pragma mark - Update With... Methods

- (void)updateWithSendingError:(NSError *)error
{
    OWSAssert(error);

    [self.dbReadWriteConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [self applyChangeToSelfAndLatestCopy:transaction
                                 changeBlock:^(TSOutgoingMessage *message) {
                                     // Mark any "sending" recipients as "failed."
                                     for (TSOutgoingMessageRecipientState *recipientState in message.recipientStateMap.allValues) {
                                         if (recipientState.state == OWSOutgoingMessageStateSending) {
                                             recipientState.state = OWSOutgoingMessageStateFailed;
                                         }
                                     }
                                     [message setMostRecentFailureText:error.localizedDescription];
                                 }];
    }];
}

- (void)updateWithRecipientState:(OWSOutgoingMessageState)state
                     recipientId:(NSString *)recipientId
                     transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(recipientId.length > 0);
    OWSAssert(transaction);
    
    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSOutgoingMessage *message) {
                                 TSOutgoingMessageRecipientState *_Nullable recipientState = message.recipientStateMap[recipientId];
                                 if (!recipientState) {
                                     OWSFail(@"%@ Missing recipient state for recipient: %@", self.logTag, recipientId);
                                     return;
                                 }
                                 recipientState.state = state;
                             }];
}

//- (void)updateWithMessageState:(TSOutgoingMessageState)messageState
//{
//    [self.dbReadWriteConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
//        [self updateWithMessageState:messageState transaction:transaction];
//    }];
//}
//
//- (void)updateWithMessageState:(TSOutgoingMessageState)messageState
//                   transaction:(YapDatabaseReadWriteTransaction *)transaction
//{
//    OWSAssert(transaction);
//
//    [self applyChangeToSelfAndLatestCopy:transaction
//                             changeBlock:^(TSOutgoingMessage *message) {
//                                 [message setMessageState:messageState];
//                             }];
//}

- (void)updateWithHasSyncedTranscript:(BOOL)hasSyncedTranscript
                          transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSOutgoingMessage *message) {
                                 [message setHasSyncedTranscript:hasSyncedTranscript];
                             }];
}

- (void)updateWithCustomMessage:(NSString *)customMessage transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(customMessage);
    OWSAssert(transaction);

    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSOutgoingMessage *message) {
                                 [message setCustomMessage:customMessage];
                             }];
}

- (void)updateWithCustomMessage:(NSString *)customMessage
{
    [self.dbReadWriteConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [self updateWithCustomMessage:customMessage transaction:transaction];
    }];
}

- (void)updateWithDeliveredToRecipientId:(NSString *)recipientId
                       deliveryTimestamp:(NSNumber *_Nullable)deliveryTimestamp
                             transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(recipientId.length > 0);
    OWSAssert(transaction);

    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSOutgoingMessage *message) {
                                 TSOutgoingMessageRecipientState *_Nullable recipientState = message.recipientStateMap[recipientId];
                                 if (!recipientState) {
                                     OWSFail(@"%@ Missing recipient state for delivered recipient: %@", self.logTag, recipientId);
                                     return;
                                 }
                                 recipientState.state = OWSOutgoingMessageStateDeliveredToRecipient;
                                 recipientState.deliveredTimestamp = deliveryTimestamp;
                             }];
}

- (void)updateWithWasSentFromLinkedDeviceWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(transaction);

    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSOutgoingMessage *message) {
                                 [message setMessageState:TSOutgoingMessageStateSentToService];
                                 [message setWasDelivered:YES];
                                 [message setIsFromLinkedDevice:YES];
                             }];
}

- (void)updateWithSingleGroupRecipient:(NSString *)singleGroupRecipient
                           transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(transaction);
    OWSAssert(singleGroupRecipient.length > 0);

    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSOutgoingMessage *message) {
                                 [message setSingleGroupRecipient:singleGroupRecipient];
                             }];
}

#pragma mark - Sent Recipients

- (NSArray<NSString *> *)sentRecipients
{
    @synchronized(self)
    {
        return _sentRecipients;
    }
}

- (void)setSentRecipients:(NSArray<NSString *> *)sentRecipients
{
    @synchronized(self)
    {
        _sentRecipients = [sentRecipients copy];
    }
}

- (void)addSentRecipient:(NSString *)contactId
{
    @synchronized(self)
    {
        OWSAssert(_sentRecipients);
        OWSAssert(contactId.length > 0);

        NSMutableArray *sentRecipients = [_sentRecipients mutableCopy];
        [sentRecipients addObject:contactId];
        _sentRecipients = [sentRecipients copy];
    }
}

- (BOOL)wasSentToRecipient:(NSString *)contactId
{
    OWSAssert(self.sentRecipients);
    OWSAssert(contactId.length > 0);

    return [self.sentRecipients containsObject:contactId];
}

- (NSUInteger)sentRecipientsCount
{
    OWSAssert(self.sentRecipients);

    return self.sentRecipients.count;
}

- (void)updateWithSentRecipient:(NSString *)contactId transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(transaction);
    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSOutgoingMessage *message) {
                                 [message addSentRecipient:contactId];
                             }];
}

- (void)updateWithReadRecipientId:(NSString *)recipientId
                    readTimestamp:(uint64_t)readTimestamp
                      transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(recipientId.length > 0);
    OWSAssert(transaction);

    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSOutgoingMessage *message) {
                                 NSMutableDictionary<NSString *, NSNumber *> *recipientReadMap
                                     = (message.recipientReadMap ? [message.recipientReadMap mutableCopy]
                                                                 : [NSMutableDictionary new]);
                                 recipientReadMap[recipientId] = @(readTimestamp);
                                 message.recipientReadMap = [recipientReadMap copy];
                             }];
}

- (nullable NSNumber *)firstRecipientReadTimestamp
{
    NSNumber *result = nil;
    for (NSNumber *timestamp in self.recipientReadMap.allValues) {
        if (!result || (result.unsignedLongLongValue > timestamp.unsignedLongLongValue)) {
            result = timestamp;
        }
    }
    return result;
}

- (void)updateWithIntendedRecipientIds:(NSSet<NSString *> *)intendedRecipientIds
                           transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(intendedRecipientIds);
    OWSAssert(transaction);

    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSOutgoingMessage *message) {
                                 message.intendedRecipientIds = [intendedRecipientIds copy];
                             }];
}

#pragma mark -

- (OWSSignalServiceProtosDataMessageBuilder *)dataMessageBuilder
{
    TSThread *thread = self.thread;
    OWSAssert(thread);
    
    OWSSignalServiceProtosDataMessageBuilder *builder = [OWSSignalServiceProtosDataMessageBuilder new];
    [builder setTimestamp:self.timestamp];


    if ([self.body lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= kOversizeTextMessageSizeThreshold) {
        [builder setBody:self.body];
    } else {
        OWSFail(@"%@ message body length too long.", self.logTag);
        NSMutableString *truncatedBody = [self.body mutableCopy];
        while ([truncatedBody lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > kOversizeTextMessageSizeThreshold) {
            DDLogError(@"%@ truncating body which is too long: %tu",
                self.logTag,
                [truncatedBody lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
            truncatedBody = [truncatedBody substringToIndex:truncatedBody.length / 2];
        }
        [builder setBody:truncatedBody];
    }
    [builder setExpireTimer:self.expiresInSeconds];
    
    // Group Messages
    BOOL attachmentWasGroupAvatar = NO;
    if ([thread isKindOfClass:[TSGroupThread class]]) {
        TSGroupThread *gThread = (TSGroupThread *)thread;
        OWSSignalServiceProtosGroupContextBuilder *groupBuilder = [OWSSignalServiceProtosGroupContextBuilder new];

        switch (self.groupMetaMessage) {
            case TSGroupMessageQuit:
                [groupBuilder setType:OWSSignalServiceProtosGroupContextTypeQuit];
                break;
            case TSGroupMessageUpdate:
            case TSGroupMessageNew: {
                if (gThread.groupModel.groupImage != nil && self.attachmentIds.count == 1) {
                    attachmentWasGroupAvatar = YES;
                    [groupBuilder setAvatar:[self buildProtoForAttachmentId:self.attachmentIds[0] filename:nil]];
                }

                [groupBuilder setMembersArray:gThread.groupModel.groupMemberIds];
                [groupBuilder setName:gThread.groupModel.groupName];
                [groupBuilder setType:OWSSignalServiceProtosGroupContextTypeUpdate];
                break;
            }
            default:
                [groupBuilder setType:OWSSignalServiceProtosGroupContextTypeDeliver];
                break;
        }
        [groupBuilder setId:gThread.groupModel.groupId];
        [builder setGroup:groupBuilder.build];
    }
    
    // Message Attachments
    if (!attachmentWasGroupAvatar) {
        NSMutableArray *attachments = [NSMutableArray new];
        for (NSString *attachmentId in self.attachmentIds) {
            NSString *_Nullable sourceFilename = self.attachmentFilenameMap[attachmentId];
            [attachments addObject:[self buildProtoForAttachmentId:attachmentId filename:sourceFilename]];
        }
        [builder setAttachmentsArray:attachments];
    }
    
    // Quoted Attachment
    TSQuotedMessage *quotedMessage = self.quotedMessage;
    if (quotedMessage) {
        OWSSignalServiceProtosDataMessageQuoteBuilder *quoteBuilder = [OWSSignalServiceProtosDataMessageQuoteBuilder new];
        [quoteBuilder setId:quotedMessage.timestamp];
        [quoteBuilder setAuthor:quotedMessage.authorId];
        
        BOOL hasQuotedText = NO;
        BOOL hasQuotedAttachment = NO;
        if (self.quotedMessage.body.length > 0) {
            hasQuotedText = YES;
            [quoteBuilder setText:quotedMessage.body];
        }

        if (quotedMessage.quotedAttachments) {
            for (OWSAttachmentInfo *attachment in quotedMessage.quotedAttachments) {
                hasQuotedAttachment = YES;

                OWSSignalServiceProtosDataMessageQuoteQuotedAttachmentBuilder *quotedAttachmentBuilder = [OWSSignalServiceProtosDataMessageQuoteQuotedAttachmentBuilder new];
                
                quotedAttachmentBuilder.contentType = attachment.contentType;
                quotedAttachmentBuilder.fileName = attachment.sourceFilename;
                if (attachment.thumbnailAttachmentStreamId) {
                    quotedAttachmentBuilder.thumbnail =
                        [self buildProtoForAttachmentId:attachment.thumbnailAttachmentStreamId];
                }

                [quoteBuilder addAttachments:[quotedAttachmentBuilder build]];
            }
        }
        
        if (hasQuotedText || hasQuotedAttachment) {
            [builder setQuoteBuilder:quoteBuilder];
        } else {
            OWSFail(@"%@ Invalid quoted message data.", self.logTag);
        }
    }
    
    return builder;
}

// recipientId is nil when building "sent" sync messages for messages sent to groups.
- (OWSSignalServiceProtosDataMessage *)buildDataMessage:(NSString *_Nullable)recipientId
{
    OWSAssert(self.thread);
    OWSSignalServiceProtosDataMessageBuilder *builder = [self dataMessageBuilder];
    [builder addLocalProfileKeyIfNecessary:self.thread recipientId:recipientId];
    
    return [[self dataMessageBuilder] build];
}

- (NSData *)buildPlainTextData:(SignalRecipient *)recipient
{
    OWSSignalServiceProtosContentBuilder *contentBuilder = [OWSSignalServiceProtosContentBuilder new];
    contentBuilder.dataMessage = [self buildDataMessage:recipient.recipientId];
    return [[contentBuilder build] data];
}

- (BOOL)shouldSyncTranscript
{
    return !self.hasSyncedTranscript;
}

- (OWSSignalServiceProtosAttachmentPointer *)buildProtoForAttachmentId:(NSString *)attachmentId
{
    OWSAssert(attachmentId.length > 0);

    TSAttachment *attachment = [TSAttachmentStream fetchObjectWithUniqueID:attachmentId];
    if (![attachment isKindOfClass:[TSAttachmentStream class]]) {
        DDLogError(@"Unexpected type for attachment builder: %@", attachment);
        return nil;
    }
    TSAttachmentStream *attachmentStream = (TSAttachmentStream *)attachment;
    return [self buildProtoForAttachmentStream:attachmentStream filename:attachmentStream.sourceFilename];
}

- (OWSSignalServiceProtosAttachmentPointer *)buildProtoForAttachmentId:(NSString *)attachmentId
                                                              filename:(nullable NSString *)filename
{
    OWSAssert(attachmentId.length > 0);

    TSAttachment *attachment = [TSAttachmentStream fetchObjectWithUniqueID:attachmentId];
    if (![attachment isKindOfClass:[TSAttachmentStream class]]) {
        DDLogError(@"Unexpected type for attachment builder: %@", attachment);
        return nil;
    }
    TSAttachmentStream *attachmentStream = (TSAttachmentStream *)attachment;
    return [self buildProtoForAttachmentStream:attachmentStream filename:filename];
}

- (OWSSignalServiceProtosAttachmentPointer *)buildProtoForAttachmentStream:(TSAttachmentStream *)attachmentStream
                                                                  filename:(nullable NSString *)filename
{
    OWSSignalServiceProtosAttachmentPointerBuilder *builder = [OWSSignalServiceProtosAttachmentPointerBuilder new];
    [builder setId:attachmentStream.serverId];
    OWSAssert(attachmentStream.contentType.length > 0);
    [builder setContentType:attachmentStream.contentType];
    DDLogVerbose(@"%@ Sending attachment with filename: '%@'", self.logTag, filename);
    [builder setFileName:filename];
    [builder setSize:attachmentStream.byteCount];
    [builder setKey:attachmentStream.encryptionKey];
    [builder setDigest:attachmentStream.digest];
    [builder setFlags:(self.isVoiceMessage ? OWSSignalServiceProtosAttachmentPointerFlagsVoiceMessage : 0)];

    if ([attachmentStream shouldHaveImageSize]) {
        CGSize imageSize = [attachmentStream imageSize];
        if (imageSize.width < NSIntegerMax && imageSize.height < NSIntegerMax) {
            NSInteger imageWidth = (NSInteger)round(imageSize.width);
            NSInteger imageHeight = (NSInteger)round(imageSize.height);
            if (imageWidth > 0 && imageHeight > 0) {
                [builder setWidth:(UInt32)imageWidth];
                [builder setHeight:(UInt32)imageHeight];
            }
        }
    }

    return [builder build];
}

@end

NS_ASSUME_NONNULL_END
