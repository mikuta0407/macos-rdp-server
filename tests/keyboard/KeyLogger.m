/*
 * KeyLogger — tiny GUI app for verifying injected keyboard input on the server.
 *
 * Shows a text view (so the Japanese IME composes normally) and appends one line
 * per keyDown / flagsChanged to $KEYLOG_DIR/keylog-events.txt (default /tmp):
 *   type keyCode kbType chars charsIgnoringMods mods inputSource
 * The committed text is mirrored to keylog-text.txt on every change, and
 * mouse-down click counts are logged too.
 * Build: tests/keyboard/build.sh   Run (in the GUI session): open KeyLogger.app
 */
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>

static NSString *gDir;

static void append_line(NSString *line) {
    NSString *path = [gDir stringByAppendingPathComponent:@"keylog-events.txt"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [@"" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    [fh seekToEndOfFile];
    [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static NSString *current_source(void) {
    TISInputSourceRef s = TISCopyCurrentKeyboardInputSource();
    NSString *sid = (__bridge NSString *)TISGetInputSourceProperty(s, kTISPropertyInputSourceID);
    NSString *r = [sid copy];
    CFRelease(s);
    return r;
}

static NSString *visible(NSString *s) {
    NSMutableString *o = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c < 0x20 || c == 0x7F || (c >= 0xF700 && c <= 0xF8FF)) [o appendFormat:@"<%04X>", c];
        else [o appendFormat:@"%C", c];
    }
    return o.length ? o : @"-";
}

@interface Delegate : NSObject <NSApplicationDelegate, NSTextViewDelegate>
@property (strong) NSWindow *window;
@property (strong) NSTextView *text;
@end

@implementation Delegate
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    /* Minimal menu bar so ⌘ shortcuts (⌘A/⌘C/⌘V/⌘Z/⌘Q) behave as in real apps. */
    NSMenu *bar = [NSMenu new];
    NSMenuItem *appItem = [bar addItemWithTitle:@"" action:nil keyEquivalent:@""];
    appItem.submenu = [NSMenu new];
    [appItem.submenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    NSMenuItem *editItem = [bar addItemWithTitle:@"Edit" action:nil keyEquivalent:@""];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = edit;
    NSApp.mainMenu = bar;

    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 640, 360)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"KeyLogger";
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:[self.window.contentView bounds]];
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.text = [[NSTextView alloc] initWithFrame:sv.bounds];
    self.text.font = [NSFont systemFontOfSize:20];
    self.text.delegate = self;
    self.text.automaticQuoteSubstitutionEnabled = NO;
    self.text.automaticDashSubstitutionEnabled = NO;
    self.text.automaticTextReplacementEnabled = NO;
    self.text.automaticSpellingCorrectionEnabled = NO;
    sv.documentView = self.text;
    self.window.contentView = sv;
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.text];
    [NSApp activateIgnoringOtherApps:YES];

    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskFlagsChanged |
                                                  NSEventMaskLeftMouseDown | NSEventMaskSystemDefined
                                          handler:^NSEvent *(NSEvent *e) {
        if (e.type == NSEventTypeLeftMouseDown) {
            append_line([NSString stringWithFormat:@"mouse clickCount=%ld mods=0x%lx", (long)e.clickCount,
                         (unsigned long)e.modifierFlags]);
            return e;
        }
        if (e.type == NSEventTypeSystemDefined) return e;
        int64_t kbType = CGEventGetIntegerValueField(e.CGEvent, kCGKeyboardEventKeyboardType);
        BOOL isKey = e.type == NSEventTypeKeyDown;
        append_line([NSString stringWithFormat:@"%@ kc=%u kbType=%lld chars=%@ ign=%@ mods=0x%lx repeat=%d src=%@",
                     isKey ? @"down" : @"flags", e.keyCode, kbType,
                     isKey ? visible(e.characters) : @"-",
                     isKey ? visible(e.charactersIgnoringModifiers) : @"-",
                     (unsigned long)e.modifierFlags, isKey ? e.isARepeat : 0, current_source()]);
        return e;
    }];
}
- (void)textDidChange:(NSNotification *)n {
    [self.text.string writeToFile:[gDir stringByAppendingPathComponent:@"keylog-text.txt"]
                       atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        const char *d = getenv("KEYLOG_DIR");
        gDir = d ? @(d) : @"/tmp";
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        Delegate *del = [Delegate new];
        app.delegate = del;
        [app run];
    }
    return 0;
}
