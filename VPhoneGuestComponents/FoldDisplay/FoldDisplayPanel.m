// SpringBoard: one physical panel for two displays. The cover and the inner
// display share this guest's only scanout, the primary; open, SpringBoard
// composites the inner display onto it.

#import "FoldDisplayPrivate.h"

static void vpShowInnerDisplay(BOOL shown);

// MARK: - power

// SpringBoard powers each panel through its CADisplayStateControl (state 1
// on, 0 off): open, the cover (primary, display 1) goes off and the inner
// display on; closed, the reverse. On this guest the primary is the only
// scanout, and open it has to show the inner display, which SpringBoard
// composites onto it (vpShowInnerDisplay). So the primary is kept on while
// either panel wants it; a screen-off turns both off. Closing does not turn
// the inner display off, so the inner display is lit only while the cover is
// not: the cover wins the shared panel. The compositor and backboardd's touch
// routing follow the inner display's applied state.
static IMP vpOriginalTransitionDisplayState;
static id vpPrimaryStateControl, vpInnerStateControl;
static long long vpPrimaryWantedState = 1, vpPrimaryAppliedState = 1, vpInnerWantedState, vpInnerAppliedState = -1;

static unsigned int vpStateControlDisplayId(id control) {
    Ivar ivar = class_getInstanceVariable(object_getClass(control), "_display_id");
    if (!ivar || strcmp(ivar_getTypeEncoding(ivar), "I") != 0) return 0;
    return *(unsigned int *)((uint8_t *)(__bridge void *)control + ivar_getOffset(ivar));
}

static void vpApplyPanelState(id control, long long state, long long *applied, id completion) {
    if (!control || (state == *applied && !completion)) return;
    *applied = state;
    ((void (*)(id, SEL, long long, id))vpOriginalTransitionDisplayState)(control,
        sel_registerName("transitionToDisplayState:withCompletion:"), state, completion);
}

static void vpApplyPanelStates(id primaryCompletion, id innerCompletion) {
    vpApplyPanelState(vpPrimaryStateControl, vpPrimaryWantedState || vpInnerWantedState ? 1 : 0,
        &vpPrimaryAppliedState, primaryCompletion);
    long long inner = vpInnerWantedState && !vpPrimaryWantedState ? 1 : 0;
    BOOL changed = inner != vpInnerAppliedState;
    vpApplyPanelState(vpInnerStateControl, inner, &vpInnerAppliedState, innerCompletion);
    if (changed && vpInnerStateControl) dispatch_async(dispatch_get_main_queue(), ^{ vpShowInnerDisplay(inner != 0); });
}

// SpringBoard asks for a transition only when it wants a state the panel is
// not in; after a SpringBoard restart the inner display may already be lit and
// is never asked about. So until it is, its wanted state is the state it has.
static void vpAdoptInnerStateControl(void) {
    if (vpInnerStateControl) return;
    for (id display in vpReadObject(objc_getClass("CADisplay"), "displays") ?: @[]) {
        if (!vpIsInnerDisplay(display)) continue;
        id control = vpReadObject(display, "stateControl");
        Method current = class_getInstanceMethod(object_getClass(control), sel_registerName("displayState"));
        if (!current || strcmp(method_getTypeEncoding(current), "q16@0:8") != 0) return;
        vpInnerWantedState = vpInnerAppliedState =
            ((long long (*)(id, SEL))objc_msgSend)(control, sel_registerName("displayState")) != 0;
        vpInnerStateControl = control;
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: adopted state %lld", vpInnerWantedState]);
        if (vpInnerWantedState) dispatch_async(dispatch_get_main_queue(), ^{ vpShowInnerDisplay(YES); });
        return;
    }
}

static void vpSharedScanoutTransition(id self, SEL selector, long long state, id completion) {
    unsigned int displayId = vpStateControlDisplayId(self);
    vpFoldDisplayLog([NSString stringWithFormat:@"inner display: display %u wants state %lld", displayId, state]);
    if (displayId == 1) {
        vpAdoptInnerStateControl();
        vpPrimaryStateControl = self;
        vpPrimaryWantedState = state;
        vpApplyPanelStates(completion, nil);
        return;
    }
    id innerDisplay = nil;
    for (id display in vpReadObject(objc_getClass("CADisplay"), "displays") ?: @[])
        if ([[display valueForKey:@"displayId"] unsignedIntValue] == displayId && vpIsInnerDisplay(display)) innerDisplay = display;
    if (!innerDisplay) {
        ((void (*)(id, SEL, long long, id))vpOriginalTransitionDisplayState)(self, selector, state, completion);
        return;
    }
    vpInnerStateControl = self;
    vpInnerWantedState = state;
    vpApplyPanelStates(nil, completion);
}

