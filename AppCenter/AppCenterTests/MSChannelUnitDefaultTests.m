// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#import <Foundation/Foundation.h>

#import "MSAbstractLogInternal.h"
#import "MSAppCenter.h"
#import "MSAuthTokenContext.h"
#import "MSAuthTokenContextPrivate.h"
#import "MSAuthTokenInfo.h"
#import "MSChannelDelegate.h"
#import "MSChannelUnitConfiguration.h"
#import "MSChannelUnitDefault.h"
#import "MSChannelUnitDefaultPrivate.h"
#import "MSDevice.h"
#import "MSDispatchTestUtil.h"
#import "MSHttpIngestion.h"
#import "MSHttpTestUtil.h"
#import "MSLogContainer.h"
#import "MSServiceCommon.h"
#import "MSStorage.h"
#import "MSTestFrameworks.h"
#import "MSUserIdContext.h"
#import "MSUtility.h"

static NSTimeInterval const kMSTestTimeout = 1.0;
static NSString *const kMSTestGroupId = @"GroupId";

@interface MSChannelUnitDefault (Test)

- (void)sendLogArray:(NSArray<id<MSLog>> *__nonnull)logArray
         withBatchId:(NSString *)batchId
        andAuthToken:(MSAuthTokenValidityInfo *)tokenInfo;
- (void)flushQueueForTokenArray:(NSMutableArray<MSAuthTokenValidityInfo *> *)tokenArray withTokenIndex:(NSUInteger)tokenIndex;

@end

@interface MSChannelUnitDefaultTests : XCTestCase

@property(nonatomic) MSChannelUnitDefault *sut;

@property(nonatomic) dispatch_queue_t logsDispatchQueue;

@property(nonatomic) id configMock;
@property(nonatomic) id storageMock;
@property(nonatomic) id ingestionMock;
@property(nonatomic) id authTokenContextMock;

/**
 * Most of the channel APIs are asynchronous, this expectation is meant to be enqueued to the data dispatch queue at the end of the test
 * before any asserts. Then it will be triggered on the next queue loop right after the channel finished its job. Wrap asserts within the
 * handler of a waitForExpectationsWithTimeout method.
 */
@property(nonatomic) XCTestExpectation *channelEndJobExpectation;

@end

@implementation MSChannelUnitDefaultTests

#pragma mark - Housekeeping

- (void)setUp {
  [super setUp];

  /*
   * dispatch_get_main_queue isn't good option for logsDispatchQueue because
   * we can't clear pending actions from it after the test. It can cause usages of stopped mocks.
   */
  self.logsDispatchQueue = dispatch_queue_create("com.microsoft.appcenter.ChannelGroupQueue", DISPATCH_QUEUE_SERIAL);
  self.configMock = OCMClassMock([MSChannelUnitConfiguration class]);
  self.storageMock = OCMProtocolMock(@protocol(MSStorage));
  OCMStub([self.storageMock saveLog:OCMOCK_ANY withGroupId:OCMOCK_ANY flags:MSFlagsPersistenceNormal]).andReturn(YES);
  OCMStub([self.storageMock saveLog:OCMOCK_ANY withGroupId:OCMOCK_ANY flags:MSFlagsPersistenceCritical]).andReturn(YES);
  self.ingestionMock = OCMProtocolMock(@protocol(MSIngestionProtocol));
  OCMStub([self.ingestionMock isReadyToSend]).andReturn(YES);
  self.sut = [[MSChannelUnitDefault alloc] initWithIngestion:self.ingestionMock
                                                     storage:self.storageMock
                                               configuration:self.configMock
                                           logsDispatchQueue:self.logsDispatchQueue];

  // Auth token context.
  [MSAuthTokenContext resetSharedInstance];
  self.authTokenContextMock = OCMClassMock([MSAuthTokenContext class]);
  OCMStub([self.authTokenContextMock sharedInstance]).andReturn(self.authTokenContextMock);
  OCMStub([self.authTokenContextMock authTokenValidityArray]).andReturn(@ [[MSAuthTokenValidityInfo new]]);
}

- (void)tearDown {
  [MSDispatchTestUtil awaitAndSuspendDispatchQueue:self.logsDispatchQueue];

  // Stop mocks.
  [self.configMock stopMocking];
  [self.authTokenContextMock stopMocking];
  [MSAuthTokenContext resetSharedInstance];
  [super tearDown];
}

#pragma mark - Tests

- (void)testNewInstanceWasInitialisedCorrectly {
  assertThat(self.sut, notNilValue());
  assertThat(self.sut.configuration, equalTo(self.configMock));
  assertThat(self.sut.ingestion, equalTo(self.ingestionMock));
  assertThat(self.sut.storage, equalTo(self.storageMock));
  assertThatUnsignedLong(self.sut.itemsCount, equalToInt(0));
  OCMVerify([self.ingestionMock addDelegate:self.sut]);
}

