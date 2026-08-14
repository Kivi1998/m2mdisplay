#import "include/CGVirtualDisplayShim.h"
#import <Foundation/Foundation.h>

// CGVirtualDisplay 是 CoreGraphics 私有类，没有公开头文件。
// 下列接口声明通过 class_copyMethodList 和 class_copyPropertyList，
// 从本机 macOS 26.5.2 / Xcode 26.6 的实时 Objective-C 运行时反省得到，
// 并非依靠记忆猜测，因此选择器和签名已确认与该系统版本匹配。
// 真正实现位于运行时的 CoreGraphics.framework 中；这里只声明接口，
// 使编译器能够生成正确调用。

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
                                              uint32_t logicalWidth,
                                              uint32_t logicalHeight,
                                              uint32_t maxPixelWidth,
                                              uint32_t maxPixelHeight,
                                              double refreshRate,
                                              uint32_t widthMM,
                                              uint32_t heightMM,
                                              uint32_t *displayIDOut) {
    CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
    descriptor.name = [NSString stringWithUTF8String:name];
    descriptor.maxPixelsWide = maxPixelWidth;
    descriptor.maxPixelsHigh = maxPixelHeight;
    descriptor.sizeInMillimeters = CGSizeMake(widthMM, heightMM);
    descriptor.vendorID = 0x4D32; // “M2”，任意取值，用于避免与真实硬件厂商编号冲突
    descriptor.productID = 0x4D44; // 使用“M2M Display”首字母“MD”
    descriptor.serialNum = 0x00000001;
    descriptor.queue = dispatch_queue_create("com.m2mdisplay.virtualdisplay", DISPATCH_QUEUE_SERIAL);
    descriptor.terminationHandler = ^(id display, CGDirectDisplayID displayID) {
        NSLog(@"[M2MDisplay] virtual display %u terminated", displayID);
    };

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (display == nil) {
        return NULL;
    }

    CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:logicalWidth
                                                                       height:logicalHeight
                                                                  refreshRate:refreshRate];
    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    // 注册为 Retina/HiDPI 模式。描述符声明后备像素上限，
    // 显示模式则报告以点为单位的桌面尺寸。
    settings.hiDPI = 1;
    settings.modes = @[mode];

    BOOL ok = [display applySettings:settings];
    if (!ok) {
        return NULL;
    }

    if (displayIDOut != NULL) {
        *displayIDOut = display.displayID;
    }

    // 以持有计数加一的不透明指针形式把所有权交给调用方；
    // 随后由 M2MDestroyVirtualDisplay 通过 CFBridgingRelease 释放。
    return (M2MVirtualDisplayRef)CFBridgingRetain(display);
}

void M2MDestroyVirtualDisplay(M2MVirtualDisplayRef ref) {
    if (ref == NULL) {
        return;
    }
    CFBridgingRelease(ref);
}