void vpInstallSharedPanel(void) {
    Method transition = class_getInstanceMethod(objc_getClass("CADisplayStateControl"),
        sel_registerName("transitionToDisplayState:withCompletion:"));
    const char *encoding = transition ? method_getTypeEncoding(transition) : "missing";
    Ivar displayId = class_getInstanceVariable(objc_getClass("CADisplayStateControl"), "_display_id");
    if (strcmp(encoding, "v32@0:8q16@?24") != 0 || !displayId || strcmp(ivar_getTypeEncoding(displayId), "I") != 0) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: shared scanout ABI unavailable (%s)", encoding]);
        return;
    }
    vpOriginalTransitionDisplayState = method_setImplementation(transition, (IMP)vpSharedScanoutTransition);
    vpFoldDisplayLog(@"inner display: shared scanout installed");
}

// MARK: - compositing

// The render server's own clone of a display (addClone:options:) never
// reaches this guest's paravirtual panel, so SpringBoard composites instead:
// a layer at the top of Main's root scene window (UIRootSceneWindow, the
// window Main's scenes are hosted in) hosts every window of the inner
// display's scenes by render context (CALayerHost, as scene hosting does). It
// is not in a window of SB-main, because open, SpringBoard gives the cover
// (Main) auxiliary content and takes its scene's windows off screen. Like
// every window it works in points, so the display's scale applies and UIKit's
// screen capture sees it as it sees the rest of the screen (a layer of its
// own on the display works in pixels, and the capture magnifies it by the
// screen scale). Touches on the hosted windows reach their owners through
// backboardd's render-tree hit test.
//
// The render server redraws a display for commits to its own contexts only;
// a commit by an inner-display context (an application changing its pixels)
// leaves the hosting primary display on its last frame. So while shown, a
// layer over the whole panel changes once per primary frame: its background
// alternates between two clear colors, which damages every pixel without
// a visible change. (An opacity flip on the container does the same, but
// below 1 the container renders offscreen as a group, and hosted secure
// windows come out as grey blocks on those frames.)
static id vpInnerHostRoot, vpInnerHostContainer, vpInnerHostDamage, vpInnerHostRefresh;
static CFRunLoopObserverRef vpInnerHostObserver;
static NSMutableDictionary<NSNumber *, id> *vpInnerHostLayers;
static CGSize vpInnerHostPanel;

@interface VPhoneInnerHostRefresh : NSObject
@end

@implementation VPhoneInnerHostRefresh
- (void)refresh:(id)link {
    static CGColorRef clear, faint;
    static BOOL flip;
    if (!clear) {
        clear = CGColorCreateSRGB(0, 0, 0, 0);
        faint = CGColorCreateSRGB(1, 1, 1, 0);
    }
    flip = !flip;
    Class transaction = objc_getClass("CATransaction");
    ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("begin"));
    ((void (*)(id, SEL, BOOL))objc_msgSend)(transaction, sel_registerName("setDisableActions:"), YES);
    ((void (*)(id, SEL, CGColorRef))objc_msgSend)(vpInnerHostDamage, sel_registerName("setBackgroundColor:"), flip ? faint : clear);
    ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("commit"));
}
@end

static id vpMainRootSceneWindow(void) {
    NSArray *windows = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(objc_getClass("UIWindow"),
        sel_registerName("allWindowsIncludingInternalWindows:onlyVisibleWindows:"), YES, NO);
    for (id window in windows)
        if ([window isKindOfClass:objc_getClass("UIRootSceneWindow")] &&
            [[vpReadObject(vpReadObject(window, "screen"), "displayIdentity") description] isEqual:@"Main"]) return window;
    return nil;
}