- (void)testLogsSentWithSuccess {

  // If
  [self initChannelEndJobExpectation];
  id delegateMock = OCMProtocolMock(@protocol(MSChannelDelegate));
  __block MSSendAsyncCompletionHandler ingestionBlock;
  __block MSLogContainer *logContainer;
  __block NSString *expectedBatchId = @"1";
  NSUInteger batchSizeLimit = 1;
  id<MSLog> expectedLog = [MSAbstractLog new];
  expectedLog.sid = MS_UUID_STRING;

  // Init mocks.
  id<MSLog> enqueuedLog = [self getValidMockLog];
  __block NSString *actualAuthToken;
  OCMStub([self.ingestionMock sendAsync:OCMOCK_ANY authToken:OCMOCK_ANY completionHandler:OCMOCK_ANY]).andDo(^(NSInvocation *invocation) {
    // Get ingestion block for later call.
    [invocation retainArguments];
    [invocation getArgument:&logContainer atIndex:2];
    [invocation getArgument:&actualAuthToken atIndex:3];
    [invocation getArgument:&ingestionBlock atIndex:4];
  });
  __block id responseMock = [MSHttpTestUtil createMockResponseForStatusCode:200 headers:nil];

  // Stub the storage load for that log.
  OCMStub([self.storageMock loadLogsWithGroupId:kMSTestGroupId
                                          limit:batchSizeLimit
                             excludedTargetKeys:OCMOCK_ANY
                                      afterDate:OCMOCK_ANY
                                     beforeDate:OCMOCK_ANY
                              completionHandler:OCMOCK_ANY])
      .andDo(^(NSInvocation *invocation) {
        [invocation retainArguments];
        MSLoadDataCompletionHandler loadCallback;

        // Get ingestion block for later call.
        [invocation getArgument:&loadCallback atIndex:7];

        // Mock load.
        loadCallback(((NSArray<id<MSLog>> *)@[ expectedLog ]), expectedBatchId);
      });

  // Configure channel.
  self.sut.configuration = [[MSChannelUnitConfiguration alloc] initWithGroupId:kMSTestGroupId
                                                                      priority:MSPriorityDefault
                                                                 flushInterval:0.0
                                                                batchSizeLimit:batchSizeLimit
                                                           pendingBatchesLimit:1];

  [self.sut addDelegate:delegateMock];
  OCMReject([delegateMock channel:self.sut didFailSendingLog:OCMOCK_ANY withError:OCMOCK_ANY]);
  OCMExpect([delegateMock channel:self.sut didSucceedSendingLog:expectedLog]);
  OCMExpect([delegateMock channel:self.sut prepareLog:enqueuedLog]);
  OCMExpect([delegateMock channel:self.sut didPrepareLog:enqueuedLog internalId:OCMOCK_ANY flags:MSFlagsDefault]);
  OCMExpect([delegateMock channel:self.sut didCompleteEnqueueingLog:enqueuedLog internalId:OCMOCK_ANY]);
  OCMExpect([self.storageMock deleteLogsWithBatchId:expectedBatchId groupId:kMSTestGroupId]);

  // When
  dispatch_async(self.logsDispatchQueue, ^{
    // Enqueue now that the delegate is set.
    [self.sut enqueueItem:enqueuedLog flags:MSFlagsDefault];

    // Try to release one batch.
    dispatch_async(self.logsDispatchQueue, ^{
      XCTAssertNotNil(ingestionBlock);
      if (ingestionBlock) {
        ingestionBlock([@(1) stringValue], responseMock, nil, nil);
      }

      // Then
      dispatch_async(self.logsDispatchQueue, ^{
        [self enqueueChannelEndJobExpectation];
      });
    });
  });

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 // Get sure it has been sent.
                                 assertThat(logContainer.batchId, is(expectedBatchId));
                                 assertThat(logContainer.logs, is(@[ expectedLog ]));
                                 assertThatBool(self.sut.pendingBatchQueueFull, isFalse());
                                 assertThatUnsignedLong(self.sut.pendingBatchIds.count, equalToUnsignedLong(0));
                                 OCMVerifyAll(delegateMock);
                                 OCMVerifyAll(self.storageMock);
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                                 XCTAssertNil(actualAuthToken);
                               }];
  [responseMock stopMocking];
}

- (void)testLogsSentWithFailure {

  // If
  [self initChannelEndJobExpectation];
  id delegateMock = OCMProtocolMock(@protocol(MSChannelDelegate));
  __block MSSendAsyncCompletionHandler ingestionBlock;
  __block MSLogContainer *logContainer;
  __block NSString *expectedBatchId = @"1";
  NSUInteger batchSizeLimit = 1;
  id<MSLog> expectedLog = [MSAbstractLog new];
  expectedLog.sid = MS_UUID_STRING;

  // Init mocks.
  id<MSLog> enqueuedLog = [self getValidMockLog];
  OCMStub([self.ingestionMock sendAsync:OCMOCK_ANY authToken:OCMOCK_ANY completionHandler:OCMOCK_ANY]).andDo(^(NSInvocation *invocation) {
    // Get ingestion block for later call.
    [invocation retainArguments];
    [invocation getArgument:&ingestionBlock atIndex:4];
    [invocation getArgument:&logContainer atIndex:2];
  });
  __block id responseMock = [MSHttpTestUtil createMockResponseForStatusCode:300 headers:nil];

  // Stub the storage load for that log.
  OCMStub([self.storageMock loadLogsWithGroupId:kMSTestGroupId
                                          limit:batchSizeLimit
                             excludedTargetKeys:OCMOCK_ANY
                                      afterDate:OCMOCK_ANY
                                     beforeDate:OCMOCK_ANY
                              completionHandler:OCMOCK_ANY])
      .andDo(^(NSInvocation *invocation) {
        [invocation retainArguments];
        MSLoadDataCompletionHandler loadCallback;

        // Get ingestion block for later call.
        [invocation getArgument:&loadCallback atIndex:7];

        // Mock load.
        loadCallback(((NSArray<id<MSLog>> *)@[ expectedLog ]), expectedBatchId);
      });

  // Configure channel.
  self.sut.configuration = [[MSChannelUnitConfiguration alloc] initWithGroupId:kMSTestGroupId
                                                                      priority:MSPriorityDefault
                                                                 flushInterval:0.0
                                                                batchSizeLimit:batchSizeLimit
                                                           pendingBatchesLimit:1];
  [self.sut addDelegate:delegateMock];
  OCMExpect([delegateMock channel:self.sut didFailSendingLog:expectedLog withError:OCMOCK_ANY]);
  OCMReject([delegateMock channel:self.sut didSucceedSendingLog:OCMOCK_ANY]);
  OCMExpect([delegateMock channel:self.sut didPrepareLog:enqueuedLog internalId:OCMOCK_ANY flags:MSFlagsDefault]);
  OCMExpect([delegateMock channel:self.sut didCompleteEnqueueingLog:enqueuedLog internalId:OCMOCK_ANY]);
  OCMExpect([self.storageMock deleteLogsWithBatchId:expectedBatchId groupId:kMSTestGroupId]);

  // When
  dispatch_async(self.logsDispatchQueue, ^{
    // Enqueue now that the delegate is set.
    [self.sut enqueueItem:enqueuedLog flags:MSFlagsDefault];

    // Try to release one batch.
    dispatch_async(self.logsDispatchQueue, ^{
      XCTAssertNotNil(ingestionBlock);
      if (ingestionBlock) {
        ingestionBlock([@(1) stringValue], responseMock, nil, nil);
      }

      // Then
      [self enqueueChannelEndJobExpectation];
    });
  });

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 // Get sure it has been sent.
                                 assertThat(logContainer.batchId, is(expectedBatchId));
                                 assertThat(logContainer.logs, is(@[ expectedLog ]));
                                 assertThatBool(self.sut.pendingBatchQueueFull, isFalse());
                                 assertThatUnsignedLong(self.sut.pendingBatchIds.count, equalToUnsignedLong(0));
                                 OCMVerifyAll(delegateMock);
                                 OCMVerifyAll(self.storageMock);
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
  [responseMock stopMocking];
}

