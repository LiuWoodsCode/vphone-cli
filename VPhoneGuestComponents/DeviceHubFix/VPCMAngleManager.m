// VPCMAngleManager.m — the hinge-angle manager stand-in for dtdeviceinfod.
//
// CoreDevice's hinge-angle stream (DeviceHub) ends, on the device, in the
// DDI's dtdeviceinfod: CMAngleManager_Bridge resolves CoreMotion's
// CMAngleManager and forwards the stream to it. On a guest the manager's
// capability answer is NO — CoreMotion picks its motion capabilities from the
// device tree's product-id, and the foldable token cannot be written without
// crash-looping SpringBoard.
//
// Opening that one gate is not enough, and that was v4's crash: with
// +[CMAngleManager isAvailable] answering YES, the bridge started the REAL
// manager, whose MotionThread asserts when its own capability bits
// (product-id) contradict the answer (dtdeviceinfod SIGABRT,
// com.apple.CoreMotion.MotionThread, eight times over a DeviceHub connect).
//
// So the manager's whole ObjC surface is taken over here, and CoreMotion's
// machinery never runs: isAvailable follows the vphone hinge provider, the
// angle range is the virtual hinge's 0–180, and the update methods deliver
// samples read from the provider's newest published sample
// (VPhoneHingeLatest, com.apple.backboardd/mobile) — the same values the HID
// service reports — wrapped in an object exposing the fields the bridge maps
// into DeviceHingeAngleSnapshot (angleDegrees, mechanicalAngleDegrees,
// velocityDegreesPerSeconds, the validity flags, state, eventPhase and
// timestamp). The sample class subclasses CoreMotion's own CMAngleData when
// that class exists, so a typed cast in the bridge still succeeds. The
// bridge's queue argument is an NSOperationQueue (CMAngleData itself never
// registered, measured on iOS 27.1), and samples are delivered onto it with
// addOperationWithBlock:.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// MARK: - Log (same file the rest of the dylib writes)

static void vpMotionLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    if (!line)
        return;
    int fd = open("/var/mobile/Library/Caches/vphone-devicehubfix.log",
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0666);
    if (fd < 0)
        return;
    fchmod(fd, 0666);
    dprintf(fd, "pid=%d %s\n", getpid(), line.UTF8String);
    close(fd);
}

// MARK: - The provider's newest sample

static NSDictionary *vpLatestSample(void) {
    CFPreferencesSynchronize(CFSTR("com.apple.backboardd"), CFSTR("mobile"), kCFPreferencesAnyHost);
    CFPropertyListRef value = CFPreferencesCopyValue(CFSTR("VPhoneHingeLatest"),
                                                     CFSTR("com.apple.backboardd"),
                                                     CFSTR("mobile"), kCFPreferencesAnyHost);
    id sample = CFBridgingRelease(value);
    return [sample isKindOfClass:NSDictionary.class] ? sample : nil;
}

// The provider republishes its status through cfprefsd. Freshness is NOT part
// of the test: the status heartbeat only runs while samples flow, so with no
// HID subscriber the stamp goes stale though the provider is alive. The pid is
// backboardd's, a launchd-critical process the guest reboots without — but
// dtdeviceinfod (mobile) cannot signal backboardd (root), so kill answers
// EPERM for a LIVE process; that counts as alive. Anything else that fails
// (ESRCH) really is gone.
static BOOL vpProviderIsRunning(void) {
    CFPreferencesSynchronize(CFSTR("com.apple.backboardd"), CFSTR("mobile"), kCFPreferencesAnyHost);
    CFPropertyListRef status = CFPreferencesCopyValue(CFSTR("VPhoneHingeStatus"),
                                                      CFSTR("com.apple.backboardd"),
                                                      CFSTR("mobile"), kCFPreferencesAnyHost);
    CFDictionaryRef dict = status && CFGetTypeID(status) == CFDictionaryGetTypeID()
                               ? (CFDictionaryRef)status : NULL;
    const void *enumerated = dict ? CFDictionaryGetValue(dict, CFSTR("enumerated")) : NULL;
    const void *pid = dict ? CFDictionaryGetValue(dict, CFSTR("pid")) : NULL;
    BOOL running = NO;
    if (enumerated && CFGetTypeID(enumerated) == CFBooleanGetTypeID() &&
        CFBooleanGetValue(enumerated) &&
        pid && CFGetTypeID(pid) == CFNumberGetTypeID()) {
        int value = 0;
        CFNumberGetValue(pid, kCFNumberIntType, &value);
        if (value > 1) {
            if (kill(value, 0) == 0)
                running = YES;
            else
                running = errno == EPERM;
        }
        // One diagnosis per process, so a closed gate explains itself in the log.
        static int logged = 0;
        if (!running && !logged++) {
            int reason = errno;
            vpMotionLog(@"hinge manager: gate closed — pid=%d kill_errno=%d (ESRCH=3 dead, EPERM=1 alive-but-unsignalable)",
                        value, reason);
        }
    }
    if (status)
        CFRelease(status);
    return running;
}

