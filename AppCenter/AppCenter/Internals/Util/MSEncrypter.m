// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#import <CommonCrypto/CommonCryptor.h>

#import "MSAppCenterInternal.h"
#import "MSEncrypterPrivate.h"
#import "MSKeychainUtil.h"
#import "MSLogger.h"

static int const kMSEncryptionAlgorithm = kCCAlgorithmAES128;
static int const kMSCipherKeySize = kCCKeySizeAES256;
static NSString *kMSEncryptionKeyTag = @"kMSEncryptionKeyTag";

@interface MSEncrypter ()

@property(nonatomic) NSData *key;

@property(nonatomic) CCCryptorRef encryptorObject;

@property(nonatomic) CCCryptorRef decryptorObject;

@property(nonatomic) BOOL cryptorCreated;

@end

@implementation MSEncrypter

- (instancetype)initWitKeyTag:(NSString *)keyTag {
  if ((self = [super init])) {
    [self createCryptorContexts:keyTag];
  }
  return self;
}

- (void)createCryptorContexts:(NSString *)keyTag {

  // Skip if it is already created.
  if (self.cryptorCreated) {
    return;
  }

  // Load a key with keyTag.
  NSData *key = [MSEncrypter loadKeyFromKeychainWithTag:keyTag];
  if (!key) {
    key = [MSEncrypter generateKeyWithTag:keyTag];
  }
  
  // Set a key to the property.
  self.key = key;
  
  // Generate the IV
  int ivLength = kCCBlockSizeAES128;
  NSMutableData *ivData = [NSMutableData dataWithLength:kCCBlockSizeAES128];
  int status = SecRandomCopyBytes(kSecRandomDefault, ivLength, ivData.mutableBytes);
  
  // Log if it failed to set IV
  if (status != errSecSuccess) {
    MSLogError([MSAppCenter logTag], @"Could not create IV.");
    self.cryptorCreated = NO;
    return;
  }

  // Create Cryptorgraphics context for encryption.
  CCCryptorRef encObj;
  CCCryptorStatus encStatus =
      CCCryptorCreate(kCCEncrypt, kMSEncryptionAlgorithm, kCCOptionPKCS7Padding, [self.key bytes], kMSCipherKeySize, ivData.bytes, &encObj);

  // Create Cryptorgraphics context for descryption.
  CCCryptorRef decObj;
  CCCryptorStatus decStatus =
      CCCryptorCreate(kCCDecrypt, kMSEncryptionAlgorithm, kCCOptionPKCS7Padding, [self.key bytes], kMSCipherKeySize, ivData.bytes, &decObj);

  // Log if it failed to create cryptorgraphics contexts.
  if (encStatus != kCCSuccess || decStatus != kCCSuccess) {
    MSLogError([MSAppCenter logTag], @"Could not create cryptor object.");
    self.cryptorCreated = NO;
    return;
  }
  self.encryptorObject = encObj;
  self.decryptorObject = decObj;
  self.cryptorCreated = YES;
}

- (void)dealloc {
  CCCryptorRelease(self.encryptorObject);
  CCCryptorRelease(self.decryptorObject);
}

- (NSString *_Nullable)encryptString:(NSString *)string {
  NSData *dataToEncrypt = [string dataUsingEncoding:NSUTF8StringEncoding];
  return [[self encryptData:dataToEncrypt] base64EncodedStringWithOptions:0];
}

- (NSData *_Nullable)encryptData:(NSData *)data {
  [self createCryptorContexts:kMSEncryptionKeyTag];
  if (!self.key) {
    MSLogError([MSAppCenter logTag], @"Could not perform encryption. Encryption key is missing.");
    return nil;
  }
  NSData *result = nil;
  size_t cipherBufferSize = CCCryptorGetOutputLength(self.encryptorObject, data.length, true);
  uint8_t *cipherBuffer = malloc(cipherBufferSize * sizeof(uint8_t));
  size_t numBytesEncrypted = 0;
  CCCryptorStatus status = CCCrypt(kCCEncrypt, kMSEncryptionAlgorithm, kCCOptionPKCS7Padding, [self.key bytes], kMSCipherKeySize, nil,
                                   [data bytes], data.length, cipherBuffer, cipherBufferSize, &numBytesEncrypted);
  if (status != kCCSuccess) {
    MSLogError([MSAppCenter logTag], @"Error performing encryption.");
  } else {
    result = [NSData dataWithBytes:(const void *)cipherBuffer length:(NSUInteger)numBytesEncrypted];
  }
  free(cipherBuffer);
  return result;
}