- (void)testEnqueuingItemsWillIncreaseCounter {

  // If
  [self initChannelEndJobExpectation];
  MSChannelUnitConfiguration *config = [[MSChannelUnitConfiguration alloc] initWithGroupId:kMSTestGroupId
                                                                                  priority:MSPriorityDefault
                                                                             flushInterval:5
                                                                            batchSizeLimit:10
                                                                       pendingBatchesLimit:3];
  self.sut.configuration = config;
  int itemsToAdd = 3;

  // When
  for (int i = 1; i <= itemsToAdd; i++) {
    [self.sut enqueueItem:[self getValidMockLog] flags:MSFlagsDefault];
  }
  [self enqueueChannelEndJobExpectation];

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 assertThatUnsignedLong(self.sut.itemsCount, equalToInt(itemsToAdd));
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testNotCheckingPendingLogsOnEnqueueFailure {

  // If
  [self initChannelEndJobExpectation];
  self.sut.configuration = [[MSChannelUnitConfiguration alloc] initWithGroupId:kMSTestGroupId
                                                                      priority:MSPriorityDefault
                                                                 flushInterval:5
                                                                batchSizeLimit:10
                                                           pendingBatchesLimit:3];
  self.sut.storage = self.storageMock = OCMProtocolMock(@protocol(MSStorage));
  OCMStub([self.storageMock saveLog:OCMOCK_ANY withGroupId:OCMOCK_ANY flags:MSFlagsDefault]).andReturn(NO);
  id channelUnitMock = OCMPartialMock(self.sut);
  OCMReject([channelUnitMock checkPendingLogs]);
  int itemsToAdd = 3;

  // When
  for (int i = 1; i <= itemsToAdd; i++) {
    [self.sut enqueueItem:[self getValidMockLog] flags:MSFlagsDefault];
  }
  [self enqueueChannelEndJobExpectation];

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 assertThatUnsignedLong(self.sut.itemsCount, equalToInt(0));
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
  [channelUnitMock stopMocking];
}

- (void)testEnqueueCriticalItem {

  // If
  [self initChannelEndJobExpectation];
  id<MSLog> mockLog = [self getValidMockLog];

  // When
  [self.sut enqueueItem:mockLog flags:MSFlagsPersistenceCritical];
  [self enqueueChannelEndJobExpectation];

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 OCMVerify([self.storageMock saveLog:mockLog withGroupId:OCMOCK_ANY flags:MSFlagsPersistenceCritical]);
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testEnqueueNonCriticalItem {

  // If
  [self initChannelEndJobExpectation];
  id<MSLog> mockLog = [self getValidMockLog];

  // When
  [self.sut enqueueItem:mockLog flags:MSFlagsPersistenceNormal];
  [self enqueueChannelEndJobExpectation];

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 OCMVerify([self.storageMock saveLog:mockLog withGroupId:OCMOCK_ANY flags:MSFlagsPersistenceNormal]);
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testEnqueueItemWithFlagsDefault {

  // If
  [self initChannelEndJobExpectation];
  id<MSLog> mockLog = [self getValidMockLog];

  // When
  [self.sut enqueueItem:mockLog flags:MSFlagsDefault];
  [self enqueueChannelEndJobExpectation];

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 OCMVerify([self.storageMock saveLog:mockLog withGroupId:OCMOCK_ANY flags:MSFlagsDefault]);
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testQueueFlushedAfterBatchSizeReached {

  // If
  [self initChannelEndJobExpectation];
  self.sut.configuration = [[MSChannelUnitConfiguration alloc] initWithGroupId:kMSTestGroupId
                                                                      priority:MSPriorityDefault
                                                                 flushInterval:0.0
                                                                batchSizeLimit:3
                                                           pendingBatchesLimit:3];
  int itemsToAdd = 3;
  XCTestExpectation *expectation = [self expectationWithDescription:@"All items enqueued"];
  id<MSLog> mockLog = [self getValidMockLog];
  id delegateMock = OCMProtocolMock(@protocol(MSChannelDelegate));
  OCMStub([delegateMock channel:self.sut didCompleteEnqueueingLog:mockLog internalId:OCMOCK_ANY])
      .andDo(^(__unused NSInvocation *invocation) {
        static int count = 0;
        count++;
        if (count == itemsToAdd) {
          [expectation fulfill];
        }
      });
  [self.sut addDelegate:delegateMock];

  // When
  for (int i = 0; i < itemsToAdd; ++i) {
    [self.sut enqueueItem:mockLog flags:MSFlagsPersistenceCritical];
  }
  [self enqueueChannelEndJobExpectation];

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 assertThatUnsignedLong(self.sut.itemsCount, equalToInt(0));
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testBatchQueueLimit {

  // If
  [self initChannelEndJobExpectation];
  NSUInteger batchSizeLimit = 1;
  __block int currentBatchId = 1;
  __block NSMutableArray<NSString *> *sentBatchIds = [NSMutableArray new];
  NSUInteger expectedMaxPendingBatched = 2;
  id<MSLog> expectedLog = [MSAbstractLog new];
  expectedLog.sid = MS_UUID_STRING;

  // Set up mock and stubs.
  OCMStub([self.ingestionMock sendAsync:OCMOCK_ANY authToken:OCMOCK_ANY completionHandler:OCMOCK_ANY]).andDo(^(NSInvocation *invocation) {
    [invocation retainArguments];
    MSLogContainer *container;
    [invocation getArgument:&container atIndex:2];
    if (container) {
      [sentBatchIds addObject:container.batchId];
    }
  });
  OCMStub([self.storageMock loadLogsWithGroupId:kMSTestGroupId
                                          limit:batchSizeLimit
                             excludedTargetKeys:OCMOCK_ANY
                                      afterDate:OCMOCK_ANY
                                     beforeDate:OCMOCK_ANY
                              completionHandler:OCMOCK_ANY])
      .andDo(^(NSInvocation *invocation) {
        [invocation retainArguments];
        MSLoadDataCompletionHandler loadCallback;

        // Mock load.
        [invocation getArgument:&loadCallback atIndex:7];
        loadCallback(((NSArray<id<MSLog>> *)@[ expectedLog ]), [@(currentBatchId++) stringValue]);
      });
  self.sut.configuration = [[MSChannelUnitConfiguration alloc] initWithGroupId:kMSTestGroupId
                                                                      priority:MSPriorityDefault
                                                                 flushInterval:0.0
                                                                batchSizeLimit:batchSizeLimit
                                                           pendingBatchesLimit:expectedMaxPendingBatched];

  // When
  for (NSUInteger i = 1; i <= expectedMaxPendingBatched + 1; i++) {
    [self.sut enqueueItem:[self getValidMockLog] flags:MSFlagsDefault];
  }
  [self enqueueChannelEndJobExpectation];

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 assertThatUnsignedLong(self.sut.pendingBatchIds.count, equalToUnsignedLong(expectedMaxPendingBatched));
                                 assertThatUnsignedLong(sentBatchIds.count, equalToUnsignedLong(expectedMaxPendingBatched));
                                 assertThat(sentBatchIds[0], is(@"1"));
                                 assertThat(sentBatchIds[1], is(@"2"));
                                 assertThatBool(self.sut.pendingBatchQueueFull, isTrue());
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testNextBatchSentIfPendingQueueGotRoomAgain {

  // If
  [self initChannelEndJobExpectation];
  XCTestExpectation *oneLogSentExpectation = [self expectationWithDescription:@"One log sent"];
  __block MSSendAsyncCompletionHandler ingestionBlock;
  __block MSLogContainer *lastBatchLogContainer;
  __block int currentBatchId = 1;
  NSUInteger batchSizeLimit = 1;
  id<MSLog> expectedLog = [MSAbstractLog new];
  expectedLog.sid = MS_UUID_STRING;

  // Init mocks.
  OCMStub([self.ingestionMock sendAsync:OCMOCK_ANY authToken:OCMOCK_ANY completionHandler:OCMOCK_ANY]).andDo(^(NSInvocation *invocation) {
    // Get ingestion block for later call.
    [invocation retainArguments];
    [invocation getArgument:&ingestionBlock atIndex:4];
    [invocation getArgument:&lastBatchLogContainer atIndex:2];
  });
  __block id responseMock = [MSHttpTestUtil createMockResponseForStatusCode:200 headers:nil];

  // Stub the storage load for that log.
  OCMStub([self.storageMock loadLogsWithGroupId:kMSTestGroupId
                                          limit:batchSizeLimit
                             excludedTargetKeys:OCMOCK_ANY
                                      afterDate:OCMOCK_ANY
                                     beforeDate:OCMOCK_ANY
                              completionHandler:OCMOCK_ANY])
      .andDo(^(NSInvocation *invocation) {
        [invocation retainArguments];
        MSLoadDataCompletionHandler loadCallback;

        // Get ingestion block for later call.
        [invocation getArgument:&loadCallback atIndex:7];

        // Mock load.
        loadCallback(((NSArray<id<MSLog>> *)@[ expectedLog ]), [@(currentBatchId) stringValue]);
      });

  // Configure channel.
  self.sut.configuration = [[MSChannelUnitConfiguration alloc] initWithGroupId:kMSTestGroupId
                                                                      priority:MSPriorityDefault
                                                                 flushInterval:0.0
                                                                batchSizeLimit:batchSizeLimit
                                                           pendingBatchesLimit:1];

  // When
  [self.sut enqueueItem:[self getValidMockLog] flags:MSFlagsDefault];

  // Try to release one batch.
  dispatch_async(self.logsDispatchQueue, ^{
    XCTAssertNotNil(ingestionBlock);
    if (ingestionBlock) {
      ingestionBlock([@(1) stringValue], responseMock, nil, nil);
    }

    // Then
    dispatch_async(self.logsDispatchQueue, ^{
      // Batch queue should not be full;
      assertThatBool(self.sut.pendingBatchQueueFull, isFalse());
      [oneLogSentExpectation fulfill];

      // When
      // Send another batch.
      currentBatchId++;
      [self.sut enqueueItem:[self getValidMockLog] flags:MSFlagsDefault];
      [self enqueueChannelEndJobExpectation];
    });
  });

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 // Get sure it has been sent.
                                 assertThat(lastBatchLogContainer.batchId, is([@(currentBatchId) stringValue]));
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
  [responseMock stopMocking];
}

- (void)testDontForwardLogsToIngestionOnDisabled {

  // If
  [self initChannelEndJobExpectation];
  NSUInteger batchSizeLimit = 1;
  id mockLog = [self getValidMockLog];
  OCMReject([self.ingestionMock sendAsync:OCMOCK_ANY completionHandler:OCMOCK_ANY]);
  OCMStub([self.ingestionMock sendAsync:OCMOCK_ANY completionHandler:OCMOCK_ANY]);
  OCMStub([self.storageMock loadLogsWithGroupId:kMSTestGroupId
                                          limit:batchSizeLimit
                             excludedTargetKeys:OCMOCK_ANY
                                      afterDate:OCMOCK_ANY
                                     beforeDate:OCMOCK_ANY
                              completionHandler:([OCMArg invokeBlockWithArgs:((NSArray<id<MSLog>> *)@[ mockLog ]), @"1", nil])]);
  self.sut.configuration = [[MSChannelUnitConfiguration alloc] initWithGroupId:kMSTestGroupId
                                                                      priority:MSPriorityDefault
                                                                 flushInterval:0.0
                                                                batchSizeLimit:batchSizeLimit
                                                           pendingBatchesLimit:10];

  // When
  [self.sut setEnabled:NO andDeleteDataOnDisabled:NO];
  [self.sut enqueueItem:mockLog flags:MSFlagsDefault];
  [self enqueueChannelEndJobExpectation];

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 OCMVerifyAll(self.ingestionMock);
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testDeleteDataOnDisabled {

  // If
  [self initChannelEndJobExpectation];
  NSUInteger batchSizeLimit = 1;
  id mockLog = [self getValidMockLog];
  OCMStub([self.storageMock loadLogsWithGroupId:kMSTestGroupId
                                          limit:batchSizeLimit
                             excludedTargetKeys:OCMOCK_ANY
                                      afterDate:OCMOCK_ANY
                                     beforeDate:OCMOCK_ANY
                              completionHandler:([OCMArg invokeBlockWithArgs:((NSArray<id<MSLog>> *)@[ mockLog ]), @"1", nil])]);
  self.sut.configuration = [[MSChannelUnitConfiguration alloc] initWithGroupId:kMSTestGroupId
                                                                      priority:MSPriorityDefault
                                                                 flushInterval:0.0
                                                                batchSizeLimit:batchSizeLimit
                                                           pendingBatchesLimit:10];

  // When
  [self.sut enqueueItem:mockLog flags:MSFlagsDefault];
  [self.sut setEnabled:NO andDeleteDataOnDisabled:YES];
  [self enqueueChannelEndJobExpectation];

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 // Check that logs as been requested for
                                 // deletion and that there is no batch left.
                                 OCMVerify([self.storageMock deleteLogsWithGroupId:kMSTestGroupId]);
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testDontSaveLogsWhileDisabledWithDataDeletion {

  // If
  [self initChannelEndJobExpectation];
  id mockLog = [self getValidMockLog];
  OCMReject([self.storageMock saveLog:OCMOCK_ANY withGroupId:OCMOCK_ANY flags:MSFlagsDefault]);
  id delegateMock = OCMProtocolMock(@protocol(MSChannelDelegate));
  OCMStub([delegateMock channel:self.sut didCompleteEnqueueingLog:mockLog internalId:OCMOCK_ANY])
      .andDo(^(__unused NSInvocation *invocation) {
        [self enqueueChannelEndJobExpectation];
      });
  [self.sut addDelegate:delegateMock];

  // When
  [self.sut setEnabled:NO andDeleteDataOnDisabled:YES];
  [self.sut enqueueItem:mockLog flags:MSFlagsDefault];

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 assertThatBool(self.sut.discardLogs, isTrue());
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testSaveLogsAfterReEnabled {

  // If
  [self initChannelEndJobExpectation];
  [self.sut setEnabled:NO andDeleteDataOnDisabled:YES];
  id<MSLog> mockLog = [self getValidMockLog];
  id delegateMock = OCMProtocolMock(@protocol(MSChannelDelegate));
  OCMStub([delegateMock channel:self.sut didCompleteEnqueueingLog:mockLog internalId:OCMOCK_ANY])
      .andDo(^(__unused NSInvocation *invocation) {
        [self enqueueChannelEndJobExpectation];
      });
  [self.sut addDelegate:delegateMock];

  // When
  [self.sut setEnabled:YES andDeleteDataOnDisabled:NO];
  [self.sut enqueueItem:mockLog flags:MSFlagsDefault];

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 assertThatBool(self.sut.discardLogs, isFalse());
                                 OCMVerify([self.storageMock saveLog:mockLog withGroupId:OCMOCK_ANY flags:MSFlagsDefault]);
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];

  // If
  [self initChannelEndJobExpectation];
  id<MSLog> otherMockLog = [self getValidMockLog];
  [self.sut setEnabled:NO andDeleteDataOnDisabled:NO];
  OCMStub([delegateMock channel:self.sut didCompleteEnqueueingLog:otherMockLog internalId:OCMOCK_ANY])
      .andDo(^(__unused NSInvocation *invocation) {
        [self enqueueChannelEndJobExpectation];
      });

  // When
  [self.sut setEnabled:YES andDeleteDataOnDisabled:NO];
  [self.sut enqueueItem:otherMockLog flags:MSFlagsDefault];

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 assertThatBool(self.sut.discardLogs, isFalse());
                                 OCMVerify([self.storageMock saveLog:mockLog withGroupId:OCMOCK_ANY flags:MSFlagsDefault]);
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testPauseOnDisabled {

  // If
  [self initChannelEndJobExpectation];
  [self.sut setEnabled:YES andDeleteDataOnDisabled:NO];

  // When
  [self.sut setEnabled:NO andDeleteDataOnDisabled:NO];

  // Then
  [self enqueueChannelEndJobExpectation];
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 assertThatBool(self.sut.enabled, isFalse());
                                 assertThatBool(self.sut.paused, isTrue());
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testResumeOnEnabled {

  // If
  __block BOOL result1, result2;
  [self initChannelEndJobExpectation];
  id<MSIngestionProtocol> ingestionMock = OCMProtocolMock(@protocol(MSIngestionProtocol));
  self.sut.ingestion = ingestionMock;

  // When
  [self.sut setEnabled:NO andDeleteDataOnDisabled:NO];
  dispatch_async(self.logsDispatchQueue, ^{
    [self.sut ingestionDidResume:ingestionMock];
  });
  [self.sut setEnabled:YES andDeleteDataOnDisabled:NO];
  dispatch_async(self.logsDispatchQueue, ^{
    result1 = self.sut.paused;
  });
  [self.sut setEnabled:NO andDeleteDataOnDisabled:NO];
  dispatch_async(self.logsDispatchQueue, ^{
    [self.sut ingestionDidPause:ingestionMock];
    dispatch_async(self.logsDispatchQueue, ^{
      [self.sut setEnabled:YES andDeleteDataOnDisabled:NO];
    });
    dispatch_async(self.logsDispatchQueue, ^{
      result2 = self.sut.paused;
    });
    [self enqueueChannelEndJobExpectation];
  });

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 assertThatBool(result1, isFalse());
                                 assertThatBool(result2, isTrue());
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testDelegateAfterChannelDisabled {

  // If
  [self initChannelEndJobExpectation];
  id delegateMock = OCMProtocolMock(@protocol(MSChannelDelegate));
  id mockLog = [self getValidMockLog];

  // When
  [self.sut addDelegate:delegateMock];
  [self.sut setEnabled:NO andDeleteDataOnDisabled:YES];

  // Enqueue now that the delegate is set.
  dispatch_async(self.logsDispatchQueue, ^{
    [self.sut enqueueItem:mockLog flags:MSFlagsDefault];
    [self enqueueChannelEndJobExpectation];
  });

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 // Check the callbacks were invoked for logs.
                                 OCMVerify([delegateMock channel:self.sut
                                                   didPrepareLog:mockLog
                                                      internalId:OCMOCK_ANY
                                                           flags:MSFlagsDefault]);
                                 OCMVerify([delegateMock channel:self.sut didCompleteEnqueueingLog:mockLog internalId:OCMOCK_ANY]);
                                 OCMVerify([delegateMock channel:self.sut willSendLog:mockLog]);
                                 OCMVerify([delegateMock channel:self.sut didFailSendingLog:mockLog withError:anything()]);
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testDelegateAfterChannelPaused {

  // If
  NSObject *identifyingObject = [NSObject new];
  [self initChannelEndJobExpectation];
  id delegateMock = OCMProtocolMock(@protocol(MSChannelDelegate));

  // When
  [self.sut addDelegate:delegateMock];

  // Pause now that the delegate is set.
  dispatch_async(self.logsDispatchQueue, ^{
    [self.sut pauseWithIdentifyingObject:identifyingObject];
    [self enqueueChannelEndJobExpectation];
  });

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 // Check the callbacks were invoked for logs.
                                 OCMVerify([delegateMock channel:self.sut didPauseWithIdentifyingObject:identifyingObject]);
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testDelegateAfterChannelResumed {

  // If
  NSObject *identifyingObject = [NSObject new];
  [self initChannelEndJobExpectation];
  id delegateMock = OCMProtocolMock(@protocol(MSChannelDelegate));

  // When
  [self.sut addDelegate:delegateMock];

  // Resume now that the delegate is set.
  dispatch_async(self.logsDispatchQueue, ^{
    [self.sut resumeWithIdentifyingObject:identifyingObject];
    [self enqueueChannelEndJobExpectation];
  });

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 // Check the callbacks were invoked for logs.
                                 OCMVerify([delegateMock channel:self.sut didResumeWithIdentifyingObject:identifyingObject]);
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testDeviceAndTimestampAreAddedOnEnqueuing {

  // If
  id<MSLog> mockLog = [self getValidMockLog];
  mockLog.device = nil;
  mockLog.timestamp = nil;

  // When
  [self.sut enqueueItem:mockLog flags:MSFlagsDefault];

  // Then
  XCTAssertNotNil(mockLog.device);
  XCTAssertNotNil(mockLog.timestamp);
}

- (void)testDeviceAndTimestampAreNotOverwrittenOnEnqueuing {

  // If
  id<MSLog> mockLog = [self getValidMockLog];
  MSDevice *device = mockLog.device = [MSDevice new];
  NSDate *timestamp = mockLog.timestamp = [NSDate new];

  // When
  [self.sut enqueueItem:mockLog flags:MSFlagsDefault];

  // Then
  XCTAssertEqual(mockLog.device, device);
  XCTAssertEqual(mockLog.timestamp, timestamp);
}

- (void)testEnqueuingLogDoesNotPersistFilteredLogs {

  // If
  [self initChannelEndJobExpectation];
  OCMReject([self.storageMock saveLog:OCMOCK_ANY withGroupId:OCMOCK_ANY flags:MSFlagsDefault]);

  id<MSLog> log = [self getValidMockLog];
  id delegateMock = OCMProtocolMock(@protocol(MSChannelDelegate));
  OCMStub([delegateMock channelUnit:self.sut shouldFilterLog:log]).andReturn(YES);
  id delegateMock2 = OCMProtocolMock(@protocol(MSChannelDelegate));
  OCMStub([delegateMock2 channelUnit:self.sut shouldFilterLog:log]).andReturn(NO);
  OCMExpect([delegateMock channel:self.sut prepareLog:log]);
  OCMExpect([delegateMock2 channel:self.sut prepareLog:log]);
  OCMExpect([delegateMock channel:self.sut didPrepareLog:log internalId:OCMOCK_ANY flags:MSFlagsDefault]);
  OCMExpect([delegateMock2 channel:self.sut didPrepareLog:log internalId:OCMOCK_ANY flags:MSFlagsDefault]);
  OCMExpect([delegateMock channel:self.sut didCompleteEnqueueingLog:log internalId:OCMOCK_ANY]);
  OCMExpect([delegateMock2 channel:self.sut didCompleteEnqueueingLog:log internalId:OCMOCK_ANY]);
  [self.sut addDelegate:delegateMock];
  [self.sut addDelegate:delegateMock2];

  // When
  dispatch_async(self.logsDispatchQueue, ^{
    // Enqueue now that the delegate is set.
    [self.sut enqueueItem:log flags:MSFlagsDefault];
    [self enqueueChannelEndJobExpectation];
  });

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 OCMVerifyAll(delegateMock);
                                 OCMVerifyAll(delegateMock2);
                                 OCMVerifyAll(self.storageMock);
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testEnqueuingLogPersistsUnfilteredLogs {

  // If
  [self initChannelEndJobExpectation];
  id<MSLog> log = [self getValidMockLog];
  id delegateMock = OCMProtocolMock(@protocol(MSChannelDelegate));
  OCMStub([delegateMock channelUnit:self.sut shouldFilterLog:log]).andReturn(NO);
  OCMExpect([delegateMock channel:self.sut didPrepareLog:log internalId:OCMOCK_ANY flags:MSFlagsDefault]);
  OCMExpect([delegateMock channel:self.sut didCompleteEnqueueingLog:log internalId:OCMOCK_ANY]);
  [self.sut addDelegate:delegateMock];

  // When
  dispatch_async(self.logsDispatchQueue, ^{
    // Enqueue now that the delegate is set.
    [self.sut enqueueItem:log flags:MSFlagsDefault];
    [self enqueueChannelEndJobExpectation];
  });

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 OCMVerifyAll(delegateMock);
                                 OCMVerify([self.storageMock saveLog:log withGroupId:OCMOCK_ANY flags:MSFlagsDefault]);
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testDisableAndDeleteDataOnIngestionFatalError {

  // If
  id ingestionMock = OCMProtocolMock(@protocol(MSIngestionProtocol));

  // When
  [self.sut ingestionDidReceiveFatalError:ingestionMock];

  // Then
  OCMVerify([self.sut setEnabled:NO andDeleteDataOnDisabled:YES]);
}

- (void)testPauseOnIngestionPaused {

  // If
  [self initChannelEndJobExpectation];
  id ingestionMock = OCMProtocolMock(@protocol(MSIngestionProtocol));
  id delegateMock = OCMProtocolMock(@protocol(MSChannelDelegate));
  [self.sut addDelegate:delegateMock];

  // When
  [self.sut ingestionDidPause:ingestionMock];

  // Then
  [self enqueueChannelEndJobExpectation];
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                                 XCTAssertTrue([self.sut paused]);
                                 OCMVerify([delegateMock channel:self.sut didPauseWithIdentifyingObject:ingestionMock]);
                               }];
}

- (void)testResumeOnIngestionResumed {

  // If
  [self initChannelEndJobExpectation];
  id ingestionMock = OCMProtocolMock(@protocol(MSIngestionProtocol));
  id delegateMock = OCMProtocolMock(@protocol(MSChannelDelegate));
  [self.sut addDelegate:delegateMock];

  // When
  [self.sut ingestionDidResume:ingestionMock];

  // Then
  [self enqueueChannelEndJobExpectation];
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                                 XCTAssertFalse([self.sut paused]);
                                 OCMVerify([delegateMock channel:self.sut didResumeWithIdentifyingObject:ingestionMock]);
                               }];
}

- (void)testDoesntResumeWhenNotAllPauseObjectsResumed {

  // If
  [self initChannelEndJobExpectation];
  NSObject *object1 = [NSObject new];
  NSObject *object2 = [NSObject new];
  NSObject *object3 = [NSObject new];
  [self.sut pauseWithIdentifyingObject:object1];
  [self.sut pauseWithIdentifyingObject:object2];
  [self.sut pauseWithIdentifyingObject:object3];

  // When
  [self.sut resumeWithIdentifyingObject:object1];
  [self.sut resumeWithIdentifyingObject:object3];

  // Then
  [self enqueueChannelEndJobExpectation];
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                                 XCTAssertTrue([self.sut paused]);
                               }];
}

- (void)testResumesWhenAllPauseObjectsResumed {

  // If
  [self initChannelEndJobExpectation];
  NSObject *object1 = [NSObject new];
  NSObject *object2 = [NSObject new];
  NSObject *object3 = [NSObject new];
  [self.sut pauseWithIdentifyingObject:object1];
  [self.sut pauseWithIdentifyingObject:object2];
  [self.sut pauseWithIdentifyingObject:object3];

  // When
  [self.sut resumeWithIdentifyingObject:object1];
  [self.sut resumeWithIdentifyingObject:object2];
  [self.sut resumeWithIdentifyingObject:object3];

  // Then
  [self enqueueChannelEndJobExpectation];
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                                 XCTAssertFalse([self.sut paused]);
                               }];
}

- (void)testResumeWhenOnlyPausedObjectIsDeallocated {

  // If
  __weak NSObject *weakObject = nil;
  @autoreleasepool {

// Ignore warning on weak variable usage in this scope to simulate dealloc.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-unsafe-retained-assign"
    weakObject = [NSObject new];
#pragma clang diagnostic pop
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-repeated-use-of-weak"
    [self.sut pauseWithIdentifyingObjectSync:weakObject];
#pragma clang diagnostic pop
  }

  // Then
  XCTAssertTrue([self.sut paused]);

  // When
  [self.sut resumeWithIdentifyingObjectSync:[NSObject new]];

  // Then
  XCTAssertFalse([self.sut paused]);
}

- (void)testResumeWithObjectThatDoesNotExistDoesNotResumeIfCurrentlyPaused {

  // If
  [self initChannelEndJobExpectation];
  NSObject *object1 = [NSObject new];
  NSObject *object2 = [NSObject new];
  [self.sut pauseWithIdentifyingObject:object1];

  // When
  [self.sut resumeWithIdentifyingObject:object2];

  // Then
  [self enqueueChannelEndJobExpectation];
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                                 XCTAssertTrue([self.sut paused]);
                               }];
}

- (void)testResumeWithObjectThatDoesNotExistDoesNotPauseIfPreviouslyResumed {

  // When
  [self.sut resumeWithIdentifyingObjectSync:[NSObject new]];

  // Then
  XCTAssertFalse([self.sut paused]);
}

- (void)testResumeTwiceInARowResumesWhenPaused {

  // If
  NSObject *object = [NSObject new];
  [self.sut pauseWithIdentifyingObjectSync:object];

  // When
  [self.sut resumeWithIdentifyingObjectSync:object];
  [self.sut resumeWithIdentifyingObjectSync:object];

  // Then
  XCTAssertFalse([self.sut paused]);
}

- (void)testResumeOnceResumesWhenPausedTwiceWithSingleObject {

  // If
  NSObject *object = [NSObject new];
  [self.sut pauseWithIdentifyingObjectSync:object];
  [self.sut pauseWithIdentifyingObjectSync:object];

  // When
  [self.sut resumeWithIdentifyingObjectSync:object];

  // Then
  XCTAssertFalse([self.sut paused]);
}

- (void)testPausedTargetKeysNotAlteredWhenChannelUnitPaused {

  // If
  [self initChannelEndJobExpectation];
  NSObject *object = [NSObject new];
  NSString *targetKey = @"targetKey";
  NSString *token = [NSString stringWithFormat:@"%@-secret", targetKey];
  [self.sut pauseSendingLogsWithToken:token];

  // When
  [self.sut pauseWithIdentifyingObjectSync:object];

  // Then
  [self enqueueChannelEndJobExpectation];
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                                 XCTAssertTrue([self.sut.pausedTargetKeys count] == 1);
                                 XCTAssertTrue([self.sut.pausedTargetKeys containsObject:targetKey]);
                               }];
}

- (void)testPausedTargetKeysNotAlteredWhenChannelUnitResumed {

  // If
  [self initChannelEndJobExpectation];
  NSObject *object = [NSObject new];
  NSString *targetKey = @"targetKey";
  NSString *token = [NSString stringWithFormat:@"%@-secret", targetKey];
  [self.sut pauseSendingLogsWithToken:token];
  [self.sut pauseWithIdentifyingObject:object];

  // When
  [self.sut resumeWithIdentifyingObject:object];

  // Then
  [self enqueueChannelEndJobExpectation];
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                                 XCTAssertTrue([self.sut.pausedTargetKeys count] == 1);
                                 XCTAssertTrue([self.sut.pausedTargetKeys containsObject:targetKey]);
                               }];
}

- (void)testNoLogsRetrievedFromStorageWhenTargetKeyIsPaused {

  // If
  [self initChannelEndJobExpectation];
  NSString *targetKey = @"targetKey";
  NSString *token = [NSString stringWithFormat:@"%@-secret", targetKey];
  __block NSArray *excludedKeys;
  OCMStub([self.storageMock loadLogsWithGroupId:self.sut.configuration.groupId
                                          limit:self.sut.configuration.batchSizeLimit
                             excludedTargetKeys:OCMOCK_ANY
                                      afterDate:OCMOCK_ANY
                                     beforeDate:OCMOCK_ANY
                              completionHandler:OCMOCK_ANY])
      .andDo(^(NSInvocation *invocation) {
        [invocation retainArguments];
        [invocation getArgument:&excludedKeys atIndex:4];
      });
  [self.sut pauseSendingLogsWithToken:token];

  // When
  dispatch_async(self.logsDispatchQueue, ^{
    [self.sut flushQueue];
    [self enqueueChannelEndJobExpectation];
  });

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                                 XCTAssertTrue([excludedKeys count] == 1);
                                 XCTAssertTrue([excludedKeys containsObject:targetKey]);
                               }];
}

