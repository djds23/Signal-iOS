//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "TSMessage.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OWSOutgoingMessageState) {
    // The failure state.
    OWSOutgoingMessageStateFailed = 0,
    // The message is either:
    // a) Enqueued for sending.
    // b) Waiting on attachment upload(s).
    // c) Being sent to the service.
    OWSOutgoingMessageStateSending,
    // The message was not sent because the recipient is not valid.
    OWSOutgoingMessageStateSkipped,
    // The message has been sent to the service.
    OWSOutgoingMessageStateSentToService,
    OWSOutgoingMessageStateDeliveredToRecipient,
    OWSOutgoingMessageStateReadByRecipient,
    
    OWSOutgoingMessageStateMin = OWSOutgoingMessageStateFailed,
    OWSOutgoingMessageStateMax = OWSOutgoingMessageStateReadByRecipient,
};

typedef NS_ENUM(NSInteger, TSGroupMetaMessage) {
    TSGroupMessageNone,
    TSGroupMessageNew,
    TSGroupMessageUpdate,
    TSGroupMessageDeliver,
    TSGroupMessageQuit,
    TSGroupMessageRequestInfo,
};

@class OWSSignalServiceProtosAttachmentPointer;
@class OWSSignalServiceProtosContentBuilder;
@class OWSSignalServiceProtosDataMessageBuilder;
@class SignalRecipient;

@interface TSOutgoingMessageRecipientState : NSObject

@property (atomic, readonly) OWSOutgoingMessageState state;
@property (atomic, nullable, readonly) NSNumber *deliveredTimestamp;
@property (atomic, nullable, readonly) NSNumber *readTimestamp;

@end

#pragma mark -

@interface TSOutgoingMessage : TSMessage

- (instancetype)initMessageWithTimestamp:(uint64_t)timestamp
                                inThread:(nullable TSThread *)thread
                             messageBody:(nullable NSString *)body
                           attachmentIds:(NSArray<NSString *> *)attachmentIds
                        expiresInSeconds:(uint32_t)expiresInSeconds
                         expireStartedAt:(uint64_t)expireStartedAt
                           quotedMessage:(nullable TSQuotedMessage *)quotedMessage NS_UNAVAILABLE;

- (instancetype)initOutgoingMessageWithTimestamp:(uint64_t)timestamp
                                        inThread:(nullable TSThread *)thread
                                     messageBody:(nullable NSString *)body
                                   attachmentIds:(NSMutableArray<NSString *> *)attachmentIds
                                expiresInSeconds:(uint32_t)expiresInSeconds
                                 expireStartedAt:(uint64_t)expireStartedAt
                                  isVoiceMessage:(BOOL)isVoiceMessage
                                groupMetaMessage:(TSGroupMetaMessage)groupMetaMessage
                                   quotedMessage:(nullable TSQuotedMessage *)quotedMessage NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithCoder:(NSCoder *)coder NS_DESIGNATED_INITIALIZER;

+ (instancetype)outgoingMessageInThread:(nullable TSThread *)thread
                            messageBody:(nullable NSString *)body
                           attachmentId:(nullable NSString *)attachmentId;

+ (instancetype)outgoingMessageInThread:(nullable TSThread *)thread
                            messageBody:(nullable NSString *)body
                           attachmentId:(nullable NSString *)attachmentId
                       expiresInSeconds:(uint32_t)expiresInSeconds;

+ (instancetype)outgoingMessageInThread:(nullable TSThread *)thread
                            messageBody:(nullable NSString *)body
                           attachmentId:(nullable NSString *)attachmentId
                       expiresInSeconds:(uint32_t)expiresInSeconds
                          quotedMessage:(nullable TSQuotedMessage *)quotedMessage;

+ (instancetype)outgoingMessageInThread:(nullable TSThread *)thread
                       groupMetaMessage:(TSGroupMetaMessage)groupMetaMessage;

//@property (atomic, readonly) TSOutgoingMessageState messageState;
//
//// The message has been sent to the service and received by at least one recipient client.
//// A recipient may have more than one client, and group message may have more than one recipient.
//@property (atomic, readonly) BOOL wasDelivered;

@property (atomic, readonly) BOOL hasSyncedTranscript;
@property (atomic, readonly) NSString *customMessage;
@property (atomic, readonly) NSString *mostRecentFailureText;
// A map of attachment id-to-"source" filename.
@property (nonatomic, readonly) NSMutableDictionary<NSString *, NSString *> *attachmentFilenameMap;

@property (atomic, readonly) TSGroupMetaMessage groupMetaMessage;

