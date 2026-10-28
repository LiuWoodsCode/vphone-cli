#pragma once
#import <Foundation/Foundation.h>

// Small ABI surface from Apple's IOHIDfamily HIDVirtualEventService.h, plus
// the C hinge-angle event factory IOHIDEventCreateHingeAngleEvent. Everything
// is resolved at runtime, so the guest library needs no private SDK stub:
// the factory is a dlsym, the service class an NSClassFromString.
@protocol VPhoneHingeHIDService <NSObject>
@property (weak) id delegate;
@property (readonly) uint64_t serviceID;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
- (void)setCancelHandler:(dispatch_block_t)handler;
- (void)activate;
- (void)cancel;
- (BOOL)dispatchEvent:(id)event;
@end

// HID.framework, verified against macOS 27.0.1's copy by calling it and
// reading the event's own field description back:
//     IOHIDEventCreateHingeAngleEvent(allocator, timeStamp,
//                                     angleDegrees, mechanicalAngleDegrees,
//                                     velocityDegreesPerSecond, options)
// CoreMotion's CLAngleNotifier consumes events of this type (0x2C) from the
// virtual service below. The created event carries the hinge state through
// HIDEvent's own -setHingeAngleState: accessor, the same field Apple's
// recorded Duo samples (hinge-samples.csv in SpringBoardFoundation) carry
// per sample.
typedef void *(*VPhoneHingeEventFactory)(void *, uint64_t, double, double, double, uint32_t);

// HIDEvent's hinge accessors, resolved at runtime beside the factory.
@protocol VPhoneHingeHIDEvent <NSObject>
- (void)setHingeAngleState:(int32_t)state;
@property (readonly) double hingeAngleAngleDegrees;
@end