- (void)testFlushQueueIteratesThroughArrayRecursively {

  // If
  NSDate *date1 = [NSDate dateWithTimeIntervalSince1970:1];
  NSDate *date2 = [NSDate dateWithTimeIntervalSince1970:60];
  NSDate *date3 = [NSDate dateWithTimeIntervalSince1970:120];
  NSDate *date4 = [NSDate dateWithTimeIntervalSince1970:180];
  NSMutableArray<MSAuthTokenValidityInfo *> *tokenValidityArray = [NSMutableArray<MSAuthTokenValidityInfo *> new];
  MSAuthTokenValidityInfo *token1 = [[MSAuthTokenValidityInfo alloc] initWithAuthToken:@"token1" startTime:date1 endTime:date2];
  MSAuthTokenValidityInfo *token2 = [[MSAuthTokenValidityInfo alloc] initWithAuthToken:@"token2" startTime:date2 endTime:date3];
  MSAuthTokenValidityInfo *token3 = [[MSAuthTokenValidityInfo alloc] initWithAuthToken:@"token3" startTime:date3 endTime:date4];
  [tokenValidityArray addObject:token1];
  [tokenValidityArray addObject:token2];
  [tokenValidityArray addObject:token3];
  NSArray<id<MSLog>> *logsForToken1 = [self getValidMockLogArrayForDate:date1 andCount:0];
  NSArray<id<MSLog>> *logsForToken2 = [self getValidMockLogArrayForDate:date2 andCount:0];
  NSArray<id<MSLog>> *logsForToken3 = [self getValidMockLogArrayForDate:date3 andCount:5];
  NSString *batchId = @"batchId";
  __block NSDate *dateAfter;
  __block NSDate *dateBefore;
  __block MSLoadDataCompletionHandler completionHandler;

  // Stub sendLogArray part - we don't need this in this test.
  id sutMock = OCMPartialMock(self.sut);
  OCMStub([sutMock sendLogArray:OCMOCK_ANY withBatchId:OCMOCK_ANY andAuthToken:OCMOCK_ANY]);
  OCMStub([self.storageMock loadLogsWithGroupId:self.sut.configuration.groupId
                                          limit:self.sut.configuration.batchSizeLimit
                             excludedTargetKeys:OCMOCK_ANY
                                      afterDate:OCMOCK_ANY
                                     beforeDate:OCMOCK_ANY
                              completionHandler:OCMOCK_ANY])
      .andDo(^(NSInvocation *invocation) {
        [invocation retainArguments];
        [invocation getArgument:&dateAfter atIndex:(5)];
        [invocation getArgument:&dateBefore atIndex:(6)];
        [invocation getArgument:&completionHandler atIndex:7];
        if ([dateAfter isEqualToDate:date1] && [dateBefore isEqualToDate:date2]) {
          completionHandler(logsForToken1, batchId);
          return;
        }
        if ([dateAfter isEqualToDate:date2] && [dateBefore isEqualToDate:date3]) {
          completionHandler(logsForToken2, batchId);
          return;
        }
        if ([dateAfter isEqualToDate:date3] && [dateBefore isEqualToDate:date4]) {
          completionHandler(logsForToken3, batchId);
          return;
        }
      });

  // When
  [sutMock flushQueueForTokenArray:tokenValidityArray withTokenIndex:0];

  // Then
  OCMVerify([sutMock sendLogArray:logsForToken3 withBatchId:OCMOCK_ANY andAuthToken:token3]);
  [sutMock stopMocking];
}