// If set, this group message should only be sent to a single recipient.
@property (atomic, readonly) NSString *singleGroupRecipient;

@property (nonatomic, readonly) BOOL isVoiceMessage;

// This property won't be accurate for legacy messages.
@property (atomic, readonly) BOOL isFromLinkedDevice;

//// Map of "recipient id"-to-"delivery time" of the recipients who have received the message.
//@property (atomic, readonly) NSDictionary<NSString *, NSNumber *> *recipientDeliveryMap;
//
//// Map of "recipient id"-to-"read time" of the recipients who have read the message.
//@property (atomic, readonly) NSDictionary<NSString *, NSNumber *> *recipientReadMap;

// Map of "recipient id"-to-"recipient state".
//
// This map is nil until the first time the message is enqueued for sending.
@property (atomic, nullable, readonly) NSDictionary<NSString *, TSOutgoingMessageRecipientState *> *recipientStateMap;

//// List of all recipients, captured the first time we enqueue the message to be sent.
//@property (atomic, readonly, nullable) NSSet<NSString *> *intendedRecipientIds;

@property (nonatomic, readonly) BOOL isSilent;

/**
 * The data representation of this message, to be encrypted, before being sent.
 */
- (NSData *)buildPlainTextData:(SignalRecipient *)recipient;

/**
 * Intermediate protobuf representation
 * Subclasses can augment if they want to manipulate the data message before building.
 */
- (OWSSignalServiceProtosDataMessageBuilder *)dataMessageBuilder;

/**
 * Should this message be synced to the users other registered devices? This is
 * generally always true, except in the case of the sync messages themseleves
 * (so we don't end up in an infinite loop).
 */
- (BOOL)shouldSyncTranscript;

/**
 * @param attachmentId
 *   id of an AttachmentStream containing the meta data used when populating the attachment proto
 *
 * @param filename
 *   optional filename of the attachment.
 *
 * @return
 *      An attachment pointer protobuf suitable for including in various container protobuf builders
 */
- (OWSSignalServiceProtosAttachmentPointer *)buildProtoForAttachmentId:(NSString *)attachmentId
                                                              filename:(nullable NSString *)filename;

- (BOOL)shouldBeSaved;

#pragma mark - Update With... Methods

- (void)updateWithRecipientState:(OWSOutgoingMessageState)state
                     recipientId:(NSString *)recipientId
                     transaction:(YapDatabaseReadWriteTransaction *)transaction;
//- (void)updateWithMessageState:(TSOutgoingMessageState)messageState;
//- (void)updateWithMessageState:(TSOutgoingMessageState)messageState
                   transaction:(YapDatabaseReadWriteTransaction *)transaction;
- (void)updateWithSendingError:(NSError *)error;
- (void)updateWithHasSyncedTranscript:(BOOL)hasSyncedTranscript
                          transaction:(YapDatabaseReadWriteTransaction *)transaction;
- (void)updateWithCustomMessage:(NSString *)customMessage transaction:(YapDatabaseReadWriteTransaction *)transaction;
- (void)updateWithCustomMessage:(NSString *)customMessage;
// deliveryTimestamp is an optional parameter, since legacy
// delivery receipts don't have a "delivery timestamp".  Those
// messages repurpose the "timestamp" field to indicate when the
// corresponding message was originally sent.
- (void)updateWithDeliveredToRecipientId:(NSString *)recipientId
                       deliveryTimestamp:(NSNumber *_Nullable)deliveryTimestamp
                             transaction:(YapDatabaseReadWriteTransaction *)transaction;
- (void)updateWithWasSentFromLinkedDeviceWithTransaction:(YapDatabaseReadWriteTransaction *)transaction;
- (void)updateWithSingleGroupRecipient:(NSString *)singleGroupRecipient
                           transaction:(YapDatabaseReadWriteTransaction *)transaction;
- (void)updateWithReadRecipientId:(NSString *)recipientId
                    readTimestamp:(uint64_t)readTimestamp
                      transaction:(YapDatabaseReadWriteTransaction *)transaction;
- (nullable NSNumber *)firstRecipientReadTimestamp;
- (void)updateWithIntendedRecipientIds:(NSSet<NSString *> *)intendedRecipientIds
                           transaction:(YapDatabaseReadWriteTransaction *)transaction;

#pragma mark - Sent Recipients

- (NSUInteger)sentRecipientsCount;
- (BOOL)wasSentToRecipient:(NSString *)contactId;
- (void)updateWithSentRecipient:(NSString *)contactId transaction:(YapDatabaseReadWriteTransaction *)transaction;

@end

NS_ASSUME_NONNULL_END
