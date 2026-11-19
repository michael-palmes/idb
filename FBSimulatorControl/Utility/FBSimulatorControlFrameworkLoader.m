/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSimulatorControlFrameworkLoader.h"

#import <CoreSimulatorUtilities/NSUserDefaults-SimDefaults.h>
#import <FBControlCore/FBControlCore.h>
#import <objc/message.h>

static NSString *const FBSimulatorAccessibilityBootstrapErrorDomain = @"com.facebook.FBSimulatorControl.AccessibilityBootstrap";

static NSError *FBSimulatorAccessibilityBootstrapError(NSInteger code, NSString *description)
{
  return [NSError errorWithDomain:FBSimulatorAccessibilityBootstrapErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey: description}];
}

static void FBSimulatorInvalidateAutomationSession(id session)
{
  SEL invalidateSelector = NSSelectorFromString(@"invalidate");
  if ([session respondsToSelector:invalidateSelector]) {
    ((void (*)(id, SEL))objc_msgSend)(session, invalidateSelector);
  }
}

static BOOL FBSimulatorAutomationSessionFlag(id session, NSString *selectorName)
{
  SEL selector = NSSelectorFromString(selectorName);
  if (![session respondsToSelector:selector]) {
    return YES;
  }
  return ((BOOL (*)(id, SEL))objc_msgSend)(session, selector);
}

@implementation FBSimulatorAccessibilityHold
{
  NSLock *_lock;
  id _session;
}

- (instancetype)initWithSession:(id)session
{
  self = [super init];
  if (!self) {
    return nil;
  }
  _lock = [NSLock new];
  _session = session;
  return self;
}

- (BOOL)isValid
{
  [_lock lock];
  id session = _session;
  [_lock unlock];
  return session && FBSimulatorAutomationSessionFlag(session, @"isValid") && FBSimulatorAutomationSessionFlag(session, @"isConnected");
}

- (void)invalidate
{
  [_lock lock];
  id session = _session;
  _session = nil;
  [_lock unlock];
  if (session) {
    FBSimulatorInvalidateAutomationSession(session);
  }
}

- (void)dealloc
{
  [self invalidate];
}

@end

@interface FBSimulatorAccessibilityBootstrapAttempt : NSObject

@property (nonatomic, strong, readonly) dispatch_group_t group;
@property (nonatomic, assign) BOOL success;
@property (nonatomic, copy, nullable) NSError *error;

@end

@implementation FBSimulatorAccessibilityBootstrapAttempt

- (instancetype)init
{
  self = [super init];
  if (!self) {
    return nil;
  }
  _group = dispatch_group_create();
  dispatch_group_enter(_group);
  return self;
}

@end

@interface FBSimulatorAccessibilitySessionRequest : NSObject

- (void)completeWithSession:(nullable id)session error:(nullable NSError *)error;
- (nullable id)sessionByMarkingTimedOut;
- (nullable id)session;
- (nullable NSError *)error;

@end

@implementation FBSimulatorAccessibilitySessionRequest
{
  NSLock *_lock;
  id _session;
  NSError *_error;
  BOOL _timedOut;
}

- (instancetype)init
{
  self = [super init];
  if (!self) {
    return nil;
  }
  _lock = [NSLock new];
  return self;
}

- (void)completeWithSession:(id)session error:(NSError *)error
{
  [_lock lock];
  BOOL timedOut = _timedOut;
  if (!timedOut) {
    _session = session;
    _error = error;
  }
  [_lock unlock];
  if (timedOut && session) {
    FBSimulatorInvalidateAutomationSession(session);
  }
}

- (id)sessionByMarkingTimedOut
{
  [_lock lock];
  _timedOut = YES;
  id session = _session;
  _session = nil;
  [_lock unlock];
  return session;
}

- (id)session
{
  [_lock lock];
  id session = _session;
  [_lock unlock];
  return session;
}

- (NSError *)error
{
  [_lock lock];
  NSError *error = _error;
  [_lock unlock];
  return error;
}

@end

@interface FBSimulatorControlFrameworkLoader ()

+ (BOOL)performAccessibilityBootstrapForSimulatorDevice:(id)simulatorDevice
                                                 timeout:(NSTimeInterval)timeout
                                                  logger:(nullable id<FBControlCoreLogger>)logger
                                                   error:(NSError **)error;

+ (nullable id)openAccessibilitySessionForSimulatorDevice:(id)simulatorDevice
                                                  timeout:(NSTimeInterval)timeout
                                                   logger:(nullable id<FBControlCoreLogger>)logger
                                                    error:(NSError **)error;

@end