- (void)testLogsStoredWhenTargetKeyIsPaused {

  // If
  [self initChannelEndJobExpectation];
  NSString *targetKey = @"targetKey";
  NSString *token = [NSString stringWithFormat:@"%@-secret", targetKey];
  [self.sut pauseSendingLogsWithToken:token];
  MSCommonSchemaLog *log = [MSCommonSchemaLog new];
  [log addTransmissionTargetToken:token];
  log.ver = @"3.0";
  log.name = @"test";
  log.iKey = targetKey;

  // When
  [self.sut enqueueItem:log flags:MSFlagsDefault];

  // Then
  [self enqueueChannelEndJobExpectation];
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                                 OCMVerify([self.storageMock saveLog:log withGroupId:self.sut.configuration.groupId flags:MSFlagsDefault]);
                               }];
}

- (void)testSendingPendingLogsOnResume {

  // If
  [self initChannelEndJobExpectation];
  NSString *targetKey = @"targetKey";
  NSString *token = [NSString stringWithFormat:@"%@-secret", targetKey];
  id channelUnitMock = OCMPartialMock(self.sut);
  [self.sut pauseSendingLogsWithToken:token];
  OCMStub([self.storageMock countLogs]).andReturn(10);

  // When
  [self.sut resumeSendingLogsWithToken:token];

  // Then
  [self enqueueChannelEndJobExpectation];
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }

                                 OCMVerify([self.storageMock countLogs]);
                                 OCMVerify([channelUnitMock checkPendingLogs]);

                                 // The count should be 0 since the logs were sent and not in pending state anymore.
                                 XCTAssertTrue(self.sut.itemsCount == 0);
                               }];
  [channelUnitMock stopMocking];
}

