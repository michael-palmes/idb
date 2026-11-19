/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

#import <FBControlCore/FBControlCore.h>

/**
 A remote automation session with Accessibility loaded, kept open until -invalidate or until it is released.
 While one is open, apps launched on the simulator keep Accessibility loaded without a bootstrap of their own.
 */
@interface FBSimulatorAccessibilityHold : NSObject

/**
 YES while the remote session is open and connected; NO once it is invalidated or the simulator goes away.
 */
@property (nonatomic, readonly, assign, getter=isValid) BOOL valid;

/**
 Closes the remote session. Safe to call more than once.
 */
- (void)invalidate;

@end

/**
 A Class for handling Framework Loading of Private Frameworks that FBSimulatorControl depends on.
 */
@interface FBSimulatorControlFrameworkLoader : FBControlCoreFrameworkLoader

/**
 The Frameworks needed for most operations.
 */
@property (class, nonnull, nonatomic, readonly, strong) FBSimulatorControlFrameworkLoader *essentialFrameworks;

/**
 The frameworks needed for Accessibility operations.
 */
@property (class, nonnull, nonatomic, readonly, strong) FBSimulatorControlFrameworkLoader *accessibilityFrameworks;

/**
 The Xcode frameworks needed to bootstrap simulator Accessibility on Xcode 27+.
 */
@property (class, nonnull, nonatomic, readonly, strong) FBSimulatorControlFrameworkLoader *accessibilityAutomationFrameworks;

/**
 Starts a short-lived remote automation session and asks it to load Accessibility.
 */
+ (BOOL)bootstrapAccessibilityForSimulatorDevice:(nonnull id)simulatorDevice
                                         timeout:(NSTimeInterval)timeout
                                          logger:(nullable id<FBControlCoreLogger>)logger
                                           error:(NSError * _Nullable * _Nullable)error;

/**
 Starts a remote automation session, asks it to load Accessibility and keeps it open in the returned hold.
 Accessibility requests skip their per-request bootstrap only once a caller marks the simulator held with +setAccessibilityHeld:forSimulatorUDID:.
 */
+ (nullable FBSimulatorAccessibilityHold *)holdAccessibilityForSimulatorDevice:(nonnull id)simulatorDevice
                                                                       timeout:(NSTimeInterval)timeout
                                                                        logger:(nullable id<FBControlCoreLogger>)logger
                                                                         error:(NSError * _Nullable * _Nullable)error;

/**
 Whether this process's Accessibility requests to the simulator skip the per-request bootstrap.
 The caller vouches that a hold is open, in this process or another; NO, the default, bootstraps before every request.
 */
+ (void)setAccessibilityHeld:(BOOL)held forSimulatorUDID:(nonnull NSString *)udid;

/**
 YES while +setAccessibilityHeld:forSimulatorUDID: last marked the simulator held.
 */
+ (BOOL)isAccessibilityHeldForSimulatorUDID:(nonnull NSString *)udid;

/**
 All of the Frameworks for operations involving the HID and Framebuffer.
 */
@property (class, nonnull, nonatomic, readonly, strong) FBSimulatorControlFrameworkLoader *xcodeFrameworks;

@end