static void FBSimulatorControl_SimLogHandler(int level, const char *function, int lineNumber, NSString *format, ...)
{
  va_list args;
  va_start(args, format);
  NSString *string = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  id<FBControlCoreLogger> logger = [FBControlCoreGlobalConfiguration.defaultLogger.debug withName:@"CoreSimulator"];
  [logger log:string];
}

@interface FBSimulatorControlFrameworkLoader_Essential : FBSimulatorControlFrameworkLoader

@end

@implementation FBSimulatorControlFrameworkLoader

#pragma mark Initializers

+ (FBSimulatorControlFrameworkLoader *)essentialFrameworks
{
  static dispatch_once_t onceToken;
  static FBSimulatorControlFrameworkLoader *loader;
  dispatch_once(&onceToken, ^{
    loader = [FBSimulatorControlFrameworkLoader_Essential loaderWithName:@"FBSimulatorControl"
                                                              frameworks:@[
                FBWeakFramework.CoreSimulator,
              ]];
  });
  return loader;
}

+ (FBSimulatorControlFrameworkLoader *)accessibilityFrameworks
{
  static dispatch_once_t onceToken;
  static FBSimulatorControlFrameworkLoader *loader;
  dispatch_once(&onceToken, ^{
    loader = [FBSimulatorControlFrameworkLoader loaderWithName:@"FBSimulatorControl"
                                                    frameworks:@[
                FBWeakFramework.AccessibilityPlatformTranslation,
              ]];
  });
  return loader;
}

+ (FBSimulatorControlFrameworkLoader *)accessibilityAutomationFrameworks
{
  static dispatch_once_t onceToken;
  static FBSimulatorControlFrameworkLoader *loader;
  dispatch_once(&onceToken, ^{
    loader = [FBSimulatorControlFrameworkLoader loaderWithName:@"FBSimulatorControl"
                                                    frameworks:@[
                FBWeakFramework.XCTDaemonControl,
                FBWeakFramework.XCUIAutomation,
              ]];
  });
  return loader;
}

+ (BOOL)bootstrapAccessibilityForSimulatorDevice:(id)simulatorDevice timeout:(NSTimeInterval)timeout logger:(id<FBControlCoreLogger>)logger error:(NSError **)error
{
  static dispatch_once_t onceToken;
  static dispatch_queue_t stateQueue;
  static NSMapTable *states;
  dispatch_once(&onceToken, ^{
    stateQueue = dispatch_queue_create("com.facebook.FBSimulatorControl.AccessibilityBootstrap", DISPATCH_QUEUE_SERIAL);
    states = [NSMapTable weakToStrongObjectsMapTable];
  });

  __block FBSimulatorAccessibilityBootstrapAttempt *attempt;
  __block BOOL ownsAttempt = NO;
  dispatch_sync(stateQueue, ^{
    id state = [states objectForKey:simulatorDevice];
    if ([state isKindOfClass:FBSimulatorAccessibilityBootstrapAttempt.class]) {
      attempt = state;
    } else {
      attempt = [FBSimulatorAccessibilityBootstrapAttempt new];
      [states setObject:attempt forKey:simulatorDevice];
      ownsAttempt = YES;
    }
  });
  if (!ownsAttempt) {
    dispatch_group_wait(attempt.group, DISPATCH_TIME_FOREVER);
    if (!attempt.success && error) {
      *error = attempt.error;
    }
    return attempt.success;
  }

  NSError *bootstrapError = nil;
  BOOL success = [self performAccessibilityBootstrapForSimulatorDevice:simulatorDevice
                                                               timeout:timeout
                                                                logger:logger
                                                                 error:&bootstrapError];
  attempt.success = success;
  attempt.error = bootstrapError;
  dispatch_sync(stateQueue, ^{
    if ([states objectForKey:simulatorDevice] == attempt) {
      [states removeObjectForKey:simulatorDevice];
    }
  });
  dispatch_group_leave(attempt.group);
  if (!success && error) {
    *error = bootstrapError;
  }
  return success;
}

+ (BOOL)performAccessibilityBootstrapForSimulatorDevice:(id)simulatorDevice timeout:(NSTimeInterval)timeout logger:(id<FBControlCoreLogger>)logger error:(NSError **)error
{
  id session = [self openAccessibilitySessionForSimulatorDevice:simulatorDevice timeout:timeout logger:logger error:error];
  if (!session) {
    return NO;
  }
  FBSimulatorInvalidateAutomationSession(session);
  [logger log:@"Bootstrapped simulator Accessibility through a short-lived remote automation session"];
  return YES;
}