- (void)testTargetKeyRemainsPausedWhenPausedASecondTime {

  // If
  [self initChannelEndJobExpectation];
  NSString *targetKey = @"targetKey";
  NSString *token = [NSString stringWithFormat:@"%@-secret", targetKey];
  [self.sut pauseSendingLogsWithToken:token];

  // When
  [self.sut pauseSendingLogsWithToken:token];

  // Then
  [self enqueueChannelEndJobExpectation];
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                                 XCTAssertTrue([self.sut.pausedTargetKeys count] == 1);
                                 XCTAssertTrue([self.sut.pausedTargetKeys containsObject:targetKey]);
                               }];
}

- (void)testTargetKeyRemainsResumedWhenResumedASecondTime {

  // If
  [self initChannelEndJobExpectation];
  NSString *targetKey = @"targetKey";
  NSString *token = [NSString stringWithFormat:@"%@-secret", targetKey];
  [self.sut pauseSendingLogsWithToken:token];

  // Then
  [self enqueueChannelEndJobExpectation];
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                                 XCTAssertTrue([self.sut.pausedTargetKeys count] == 1);
                                 XCTAssertTrue([self.sut.pausedTargetKeys containsObject:targetKey]);
                               }];

  // If
  [self initChannelEndJobExpectation];

  // When
  [self.sut resumeSendingLogsWithToken:token];
  [self enqueueChannelEndJobExpectation];

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                                 XCTAssertTrue([self.sut.pausedTargetKeys count] == 0);
                               }];

  // If
  [self initChannelEndJobExpectation];

  // When
  [self.sut resumeSendingLogsWithToken:token];
  [self enqueueChannelEndJobExpectation];

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                                 XCTAssertTrue([self.sut.pausedTargetKeys count] == 0);
                               }];
}

