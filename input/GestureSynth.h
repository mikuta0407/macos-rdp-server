/*
 * GestureSynth — trackpad gestures posted as the events a real Multi-Touch
 * trackpad produces, so macOS and the app under the pointer react as they
 * would to the user's own fingers: pinch to zoom, rotate, smart zoom, the
 * two-finger swipe between pages, and the Dock's swipes (Spaces, Mission
 * Control, App Exposé) that follow the fingers.
 *
 * None of this is public API. The event types (NSEventTypeGesture 29,
 * NSEventTypeMagnify 30 as the Dock's carrier) and the CGEvent field numbers
 * are what WindowServer itself fills in, as read back from real trackpad
 * events; the same recipe is used by long-lived tools (Mac Mouse Fix's
 * TouchSimulator). A macOS release may change them, so every caller has a
 * fallback that does not depend on them.
 */
#ifndef GESTURE_SYNTH_H
#define GESTURE_SYNTH_H

#include <stdint.h>

/* IOHIDEventPhaseBits — not NSEvent.Phase: Changed is 2 here. */
enum {
    GS_PHASE_BEGAN = 1,
    GS_PHASE_CHANGED = 2,
    GS_PHASE_ENDED = 4,
    GS_PHASE_CANCELLED = 8,
};

/* The Dock's swipes, by the axis the fingers move along. */
typedef enum {
    GS_DOCK_HORIZONTAL = 1,     /* Spaces / full-screen apps */
    GS_DOCK_VERTICAL = 2,       /* Mission Control (up), App Exposé (down) */
} gs_dock_axis;

/* IOHIDSwipeMask: the direction the content moves for a navigation swipe. */
typedef enum {
    GS_SWIPE_UP = 1,
    GS_SWIPE_DOWN = 2,
    GS_SWIPE_LEFT = 4,
    GS_SWIPE_RIGHT = 8,
} gs_swipe_direction;

/* magnification: the change since the previous event (0.1 = 10 % larger). */
void gs_post_magnify(double magnification, uint32_t phase);
/* rotation: degrees since the previous event, counter-clockwise positive. */
void gs_post_rotate(double degrees, uint32_t phase);
/* A two-finger double tap. */
void gs_post_smart_zoom(void);
/* Back / forward between pages, as a completed two-finger swipe. */
void gs_post_navigation_swipe(gs_swipe_direction direction);
/* progress: how far the gesture has gone in total, in screen widths (or
 * heights); positive left/up as the fingers move. velocity matters only on
 * the ending event: it decides whether a short swipe still completes. */
void gs_post_dock_swipe(gs_dock_axis axis, double progress, uint32_t phase, double velocity);

/* The gesture event a trackpad sends alongside each scroll of a gesture
 * (IOHIDEventTypeScroll). Apps that track a swipe from scrolling - Safari's
 * swipe between pages - read the gesture from it. Deltas in points. */
void gs_post_scroll_gesture(double dx, double dy, uint32_t phase);

/* `macos-rdp-daemon --gesture-probe ...`: posts one gesture and exits. */
int gs_probe_main(int argc, char **argv);

#endif