+ (FBSimulatorAccessibilityHold *)holdAccessibilityForSimulatorDevice:(id)simulatorDevice timeout:(NSTimeInterval)timeout logger:(id<FBControlCoreLogger>)logger error:(NSError **)error
{
  id session = [self openAccessibilitySessionForSimulatorDevice:simulatorDevice timeout:timeout logger:logger error:error];
  if (!session) {
    return nil;
  }
  [logger log:@"Holding simulator Accessibility through a remote automation session"];
  return [[FBSimulatorAccessibilityHold alloc] initWithSession:session];
}

+ (NSMutableSet<NSString *> *)heldSimulatorUDIDs
{
  static dispatch_once_t onceToken;
  static NSMutableSet<NSString *> *held;
  dispatch_once(&onceToken, ^{
    held = [NSMutableSet set];
  });
  return held;
}

+ (void)setAccessibilityHeld:(BOOL)held forSimulatorUDID:(NSString *)udid
{
  NSMutableSet<NSString *> *heldUDIDs = self.heldSimulatorUDIDs;
  @synchronized (heldUDIDs) {
    if (held) {
      [heldUDIDs addObject:udid];
    } else {
      [heldUDIDs removeObject:udid];
    }
  }
}

+ (BOOL)isAccessibilityHeldForSimulatorUDID:(NSString *)udid
{
  NSMutableSet<NSString *> *heldUDIDs = self.heldSimulatorUDIDs;
  @synchronized (heldUDIDs) {
    return [heldUDIDs containsObject:udid];
  }
}

+ (id)openAccessibilitySessionForSimulatorDevice:(id)simulatorDevice timeout:(NSTimeInterval)timeout logger:(id<FBControlCoreLogger>)logger error:(NSError **)error
{
  if (![self.accessibilityAutomationFrameworks loadPrivateFrameworks:logger error:error]) {
    return nil;
  }

  Class providerClass = NSClassFromString(@"XCUIDeviceRemoteDaemonConnectionProvider");
  SEL providerSelector = NSSelectorFromString(@"connectionProviderForSimDevice:");
  if (![providerClass respondsToSelector:providerSelector]) {
    if (error) {
      *error = FBSimulatorAccessibilityBootstrapError(1, @"XCUIDeviceRemoteDaemonConnectionProvider.connectionProviderForSimDevice: is unavailable");
    }
    return nil;
  }
  id provider = ((id (*)(id, SEL, id))objc_msgSend)(providerClass, providerSelector, simulatorDevice);
  if (!provider) {
    if (error) {
      *error = FBSimulatorAccessibilityBootstrapError(2, @"Could not create the simulator remote daemon connection provider");
    }
    return nil;
  }

  Class sessionClass = NSClassFromString(@"XCUIDeviceRemoteAutomationSession");
  SEL requestSelector = NSSelectorFromString(@"requestSessionWithDaemonConnectionProvider:completion:");
  if (![sessionClass respondsToSelector:requestSelector]) {
    if (error) {
      *error = FBSimulatorAccessibilityBootstrapError(3, @"XCUIDeviceRemoteAutomationSession request API is unavailable");
    }
    return nil;
  }

  dispatch_semaphore_t sessionSemaphore = dispatch_semaphore_create(0);
  FBSimulatorAccessibilitySessionRequest *sessionRequest = [FBSimulatorAccessibilitySessionRequest new];
  id sessionCompletion = ^(id returnedSession, NSError *returnedError) {
    [sessionRequest completeWithSession:returnedSession error:returnedError];
    dispatch_semaphore_signal(sessionSemaphore);
  };
  ((void (*)(id, SEL, id, id))objc_msgSend)(sessionClass, requestSelector, provider, sessionCompletion);
  if (dispatch_semaphore_wait(sessionSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
    id lateSession = [sessionRequest sessionByMarkingTimedOut];
    if (lateSession) {
      FBSimulatorInvalidateAutomationSession(lateSession);
    }
    if (error) {
      *error = FBSimulatorAccessibilityBootstrapError(4, @"Timed out creating the simulator remote automation session");
    }
    return nil;
  }
  id session = sessionRequest.session;
  if (!session) {
    if (error) {
      *error = sessionRequest.error ?: FBSimulatorAccessibilityBootstrapError(5, @"Could not create the simulator remote automation session");
    }
    return nil;
  }

  BOOL kept = NO;
  @try {
    SEL enableSelector = NSSelectorFromString(@"enableAutomationModeWithError:");
    if ([session respondsToSelector:enableSelector]) {
      NSError *enableError = nil;
      BOOL enabled = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(session, enableSelector, &enableError);
      if (!enabled) {
        if (error) {
          *error = enableError ?: FBSimulatorAccessibilityBootstrapError(6, @"Could not enable simulator automation mode");
        }
        return nil;
      }
    }

    SEL loadSelector = NSSelectorFromString(@"loadAccessibilityWithTimeout:reply:");
    if (![session respondsToSelector:loadSelector]) {
      if (error) {
        *error = FBSimulatorAccessibilityBootstrapError(7, @"Remote automation session cannot load Accessibility");
      }
      return nil;
    }
    dispatch_semaphore_t loadSemaphore = dispatch_semaphore_create(0);
    __block BOOL loaded = NO;
    __block NSError *loadError = nil;
    id loadReply = ^(BOOL returnedLoaded, NSError *returnedError) {
      loaded = returnedLoaded;
      loadError = returnedError;
      dispatch_semaphore_signal(loadSemaphore);
    };
    ((void (*)(id, SEL, double, id))objc_msgSend)(session, loadSelector, timeout, loadReply);
    if (dispatch_semaphore_wait(loadSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 1) * NSEC_PER_SEC))) != 0) {
      if (error) {
        *error = FBSimulatorAccessibilityBootstrapError(8, @"Timed out loading simulator Accessibility");
      }
      return nil;
    }
    if (!loaded) {
      if (error) {
        *error = loadError ?: FBSimulatorAccessibilityBootstrapError(9, @"The simulator rejected the Accessibility load request");
      }
      return nil;
    }
    kept = YES;
    return session;
  } @finally {
    if (!kept) {
      FBSimulatorInvalidateAutomationSession(session);
    }
  }
}

