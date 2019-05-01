// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#import "MSALPublicClientApplication.h"
#import "MSAuth.h"
#import "MSAuthConfig.h"
#import "MSAuthConfigIngestion.h"
#import "MSAuthTokenContextDelegate.h"
#import "MSChannelDelegate.h"
#import "MSCustomApplicationDelegate.h"
#import "MSServiceInternal.h"

NS_ASSUME_NONNULL_BEGIN

@class MSALPublicClientApplication;

/**
 * Completion handler triggered when complete getting a token.
 *
 * @param userInformation User information for signed in user.
 * @param error Error for sign-in failure.
 */
typedef void (^MSAcquireTokenCompletionHandler)(MSUserInformation *_Nullable userInformation, NSError *_Nullable error);

@interface MSAuth () <MSServiceInternal, MSAuthTokenContextDelegate>

/**
 * The MSAL client for authentication.
 */
@property(nonatomic, nullable) MSALPublicClientApplication *clientApplication;

/**
 * The configuration for the Auth service.
 */
@property(nonatomic, nullable) MSAuthConfig *authConfig;

/**
 * Base URL of the remote configuration file.
 */
@property(atomic, copy, nullable) NSString *configUrl;

/**
 * Ingestion instance (should not be deallocated).
 */
@property(nonatomic, nullable) MSAuthConfigIngestion *ingestion;

/**
 * Custom application delegate dedicated to Auth.
 */
@property(nonatomic) id<MSCustomApplicationDelegate> appDelegate;

/**
 * Completion handler for sign-in.
 */
@property(atomic, nullable) MSAcquireTokenCompletionHandler signInCompletionHandler;

/**
 * Completion handler for refresh completion.
 */
@property(atomic, nullable) MSAcquireTokenCompletionHandler refreshCompletionHandler;

/**
 * The home account id that should be used for refreshing token after coming back online.
 */
@property(nonatomic, nullable, copy) NSString *homeAccountIdToRefresh;

/**
 * Indicates that there is a pending configuration download
 * and sign in, if called, should wait until configuration is downloaded.
 */
@property(atomic) BOOL signInShouldWaitForConfig;

@property(atomic) BOOL configDownloadFailed;

@property(atomic, nullable) MSSignInCompletionHandler userSignInCompletionHandler;

/**
 * Rest singleton instance.
 */
+ (void)resetSharedInstance;

/**
 * Get a file path of auth config.
 *
 * @return The config file path.
 */
- (NSString *)authConfigFilePath;

/**
 * Download auth configuration with an eTag.
 */
- (void)downloadConfigurationWithETag:(nullable NSString *)eTag;

/**
 * Load auth configuration from cache file.
 *
 * @return `YES` if the configuration loaded successfully, otherwise `NO`.
 */
- (BOOL)loadConfigurationFromCache;

/**
 * Config MSAL client.
 */
- (void)configAuthenticationClient;

/**
 * Perform sign in with completion handler.
 */
- (void)signInWithCompletionHandler:(MSSignInCompletionHandler _Nullable)completionHandler;

/**
 * Refreshes token for given accountId.
 */
- (void)refreshTokenForAccountId:(NSString *)accountId withNetworkConnected:(BOOL)networkConnected;

/**
 * Acquires token in background with the given account.
 *
 * @param account The account that is used for acquiring token.
 * @param uiFallback The flag for fallback to interactive sign-in when it fails.
 * @param completionHandlerKeyPath The key path of completion handler to process sign-in or refresh token.
 */
- (void)acquireTokenSilentlyWithMSALAccount:(MSALAccount *)account
                                 uiFallback:(BOOL)uiFallback
                keyPathForCompletionHandler:(NSString *)completionHandlerKeyPath;

/**
 * Cancel pending sign-in and refresh token operation.
 *
 * @param errorCode The error code that indicates a reason of cancellation.
 * @param message The message describes a reason of cancellation.
 */
- (void)cancelPendingOperationsWithErrorCode:(NSInteger)errorCode message:(NSString *)message;

@end

NS_ASSUME_NONNULL_END
