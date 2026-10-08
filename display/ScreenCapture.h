#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurface.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ScreenCaptureFrameBlock)(IOSurfaceRef surface,
                                        uint32_t width, uint32_t height,
                                        CGRect dirtyRect);

@interface ScreenCapture : NSObject

@property (nonatomic, readonly) BOOL isCapturing;
@property (nonatomic, copy, nullable) ScreenCaptureFrameBlock frameHandler;

- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID;
- (BOOL)startWithWidth:(uint32_t)width height:(uint32_t)height;
- (void)stop;
/* Frame-rate cap (1...120). Set before start, or while running. */
@property (nonatomic, assign) uint32_t maxFps;

@end

NS_ASSUME_NONNULL_END