- (NSString *_Nullable)decryptString:(NSString *)string {
  NSString *result = nil;
  NSData *dataToDecrypt = [[NSData alloc] initWithBase64EncodedString:string options:0];
  if (dataToDecrypt) {
    NSData *decryptedBytes = [self decryptData:dataToDecrypt];
    result = [[NSString alloc] initWithData:decryptedBytes encoding:NSUTF8StringEncoding];
    if (!result) {
      MSLogWarning([MSAppCenter logTag], @"Converting decrypted NSData to NSString failed.");
    }
  } else {
    MSLogWarning([MSAppCenter logTag], @"Conversion of encrypted string to NSData failed.");
  }
  return result;
}

- (NSData *_Nullable)decryptData:(NSData *)data {
  [self createCryptorContexts:kMSEncryptionKeyTag];
  if (!self.key) {
    MSLogError([MSAppCenter logTag], @"Could not perform decryption. Encryption key is missing.");
    return nil;
  }
  NSData *result = nil;
  size_t cipherBufferSize = CCCryptorGetOutputLength(self.decryptorObject, data.length, true);
  uint8_t *cipherBuffer = malloc(cipherBufferSize);
  size_t numBytesDecrypted = 0;
  CCCryptorStatus status = CCCrypt(kCCDecrypt, kMSEncryptionAlgorithm, kCCOptionPKCS7Padding, [self.key bytes], kMSCipherKeySize, nil,
                                   [data bytes], data.length, cipherBuffer, cipherBufferSize, &numBytesDecrypted);
  if (status != kCCSuccess) {
    MSLogError([MSAppCenter logTag], @"Error performing decryption with CCCryptorStatus: %d.", status);
  } else {
    result = [NSData dataWithBytes:cipherBuffer length:numBytesDecrypted];
    if (!result) {
      MSLogWarning([MSAppCenter logTag], @"Could not create NSData object from decrypted bytes.");
    }
  }
  free(cipherBuffer);
  return result;
}

+ (void)deleteKeyWithTag:(NSString *)keyTag {
  [MSKeychainUtil deleteStringForKey:keyTag];
}

+ (NSData *)loadKeyFromKeychainWithTag:(NSString *)keyTag {
  NSData *keyData = nil;
  NSString *stringKey = [MSKeychainUtil stringForKey:keyTag];
  if (stringKey) {
    keyData = [[NSData alloc] initWithBase64EncodedString:stringKey options:0];
  }
  return keyData;
}

+ (NSData *)generateKeyWithTag:(NSString *)keyTag {
  NSData *resultKey = nil;
  uint8_t *keyBytes = nil;
  keyBytes = malloc(kMSCipherKeySize * sizeof(uint8_t));
  memset((void *)keyBytes, 0x0, kMSCipherKeySize);
  OSStatus status = SecRandomCopyBytes(kSecRandomDefault, kMSCipherKeySize, keyBytes);
  if (status != errSecSuccess) {
    MSLogError([MSAppCenter logTag], @"Error generating encryption key. Error code: %d", (int)status);
  }
  resultKey = [[NSData alloc] initWithBytes:keyBytes length:kMSCipherKeySize];
  free(keyBytes);

  // Save key to the Keychain.
  NSString *stringKey = [resultKey base64EncodedStringWithOptions:0];
  [MSKeychainUtil storeString:stringKey forKey:keyTag];
  return resultKey;
}

@end
