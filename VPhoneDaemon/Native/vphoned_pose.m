/*
 * vphoned_pose — set a foldable guest's device pose, and the virtual hinge
 * angle behind it.
 *
 * A VM has no hinge, and SpringBoard only consumes CoreMotion's hinge angle
 * and magic pose on a board CoreMotion recognizes with two always-connected
 * displays. SpringBoardServices' test-automation client sets the pose
 * directly: SpringBoard builds a synthetic magic pose from the device
 * orientation, hinge state and tabletop pose, and derives the hinge angle
 * from the hinge state. The server checks the client for
 * com.apple.springboard.testautomation, which vphoned carries.
 *
 * The class is resolved at run time, so a base without it reports false.
 */

#import "Include/VphonedNative.h"
#import "../../VPhoneGuestComponents/Hinge/VPhoneHingeState.h"

#include <dlfcn.h>
#include <errno.h>
#include <math.h>
#include <notify.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <signal.h>
#include <unistd.h>

/// The override `-[SBSTestAutomationService setDevicePoseOverride:]` takes, as
/// SpringBoard's handler reads it: a 64-bit orientation, then the device
/// orientation, hinge state and tabletop pose as 32-bit values.
typedef struct {
    int64_t orientation;
    int32_t deviceOrientation;
    int32_t hingeState;
    int32_t tabletopPose;
} VPDevicePoseOverride;

bool vp_device_pose_set(int deviceOrientation, int hingeState, int tabletopPose) {
    static Class service;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        service = NSClassFromString(@"SBSTestAutomationService");
    });
    SEL selector = NSSelectorFromString(@"setDevicePoseOverride:");
    if (!service || ![service instancesRespondToSelector:selector]) return false;
    id client = [service new];
    VPDevicePoseOverride pose = {deviceOrientation, deviceOrientation, hingeState, tabletopPose};
    ((void (*)(id, SEL, VPDevicePoseOverride))objc_msgSend)(client, selector, pose);
    return true;
}

NSDictionary<NSString *, id> *vp_device_pose_get(void) {
    dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    Class service = NSClassFromString(@"SBSTestAutomationService");
    SEL selector = NSSelectorFromString(@"getDevicePose");
    Method method = class_getInstanceMethod(service, selector);
    if (!method || strcmp(method_getTypeEncoding(method), "{?=qiii}16@0:8") != 0)
        return @{@"available": @NO, @"reason": @"device pose readback ABI unavailable"};
    // The client synchronously returns the 24-byte structure reconstructed
    // from SpringBoard's current pose snapshot. The completion selector is
    // on the server protocol, not this client class.
    id client = [service new];
    VPDevicePoseOverride pose = ((VPDevicePoseOverride (*)(id, SEL))objc_msgSend)(client, selector);
    return @{@"available": @YES, @"orientation": @(pose.orientation),
        @"device_orientation": @(pose.deviceOrientation), @"hinge": @(pose.hingeState),
        @"tabletop": @(pose.tabletopPose)};
}

/* The virtual hinge publishes one coherent preference dictionary per update. */
NSDictionary *vp_hinge_get(void) {
    CFPreferencesSynchronize(CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    id configuration = CFBridgingRelease(CFPreferencesCopyValue(CFSTR(VP_HINGE_CONFIGURATION),
        CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost));
    VPhoneHingeState state;
    BOOL valid = VPhoneHingeDecode(configuration, &state);
    id status = CFBridgingRelease(CFPreferencesCopyValue(CFSTR(VP_HINGE_STATUS),
        CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost));
    BOOL running = NO;
    if ([status isKindOfClass:NSDictionary.class] &&
        [status[@"pid"] isKindOfClass:NSNumber.class] &&
        [status[@"updated_at"] isKindOfClass:NSNumber.class] &&
        [status[@"enumerated"] isKindOfClass:NSNumber.class] &&
        [status[@"report_interval_us"] isKindOfClass:NSNumber.class]) {
        pid_t pid = [status[@"pid"] intValue];
        BOOL alive = pid > 1 && (kill(pid, 0) == 0 || errno == EPERM);
        double age = NSDate.date.timeIntervalSince1970 - [status[@"updated_at"] doubleValue];
        BOOL flowing = [status[@"report_interval_us"] unsignedLongLongValue] > 0;
        running = [status[@"enumerated"] boolValue] && alive && age >= 0 && (age < 10 || !flowing);
    } else {
        status = NSNull.null;
    }
    return @{@"angle": @(valid && state.enabled ? state.angle : 0.0),
             @"enabled": @(valid && state.enabled),
             @"provider_running": @(running), @"provider": status};
}

static bool vp_hinge_publish(NSDictionary *configuration, double expectedAngle) {
    CFPreferencesSetValue(CFSTR(VP_HINGE_CONFIGURATION), (__bridge CFDictionaryRef)configuration,
                          CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    if (!CFPreferencesSynchronize(CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost))
        return false;
    if (notify_post(VP_HINGE_NOTIFICATION) != NOTIFY_STATUS_OK)
        return false;
    for (int attempt = 0; attempt < 15; attempt++) {
        usleep(20000);
        CFPreferencesSynchronize(CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
        id status = CFBridgingRelease(CFPreferencesCopyValue(CFSTR(VP_HINGE_STATUS),
            CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost));
        id reported = [status isKindOfClass:NSDictionary.class] ? status[@"configuration"] : nil;
        if ([reported isKindOfClass:NSDictionary.class] &&
            [reported[@"angle"] isKindOfClass:NSNumber.class] &&
            fabs([reported[@"angle"] doubleValue] - expectedAngle) < 0.5)
            break;
    }
    return true;
}

bool vp_hinge_set(double angleDegrees) {
    if (!isfinite(angleDegrees) || angleDegrees < 0 || angleDegrees > 180)
        return false;
    return vp_hinge_publish(VPhoneHingeEncode((VPhoneHingeState){true, false, angleDegrees, 0, 0}), angleDegrees);
}

bool vp_hinge_sweep(double targetDegrees, double durationMs, int profile) {
    if (!isfinite(targetDegrees) || targetDegrees < 0 || targetDegrees > 180 ||
        !isfinite(durationMs) || durationMs < -1 || durationMs > 10000 ||
        (profile != VPhoneHingeProfileContinuous && profile != VPhoneHingeProfileFade))
        return false;
    return vp_hinge_publish(VPhoneHingeEncode((VPhoneHingeState){true, true, targetDegrees, durationMs, profile}), targetDegrees);
}