// The inner display's points are fitted onto the panel's points, turned a
// quarter (-90 degrees) if they read landscape on the portrait panel,
// centered, shrunk only if they do not fit.
static void vpFitInnerHosts(CGRect inner) {
    CGRect panel = ((CGRect (*)(id, SEL))objc_msgSend)(vpReadObject(vpInnerHostRoot, "superlayer"), sel_registerName("bounds"));
    if (CGSizeEqualToSize(panel.size, vpInnerHostPanel)) return;
    vpInnerHostPanel = panel.size;
    ((void (*)(id, SEL, CGRect))objc_msgSend)(vpInnerHostRoot, sel_registerName("setFrame:"), panel);
    ((void (*)(id, SEL, CGRect))objc_msgSend)(vpInnerHostDamage, sel_registerName("setFrame:"), panel);
    BOOL turned = inner.size.width > inner.size.height;
    CGSize upright = turned ? CGSizeMake(inner.size.height, inner.size.width) : inner.size;
    CGFloat scale = MIN(1, MIN(panel.size.width / upright.width, panel.size.height / upright.height));
    CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
    if (turned) transform = CGAffineTransformRotate(transform, -M_PI_2);
    id container = vpInnerHostContainer;
    ((void (*)(id, SEL, CGRect))objc_msgSend)(container, sel_registerName("setBounds:"), (CGRect){CGPointZero, inner.size});
    ((void (*)(id, SEL, CGPoint))objc_msgSend)(container, sel_registerName("setPosition:"), CGPointMake(CGRectGetMidX(panel), CGRectGetMidY(panel)));
    ((void (*)(id, SEL, CGAffineTransform))objc_msgSend)(container, sel_registerName("setAffineTransform:"), transform);
    vpFoldDisplayLog([NSString stringWithFormat:@"inner display: fitted panel={%.0f, %.0f} inner={%.0f, %.0f} turned=%d scale=%.3f",
        panel.size.width, panel.size.height, inner.size.width, inner.size.height, turned, scale]);
}

// Runs just before Core Animation commits each main run loop turn, so a
// window SpringBoard shows or hides and its host change in one transaction:
// syncing later leaves a frame without the window's content.
static void vpSyncInnerHosts(void) {
    Class transaction = objc_getClass("CATransaction");
    ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("begin"));
    ((void (*)(id, SEL, BOOL))objc_msgSend)(transaction, sel_registerName("setDisableActions:"), YES);
    id app = vpReadObject(objc_getClass("UIApplication"), "sharedApplication");
    id innerScene = vpSpringBoardWindowScene(YES);
    if (innerScene)
        vpFitInnerHosts(((CGRect (*)(id, SEL))objc_msgSend)(vpReadObject(innerScene, "coordinateSpace"), sel_registerName("bounds")));
    NSMutableArray *windows = [NSMutableArray array];
    for (id scene in [vpReadObject(app, "connectedScenes") allObjects] ?: @[])
        if ([scene isKindOfClass:objc_getClass("UIWindowScene")] && vpSceneIsOnInnerDisplay(scene))
            for (id window in vpReadObject(scene, "windows") ?: @[])
                if (![[window valueForKey:@"hidden"] boolValue]) [windows addObject:window];
    [windows sortUsingComparator:^NSComparisonResult(id a, id b) {
        return [[a valueForKey:@"windowLevel"] compare:[b valueForKey:@"windowLevel"]];
    }];
    NSMutableSet *live = [NSMutableSet set];
    SEL contextIdSelector = sel_registerName("_contextId");
    for (NSUInteger index = 0; index < windows.count; index++) {
        id window = windows[index];
        if (![window respondsToSelector:contextIdSelector]) continue;
        unsigned int contextId = ((unsigned int (*)(id, SEL))objc_msgSend)(window, contextIdSelector);
        if (!contextId) continue;
        NSNumber *key = @(contextId);
        [live addObject:key];
        id host = vpInnerHostLayers[key];
        if (!host) {
            host = [objc_getClass("CALayerHost") new];
            ((void (*)(id, SEL, unsigned int))objc_msgSend)(host, sel_registerName("setContextId:"), contextId);
            ((void (*)(id, SEL, id))objc_msgSend)(vpInnerHostContainer, sel_registerName("addSublayer:"), host);
            vpInnerHostLayers[key] = host;
        }
        // Re-setting an unchanged frame or zPosition makes the render server
        // drop every hosted window for a frame.
        CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(window, sel_registerName("frame"));
        if (!CGRectEqualToRect(((CGRect (*)(id, SEL))objc_msgSend)(host, sel_registerName("frame")), frame))
            ((void (*)(id, SEL, CGRect))objc_msgSend)(host, sel_registerName("setFrame:"), frame);
        if (((double (*)(id, SEL))objc_msgSend)(host, sel_registerName("zPosition")) != index)
            ((void (*)(id, SEL, double))objc_msgSend)(host, sel_registerName("setZPosition:"), index);
    }
    for (NSNumber *key in vpInnerHostLayers.allKeys) {
        if ([live containsObject:key]) continue;
        ((void (*)(id, SEL))objc_msgSend)(vpInnerHostLayers[key], sel_registerName("removeFromSuperlayer"));
        [vpInnerHostLayers removeObjectForKey:key];
    }
    ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("commit"));
}