- (void)testEnqueueItemDoesNotSetUserIdWhenItAlreadyHasOne {

  // If
  [self initChannelEndJobExpectation];
  id<MSLog> enqueuedLog = [self getValidMockLog];
  NSString *expectedUserId = @"Fake-UserId";
  __block NSString *actualUserId;
  id userIdContextMock = OCMClassMock([MSUserIdContext class]);
  OCMStub([userIdContextMock sharedInstance]).andReturn(userIdContextMock);
  OCMStub([userIdContextMock userId]).andReturn(@"SomethingElse");
  self.sut.storage = self.storageMock = OCMProtocolMock(@protocol(MSStorage));
  OCMStub([self.storageMock saveLog:OCMOCK_ANY withGroupId:OCMOCK_ANY flags:MSFlagsPersistenceNormal])
      .andDo(^(NSInvocation *invocation) {
        [invocation retainArguments];
        MSAbstractLog *log;
        [invocation getArgument:&log atIndex:2];
        actualUserId = log.userId;
        [self enqueueChannelEndJobExpectation];
      })
      .andReturn(YES);

  // When
  enqueuedLog.userId = expectedUserId;
  [self.sut enqueueItem:enqueuedLog flags:MSFlagsDefault];

  // Then
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *_Nullable error) {
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                                 XCTAssertEqual(actualUserId, expectedUserId);
                               }];
  [userIdContextMock stopMocking];
}

