#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * The main display's own resolution, following the client's: the closest
 * display mode the Mac offers to the size the client asked for (in points,
 * and HiDPI for a client drawing at Retina density), as a Windows host
 * changes its session's resolution.
 *
 * Changed for this process only (kCGConfigureForAppOnly), so the Mac goes back
 * to its own mode when the daemon exits, even by a crash; -restore puts it
 * back when the session ends. RDP_MATCH_RESOLUTION=0 leaves the display alone.
 */
@interface MainDisplayMode : NSObject

- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID;

/* Whether the resolution follows the client at all (RDP_MATCH_RESOLUTION). */
@property (class, nonatomic, readonly) BOOL isEnabled;

/* Switches to the mode closest to pointWidth x pointHeight. YES when the
 * display's mode changed. */
- (BOOL)matchPointWidth:(double)pointWidth height:(double)pointHeight hiDPI:(BOOL)hiDPI;

/* Back to the mode the display had before the first match. */
- (void)restore;

@end

NS_ASSUME_NONNULL_END