+ (FBSimulatorControlFrameworkLoader *)xcodeFrameworks
{
  static dispatch_once_t onceToken;
  static FBSimulatorControlFrameworkLoader *loader;
  dispatch_once(&onceToken, ^{
    loader = [FBSimulatorControlFrameworkLoader loaderWithName:@"FBSimulatorControl"
                                                    frameworks:@[
                FBWeakFramework.SimulatorKit,
              ]];
  });
  return loader;
}

@end

@implementation FBSimulatorControlFrameworkLoader_Essential

#pragma mark Public Methods

- (BOOL)loadPrivateFrameworks:(nullable id<FBControlCoreLogger>)logger error:(NSError **)error
{
  if (self.hasLoadedFrameworks) {
    return YES;
  }
  BOOL loaded = [super loadPrivateFrameworks:logger error:error];
  if (loaded) {
    // Hook the default handler to call us instead.
    [FBSimulatorControlFrameworkLoader_Essential setInternalLogHandler];
    // Set CoreSimulator Logging since it is now loaded.
    [FBSimulatorControlFrameworkLoader_Essential setCoreSimulatorLoggingEnabled:(logger.level >= FBControlCoreLogLevelDebug)];
  }
  return loaded;
}

#pragma mark Private Methods

+ (void)setCoreSimulatorLoggingEnabled:(BOOL)enabled
{
  if (![NSUserDefaults respondsToSelector:@selector(simulatorDefaults)]) {
    return;
  }
  // These are stored at ~/Library/Preferences/com.apple.CoreSimulator.plist
  // This will also be picked up by CoreSimulatorService, which itself links CoreSimulator and uses -[NSUserDefaults(SimDefaults) simulatorDefaults]
  NSUserDefaults *simulatorDefaults = [NSUserDefaults simulatorDefaults];
  [simulatorDefaults setBool:enabled forKey:@"DebugLogging"];
  [simulatorDefaults synchronize];
}

+ (BOOL)setInternalLogHandler
{
  NSBundle *coreSimulatorBundle = [NSBundle bundleWithIdentifier:@"com.apple.CoreSimulator"];
  if (!coreSimulatorBundle) {
    return NO;
  }
  NSString *bundleVersionString = coreSimulatorBundle.infoDictionary[@"CFBundleVersion"];
  if (!bundleVersionString) {
    return NO;
  }
  NSDecimalNumber *bundleVersion = [NSDecimalNumber decimalNumberWithString:bundleVersionString];
  if (!bundleVersion) {
    return NO;
  }
  if ([bundleVersion isEqualToNumber:NSDecimalNumber.notANumber]) {
    return NO;
  }
  if ([bundleVersion isGreaterThanOrEqualTo:[NSDecimalNumber decimalNumberWithString:@"757"]]) {
    return NO;
  }
  void *coreSimulatorHandle = [coreSimulatorBundle dlopenExecutablePath];
  if (!coreSimulatorHandle) {
    return NO;
  }
  void (*SetHandler)(void *) = FBGetSymbolFromHandleOptional(coreSimulatorHandle, "SimLogSetHandler");
  if (!SetHandler) {
    return NO;
  }
  SetHandler(FBSimulatorControl_SimLogHandler);
  return YES;
}

@end