#pragma mark - Helper

- (void)initChannelEndJobExpectation {
  self.channelEndJobExpectation = [self expectationWithDescription:@"Channel job should be finished"];
}

- (void)enqueueChannelEndJobExpectation {

  // Enqueue end job expectation on channel's queue to detect when channel
  // finished processing.
  dispatch_async(self.logsDispatchQueue, ^{
    [self.channelEndJobExpectation fulfill];
  });
}

- (NSArray<id<MSLog>> *)getValidMockLogArrayForDate:(NSDate *)date andCount:(NSUInteger)count {
  NSMutableArray<id<MSLog>> *logs = [NSMutableArray<id<MSLog>> new];
  for (NSUInteger i = 0; i < count; i++) {
    [logs addObject:[self getValidMockLogWithDate:[date dateByAddingTimeInterval:i]]];
  }
  return logs;
}

- (id)getValidMockLog {
  id mockLog = OCMPartialMock([MSAbstractLog new]);
  OCMStub([mockLog isValid]).andReturn(YES);
  return mockLog;
}

- (id)getValidMockLogWithDate:(NSDate *)date {
  id<MSLog> mockLog = OCMPartialMock([MSAbstractLog new]);
  OCMStub([mockLog timestamp]).andReturn(date);
  OCMStub([mockLog isValid]).andReturn(YES);
  return mockLog;
}

@end