// MARK: - The sample object

typedef struct {
    double angle;
    double mechanical;
    double velocity;
    double timestamp;
    BOOL angleValid;
    BOOL velocityValid;
    long state;
    long phase;
} VPAngleSampleFields;

static Class VPAngleDataClass;
static ptrdiff_t VPAngleDataOffset;

#define VP_SAMPLE_GETTER(name, field, types)                                              \
    class_addMethod(VPAngleDataClass, sel_registerName(name),                             \
                    imp_implementationWithBlock(^(id self) {                              \
                        return ((VPAngleSampleFields *)((char *)(__bridge void *)self + VPAngleDataOffset))->field; \
                    }), types)

static void vpRegisterAngleDataClass(void) {
    // Subclass CoreMotion's own data class when it exists, so a typed cast in
    // the bridge still succeeds; the getters are replaced either way.
    Class base = objc_getClass("CMAngleData");
    if (!base)
        base = [NSObject class];
    VPAngleDataClass = objc_allocateClassPair(base, "VPCMAngleData", 0);
    if (!VPAngleDataClass)
        return;
    if (!class_addIvar(VPAngleDataClass, "fields", sizeof(VPAngleSampleFields),
                       0, @encode(VPAngleSampleFields))) {
        VPAngleDataClass = NULL;
        return;
    }
    objc_registerClassPair(VPAngleDataClass);
    VPAngleDataOffset = ivar_getOffset(class_getInstanceVariable(VPAngleDataClass, "fields"));
    // The fields CMAngleManager_Bridge maps into DeviceHingeAngleSnapshot,
    // with both spellings of the two flags.
    VP_SAMPLE_GETTER("angleDegrees", angle, "d16@0:8");
    VP_SAMPLE_GETTER("mechanicalAngleDegrees", mechanical, "d16@0:8");
    VP_SAMPLE_GETTER("velocityDegreesPerSeconds", velocity, "d16@0:8");
    VP_SAMPLE_GETTER("timestamp", timestamp, "d16@0:8");
    VP_SAMPLE_GETTER("isAngleValid", angleValid, "B16@0:8");
    VP_SAMPLE_GETTER("angleValid", angleValid, "B16@0:8");
    VP_SAMPLE_GETTER("isVelocityValid", velocityValid, "B16@0:8");
    VP_SAMPLE_GETTER("velocityValid", velocityValid, "B16@0:8");
    VP_SAMPLE_GETTER("state", state, "q16@0:8");
    VP_SAMPLE_GETTER("eventPhase", phase, "q16@0:8");
}

static id vpAngleDataFromSample(NSDictionary *latest) {
    if (!VPAngleDataClass)
        return nil;
    id data = [VPAngleDataClass new];
    VPAngleSampleFields *fields = (VPAngleSampleFields *)((char *)(__bridge void *)data + VPAngleDataOffset);
    fields->angle = [latest[@"angle"] doubleValue];
    fields->mechanical = [latest[@"mechanical_angle"] doubleValue];
    fields->velocity = [latest[@"velocity"] doubleValue];
    fields->timestamp = [latest[@"timestamp"] doubleValue];
    fields->angleValid = latest[@"angle"] != nil;
    fields->velocityValid = latest[@"velocity"] != nil;
    fields->state = [latest[@"state"] longValue];
    fields->phase = [latest[@"event_phase"] longValue];
    return data;
}

// MARK: - The update session

