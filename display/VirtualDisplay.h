#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * VirtualDisplay: manages which CGDirectDisplayID the session captures.
 *
 * Without the com.apple.developer.virtual-display entitlement (which requires
 * an explicit Apple approval), CGVirtualDisplay symbols are not exported from
 * the SDK. We default to CGMainDisplayID() and add the virtual display path
 * behind MACOS_RDP_VIRTUAL_DISPLAY so it compiles only when the entitlement
 * is present and the binary is properly signed.
 */
@interface VirtualDisplay : NSObject

@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly) uint32_t width;
@property (nonatomic, readonly) uint32_t height;
/* Drawn at Retina density: the desktop is width/2 x height/2 points, backed by
 * width x height pixels. width/height are always the PIXEL size the client sees. */
@property (nonatomic, readonly) BOOL hiDPI;

- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height;
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height hiDPI:(BOOL)hiDPI;
- (BOOL)create;
- (void)destroy;
- (void)setResolutionWidth:(uint32_t)width height:(uint32_t)height;
/* Change a live virtual display's size and density in place (the display id,
 * and so the windows on it, stay). Returns NO when this is the main display
 * fallback or the mode could not be applied. */
- (BOOL)reconfigureWidth:(uint32_t)width height:(uint32_t)height hiDPI:(BOOL)hiDPI;

@end

NS_ASSUME_NONNULL_END