static void vpShowInnerDisplay(BOOL shown) {
    @try {
        if (!shown) {
            if (!vpInnerHostRoot) return;
            CFRunLoopObserverInvalidate(vpInnerHostObserver);
            CFRelease(vpInnerHostObserver);
            vpInnerHostObserver = NULL;
            ((void (*)(id, SEL))objc_msgSend)(vpInnerHostRefresh, sel_registerName("invalidate"));
            vpInnerHostRefresh = nil;
            ((void (*)(id, SEL))objc_msgSend)(vpInnerHostRoot, sel_registerName("removeFromSuperlayer"));
            vpInnerHostRoot = vpInnerHostContainer = vpInnerHostDamage = nil;
            vpInnerHostLayers = nil;
            vpInnerHostPanel = CGSizeZero;
            vpFoldDisplayLog(@"inner display: shown=0");
            return;
        }
        if (vpInnerHostRoot) return;
        id rootWindow = vpMainRootSceneWindow();
        Method hostContext = class_getInstanceMethod(objc_getClass("CALayerHost"), sel_registerName("setContextId:"));
        if (!rootWindow || !hostContext || strcmp(method_getTypeEncoding(hostContext), "v20@0:8I16") != 0) {
            vpFoldDisplayLog([NSString stringWithFormat:@"inner display: show unavailable root=%@ host=%s", rootWindow,
                hostContext ? method_getTypeEncoding(hostContext) : "missing"]);
            return;
        }
        id root = [objc_getClass("CALayer") new];
        ((void (*)(id, SEL, CGColorRef))objc_msgSend)(root, sel_registerName("setBackgroundColor:"),
            ((CGColorRef (*)(id, SEL))objc_msgSend)(vpReadObject(objc_getClass("UIColor"), "blackColor"), sel_registerName("CGColor")));
        id container = [objc_getClass("CALayer") new];
        ((void (*)(id, SEL, id))objc_msgSend)(root, sel_registerName("addSublayer:"), container);
        id damage = [objc_getClass("CALayer") new];
        ((void (*)(id, SEL, id))objc_msgSend)(root, sel_registerName("addSublayer:"), damage);
        vpInnerHostDamage = damage;
        ((void (*)(id, SEL, double))objc_msgSend)(root, sel_registerName("setZPosition:"), 1.0e9);
        ((void (*)(id, SEL, id))objc_msgSend)(vpReadObject(rootWindow, "layer"), sel_registerName("addSublayer:"), root);
        vpInnerHostRoot = root;
        vpInnerHostContainer = container;
        vpInnerHostLayers = [NSMutableDictionary dictionary];
        vpInnerHostPanel = CGSizeZero;
        vpSyncInnerHosts();
        // Order 1999999: just before Core Animation's commit observer (2000000).
        vpInnerHostObserver = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit, true,
            1999999, ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) { vpSyncInnerHosts(); });
        CFRunLoopAddObserver(CFRunLoopGetMain(), vpInnerHostObserver, kCFRunLoopCommonModes);
        vpInnerHostRefresh = ((id (*)(id, SEL, id, SEL))objc_msgSend)(objc_getClass("CADisplayLink"),
            sel_registerName("displayLinkWithTarget:selector:"), [VPhoneInnerHostRefresh new], @selector(refresh:));
        ((void (*)(id, SEL, id, id))objc_msgSend)(vpInnerHostRefresh, sel_registerName("addToRunLoop:forMode:"),
            NSRunLoop.mainRunLoop, NSRunLoopCommonModes);
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: shown=1 hosts=%lu", (unsigned long)vpInnerHostLayers.count]);
    } @catch (NSException *exception) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: show exception %@", exception.reason]);
    }
}