@interface VPAngleSession : NSObject
// CoreMotion's queue argument is an NSOperationQueue, like CMMotionManager's
// start...UpdatesToQueue: (that was v5's crash — dispatch_async on an
// NSOperationQueue made libdispatch vtable-dispatch through a non-dispatch
// object and die with EXC_ARM_PAC_FAIL). Held as id and dispatched by kind.
@property (nonatomic, strong) id deliveryQueue;
@property (nonatomic, copy) void (^handler)(id data);
@property (nonatomic) NSTimeInterval interval;
@property (nonatomic, strong) dispatch_source_t timer;
@end

@implementation VPAngleSession
- (void)dealloc {
    if (_timer)
        dispatch_source_cancel(_timer);
}
@end

static char vpSessionKey;

static dispatch_queue_t vpTimerQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.vphone.devicehubfix.angle", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSTimeInterval vpClampInterval(NSTimeInterval interval) {
    if (!isfinite(interval) || interval <= 0)
        return 0;
    return MIN(10.0, MAX(0.01, interval));
}

static void vpDeliver(VPAngleSession *session) {
    if (!session.handler)
        return;
    id data = vpAngleDataFromSample(vpLatestSample());
    if (!data)
        return;
    void (^handler)(id) = session.handler;
    id queue = session.deliveryQueue;
    if ([queue isKindOfClass:[NSOperationQueue class]])
        [(NSOperationQueue *)queue addOperationWithBlock:^{ handler(data); }];
    else if (queue)
        dispatch_async((dispatch_queue_t)queue, ^{ handler(data); });
    else
        handler(data);
}

static void vpArmTimer(VPAngleSession *session) {
    if (session.timer) {
        dispatch_source_cancel(session.timer);
        session.timer = nil;
    }
    if (!session.handler)
        return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, vpTimerQueue());
    NSTimeInterval interval = session.interval > 0 ? session.interval : 0.1;
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW,
                              (uint64_t)(interval * NSEC_PER_SEC), (uint64_t)(10 * NSEC_PER_MSEC));
    // Weak, so the session dies with the manager and cancels the timer.
    __weak VPAngleSession *weakSession = session;
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool {
            VPAngleSession *alive = weakSession;
            if (alive)
                vpDeliver(alive);
        }
    });
    dispatch_resume(timer);
    session.timer = timer;
}

