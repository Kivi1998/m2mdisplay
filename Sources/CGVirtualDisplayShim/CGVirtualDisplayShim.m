#import "include/CGVirtualDisplayShim.h"
#import <Foundation/Foundation.h>

// CGVirtualDisplay is a private CoreGraphics class with no public headers.
// These interface declarations were reconstructed by introspecting the live
// Objective-C runtime on this machine (macOS 26.5.2 / Xcode 26.6) via
// class_copyMethodList / class_copyPropertyList — not guessed from memory —
// so the selectors/signatures below are known to match this OS build.
// The real implementation lives in CoreGraphics.framework at runtime; we're
// only declaring the interface so the compiler can emit correct calls.

NS_ASSUME_NONNULL_BEGIN

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) double refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, assign) NSUInteger hiDPI;
@property (nonatomic, copy) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic, assign) NSUInteger rotation;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) NSUInteger maxPixelsWide;
@property (nonatomic, assign) NSUInteger maxPixelsHigh;
@property (nonatomic, assign) CGSize sizeInMillimeters;
@property (nonatomic, assign) uint32_t productID;
@property (nonatomic, assign) uint32_t vendorID;
@property (nonatomic, assign) uint32_t serialNum;
@property (nonatomic, strong, nullable) dispatch_queue_t queue;
@property (nonatomic, copy, nullable) void (^terminationHandler)(id display, CGDirectDisplayID displayID);
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@end

NS_ASSUME_NONNULL_END

M2MVirtualDisplayRef M2MCreateVirtualDisplay(const char *name,
                                              uint32_t widthPx,
                                              uint32_t heightPx,
                                              double refreshRate,
                                              uint32_t widthMM,
                                              uint32_t heightMM,
                                              uint32_t *displayIDOut) {
    CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
    descriptor.name = [NSString stringWithUTF8String:name];
    descriptor.maxPixelsWide = widthPx;
    descriptor.maxPixelsHigh = heightPx;
    descriptor.sizeInMillimeters = CGSizeMake(widthMM, heightMM);
    descriptor.vendorID = 0x4D32; // "M2" — arbitrary, avoids colliding with real hardware vendor IDs
    descriptor.productID = 0x4D44; // "MD"
    descriptor.serialNum = 0x00000001;
    descriptor.queue = dispatch_queue_create("com.m2mdisplay.virtualdisplay", DISPATCH_QUEUE_SERIAL);
    descriptor.terminationHandler = ^(id display, CGDirectDisplayID displayID) {
        NSLog(@"[M2MDisplay] virtual display %u terminated", displayID);
    };

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (display == nil) {
        return NULL;
    }

    CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:widthPx
                                                                       height:heightPx
                                                                  refreshRate:refreshRate];
    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = 0;
    settings.modes = @[mode];

    BOOL ok = [display applySettings:settings];
    if (!ok) {
        return NULL;
    }

    if (displayIDOut != NULL) {
        *displayIDOut = display.displayID;
    }

    // Hand ownership to the caller as a +1 retained opaque pointer; released in
    // M2MDestroyVirtualDisplay via CFBridgingRelease.
    return (M2MVirtualDisplayRef)CFBridgingRetain(display);
}

void M2MDestroyVirtualDisplay(M2MVirtualDisplayRef ref) {
    if (ref == NULL) {
        return;
    }
    CFBridgingRelease(ref);
}
