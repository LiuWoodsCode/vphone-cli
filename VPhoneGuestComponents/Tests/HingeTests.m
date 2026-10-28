// HingeTests.m — the hinge angle transport, and the real HID factory.
//
// On a Mac, Apple's own HID.framework answers IOHIDEventCreateHingeAngleEvent,
// so the argument order the guest library calls with is checked against the
// event's own field description: the third argument must read back as
// AngleDegrees, the fourth as MechanicalAngleDegrees, the fifth as the
// velocity. Where the framework is absent (a CI runner without the private
// framework) the factory check is skipped; the transport checks always run.
#import "../Hinge/VPhoneHingeHID.h"
#import "../Hinge/VPhoneHingeState.h"
#include <assert.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        VPhoneHingeState state;
        NSDictionary *sample = @{
            @"enabled": @YES, @"angle": @90.0,
            @"sweep": @YES, @"duration_ms": @-1.0, @"profile": @0,
        };
        // The transport is a property list, including a real Boolean. Test
        // after serialization, as cfprefsd crosses a process boundary.
        NSData *wire = [NSPropertyListSerialization dataWithPropertyList:sample
                                     format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        id decoded = [NSPropertyListSerialization propertyListWithData:wire options:0 format:nil error:nil];
        assert(VPhoneHingeDecode(decoded, &state));
        assert(state.enabled && state.sweep && state.angle == 90.0);
        assert(state.durationMs == -1.0 && state.profile == 0);
        assert([VPhoneHingeEncode(state) isEqual:sample]);

        // An instant set carries no sweep.
        NSDictionary *instant = @{@"enabled": @YES, @"angle": @180.0};
        NSData *instantWire = [NSPropertyListSerialization dataWithPropertyList:instant
                                     format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        id instantRead = [NSPropertyListSerialization propertyListWithData:instantWire options:0 format:nil error:nil];
        assert(VPhoneHingeDecode(instantRead, &state));
        assert(state.enabled && !state.sweep && state.angle == 180.0 && state.profile == 0);

        NSMutableDictionary *closed = [sample mutableCopy];
        closed[@"angle"] = @0.0;
        assert(VPhoneHingeDecode(closed, &state) && state.angle == 0.0);
        closed[@"angle"] = @180.0;
        assert(VPhoneHingeDecode(closed, &state) && state.angle == 180.0);
        closed[@"duration_ms"] = @0.0;
        assert(VPhoneHingeDecode(closed, &state) && state.durationMs == 0.0);
        closed[@"profile"] = @1;
        assert(VPhoneHingeDecode(closed, &state) && state.profile == 1);
        NSMutableDictionary *disabled = [sample mutableCopy];
        disabled[@"enabled"] = @NO;
        assert(VPhoneHingeDecode(disabled, &state) && !state.enabled && state.angle == 90.0);

        for (id invalid in @[@YES, @"90", NSNull.null, @(NAN), @(INFINITY), @-0.5, @180.5]) {
            NSMutableDictionary *bad = [sample mutableCopy];
            bad[@"angle"] = invalid;
            assert(!VPhoneHingeDecode(bad, &state));
            assert(!state.enabled && state.angle == 0);
        }
        for (NSString *key in @[@"enabled", @"angle"]) {
            NSMutableDictionary *bad = [sample mutableCopy];
            [bad removeObjectForKey:key];
            assert(!VPhoneHingeDecode(bad, &state));
        }
        // The optional sweep fields reject malformed values: a profile that
        // is not one of the two, a boolean duration, an out-of-range
        // duration.
        for (id invalid in @[@2, @YES]) {
            NSMutableDictionary *bad = [sample mutableCopy];
            bad[@"profile"] = invalid;
            assert(!VPhoneHingeDecode(bad, &state));
        }
        for (id invalid in @[@YES, @-2, @10001]) {
            NSMutableDictionary *bad = [sample mutableCopy];
            bad[@"duration_ms"] = invalid;
            assert(!VPhoneHingeDecode(bad, &state));
        }
        assert(!VPhoneHingeDecode(@"flat", &state));
        assert(VPhoneHingeInterval(nil) == 0);
        assert(VPhoneHingeInterval(@YES) == 0);
        assert(VPhoneHingeInterval(@0) == 0);
        assert(VPhoneHingeInterval(@(-5)) == 0);
        assert(VPhoneHingeInterval(@(4000.5)) == 5000);
        assert(VPhoneHingeInterval(@(16000)) == 16000);
        assert(VPhoneHingeInterval(@(2e9)) == 1000000);

        void *hid = dlopen("/System/Library/PrivateFrameworks/HID.framework/HID", RTLD_NOW | RTLD_LOCAL);
        VPhoneHingeEventFactory factory = (VPhoneHingeEventFactory)dlsym(hid, "IOHIDEventCreateHingeAngleEvent");
        if (!factory) {
            printf("HID.framework hinge factory unavailable here; transport checks only\n");
            printf("hinge tests passed\n");
            return 0;
        }
        id event = (__bridge id)factory(NULL, mach_absolute_time(), 42.0, 43.0, 1.0, 0);
        assert(event);
        // The description is column-formatted; collapse the runs of spaces
        // before matching, so a wider label column still passes.
        NSArray *fields = [[event description] componentsSeparatedByCharactersInSet:
                           [NSCharacterSet whitespaceCharacterSet]];
        NSString *flat = [[fields filteredArrayUsingPredicate:
                           [NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
        assert([flat containsString:@"AngleDegrees: 42.000000"]);
        assert([flat containsString:@"MechanicalAngleDegre 43.000000"]);
        assert([flat containsString:@"velocityDegreesPerSe 1.000000"]);
        printf("hinge tests passed\n");
        return 0;
    }
}