static VPAngleSession *vpSession(id manager) {
    VPAngleSession *session = objc_getAssociatedObject(manager, &vpSessionKey);
    if (!session) {
        session = [VPAngleSession new];
        objc_setAssociatedObject(manager, &vpSessionKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return session;
}

// MARK: - The swapped CMAngleManager surface

static IMP vpOriginalIsAvailableIMP;
__attribute__((used)) static IMP vpOriginalStartIMP;
__attribute__((used)) static IMP vpOriginalSetHandlerIMP;
__attribute__((used)) static IMP vpOriginalStopIMP;
__attribute__((used)) static IMP vpOriginalActiveIMP;
__attribute__((used)) static IMP vpOriginalGetIntervalIMP;
__attribute__((used)) static IMP vpOriginalSetIntervalIMP;

static BOOL vpSwizzledIsAvailable(id self, SEL selector) {
    if (vpProviderIsRunning())
        return YES;
    return ((BOOL (*)(id, SEL))vpOriginalIsAvailableIMP)(self, selector);
}

static double vpSwizzledMinAngle(id self, SEL selector) { return 0.0; }
static double vpSwizzledMaxAngle(id self, SEL selector) { return 180.0; }

static void vpSwizzledStartUpdates(id self, SEL selector, id queue, id handler) {
    VPAngleSession *session = vpSession(self);
    session.deliveryQueue = queue;
    session.handler = [handler copy];
    vpArmTimer(session);
}

static void vpSwizzledSetHandler(id self, SEL selector, id handler, double interval) {
    VPAngleSession *session = vpSession(self);
    session.deliveryQueue = nil;
    session.interval = vpClampInterval(interval);
    session.handler = [handler copy];
    vpArmTimer(session);
}

static void vpSwizzledStopUpdates(id self, SEL selector) {
    VPAngleSession *session = objc_getAssociatedObject(self, &vpSessionKey);
    session.handler = nil;
    if (session.timer) {
        dispatch_source_cancel(session.timer);
        session.timer = nil;
    }
}

static BOOL vpSwizzledIsAngleActive(id self, SEL selector) {
    VPAngleSession *session = objc_getAssociatedObject(self, &vpSessionKey);
    return session.handler != nil && session.timer != nil;
}

static double vpSwizzledAngleUpdateInterval(id self, SEL selector) {
    VPAngleSession *session = objc_getAssociatedObject(self, &vpSessionKey);
    return session.interval > 0 ? session.interval : 0.1;
}

static void vpSwizzledSetAngleUpdateInterval(id self, SEL selector, double interval) {
    VPAngleSession *session = vpSession(self);
    session.interval = vpClampInterval(interval);
    if (session.handler)
        vpArmTimer(session);
}

// MARK: - Install

__attribute__((constructor)) static void vpInstallAngleManagerStandIn(void) {
    if (strcmp(getprogname(), "dtdeviceinfod") != 0)
        return;
    dlopen("/System/Library/Frameworks/CoreMotion.framework/CoreMotion", RTLD_LAZY | RTLD_LOCAL);
    Class manager = objc_getClass("CMAngleManager");
    if (!manager) {
        vpMotionLog(@"hinge manager: CMAngleManager not found, CoreDevice hingeAngle stays off");
        return;
    }
    vpRegisterAngleDataClass();

    Method available = class_getClassMethod(manager, sel_registerName("isAvailable"));
    if (available) {
        vpOriginalIsAvailableIMP = method_getImplementation(available);
        method_setImplementation(available, (IMP)vpSwizzledIsAvailable);
    }
    Method min = class_getClassMethod(manager, sel_registerName("minAngleDegrees"));
    if (min)
        method_setImplementation(min, (IMP)vpSwizzledMinAngle);
    Method max = class_getClassMethod(manager, sel_registerName("maxAngleDegrees"));
    if (max)
        method_setImplementation(max, (IMP)vpSwizzledMaxAngle);

    // The instance methods the bridge drives. Every one replaced means one
    // less path into CoreMotion's own MotionThread.
    Method start = class_getInstanceMethod(manager, sel_registerName("startAngleUpdatesToQueue:handler:"));
    if (start) {
        vpOriginalStartIMP = method_getImplementation(start);
        method_setImplementation(start, (IMP)vpSwizzledStartUpdates);
    }
    Method setHandler = class_getInstanceMethod(manager, sel_registerName("setAngleHandler:interval:"));
    if (setHandler) {
        vpOriginalSetHandlerIMP = method_getImplementation(setHandler);
        method_setImplementation(setHandler, (IMP)vpSwizzledSetHandler);
    }
    Method stop = class_getInstanceMethod(manager, sel_registerName("stopAngleUpdates"));
    if (stop) {
        vpOriginalStopIMP = method_getImplementation(stop);
        method_setImplementation(stop, (IMP)vpSwizzledStopUpdates);
    }
    Method active = class_getInstanceMethod(manager, sel_registerName("isAngleActive"));
    if (active) {
        vpOriginalActiveIMP = method_getImplementation(active);
        method_setImplementation(active, (IMP)vpSwizzledIsAngleActive);
    }
    Method getInterval = class_getInstanceMethod(manager, sel_registerName("angleUpdateInterval"));
    if (getInterval) {
        vpOriginalGetIntervalIMP = method_getImplementation(getInterval);
        method_setImplementation(getInterval, (IMP)vpSwizzledAngleUpdateInterval);
    }
    Method setInterval = class_getInstanceMethod(manager, sel_registerName("setAngleUpdateInterval:"));
    if (setInterval) {
        vpOriginalSetIntervalIMP = method_getImplementation(setInterval);
        method_setImplementation(setInterval, (IMP)vpSwizzledSetAngleUpdateInterval);
    }

    BOOL sampleReady = VPAngleDataClass != NULL;
    vpMotionLog(@"hinge manager: stand-in v6 installed (start=%@ setHandler=%@ stop=%@ active=%@ interval=%@ sample=%@ base=%@)",
                start ? @"yes" : @"MISSING", setHandler ? @"yes" : @"missing", stop ? @"yes" : @"missing",
                active ? @"yes" : @"missing", getInterval ? @"yes" : @"missing",
                sampleReady ? @"ready" : @"MISSING",
                VPAngleDataClass ? class_getSuperclass(VPAngleDataClass) : nil);
}
