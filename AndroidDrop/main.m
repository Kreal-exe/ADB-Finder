#import <Cocoa/Cocoa.h>

static NSString * const kDefaultRemote = @"/sdcard/Downloads";

@class AppController;
@class BrowserController;

@interface DropView : NSView
@property(nonatomic, copy) void (^handler)(NSArray<NSURL *> *urls);
@property(nonatomic, assign) BOOL highlighted;
@end

@interface BrowserController : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@property(nonatomic, weak) AppController *owner;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTableView *table;
@property(nonatomic, strong) NSTextField *pathField;
@property(nonatomic, strong) NSTextField *footer;
@property(nonatomic, strong) NSArray<NSDictionary *> *items;
@property(nonatomic, copy) NSString *current;
@property(nonatomic, assign) BOOL loading;
- (void)show;
- (void)close;
@end

@interface AppController : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) DropView *drop;
@property(nonatomic, strong) NSTextField *deviceLabel;
@property(nonatomic, strong) NSTextField *pathField;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSProgressIndicator *progress;
@property(nonatomic, copy) NSString *serial;
@property(nonatomic, copy) NSString *remotePath;
@property(nonatomic, strong) NSTimer *deviceTimer;
@property(nonatomic, assign) BOOL deviceRefreshRunning;
@property(nonatomic, strong) BrowserController *browser;
@property(nonatomic, assign) BOOL transferring;

- (NSString *)adbPath;
- (NSString *)normalizedPath:(NSString *)path;
- (BOOL)runADB:(NSArray<NSString *> *)arguments output:(NSString **)output error:(NSString **)errorText;
- (BOOL)runADBShell:(NSString *)command serial:(NSString *)serial output:(NSString **)output error:(NSString **)errorText;
- (NSString *)shellQuote:(NSString *)value;
- (NSString *)safeName:(NSString *)name;
- (NSString *)deviceDisplayNameForSerial:(NSString *)serial;
- (void)appendLog:(NSString *)message;
- (void)refreshDevice;
- (void)sendURLs:(NSArray<NSURL *> *)urls;
- (void)browse:(id)sender;
- (void)buildUI;
- (void)buildMenu;
@end

@implementation DropView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
        self.wantsLayer = YES;
    }
    return self;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    (void)sender;
    self.highlighted = YES;
    [self setNeedsDisplay:YES];
    return NSDragOperationCopy;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    (void)sender;
    self.highlighted = NO;
    [self setNeedsDisplay:YES];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    self.highlighted = NO;
    [self setNeedsDisplay:YES];

    NSArray<NSURL *> *urls =
        [sender.draggingPasteboard readObjectsForClasses:@[[NSURL class]]
                                                 options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];

    if (urls.count > 0 && self.handler) {
        self.handler(urls);
    }
    return urls.count > 0;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;

    NSRect r = NSInsetRect(self.bounds, 1, 1);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:r xRadius:22 yRadius:22];

    NSColor *fill = self.highlighted
        ? [NSColor colorWithCalibratedRed:0.92 green:0.96 blue:1.0 alpha:1.0]
        : [NSColor colorWithCalibratedWhite:0.985 alpha:1.0];

    [fill setFill];
    [path fill];

    [[NSColor colorWithCalibratedRed:0.40 green:0.62 blue:0.92 alpha:1.0] setStroke];
    [path setLineWidth:self.highlighted ? 2.0 : 1.0];
    [path stroke];

    NSDictionary *titleAttrs = @{
        NSFontAttributeName:[NSFont systemFontOfSize:25 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName:[NSColor labelColor]
    };
    NSDictionary *subAttrs = @{
        NSFontAttributeName:[NSFont systemFontOfSize:14],
        NSForegroundColorAttributeName:[NSColor secondaryLabelColor]
    };

    NSString *title = @"Drop files or folders";
    NSString *subtitle = @"Sending starts automatically";

    NSSize a = [title sizeWithAttributes:titleAttrs];
    NSSize b = [subtitle sizeWithAttributes:subAttrs];

    [title drawAtPoint:NSMakePoint(NSMidX(self.bounds) - a.width / 2.0,
                                   NSMidY(self.bounds) + 10.0)
        withAttributes:titleAttrs];

    [subtitle drawAtPoint:NSMakePoint(NSMidX(self.bounds) - b.width / 2.0,
                                      NSMidY(self.bounds) - 20.0)
            withAttributes:subAttrs];
}

@end

@implementation AppController

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    // The address field starts at Downloads.
    // Browse intentionally starts at the root of shared Android storage.
    self.remotePath = kDefaultRemote;

    [self buildMenu];
    [self buildUI];
    [self refreshDevice];

    self.deviceTimer =
        [NSTimer scheduledTimerWithTimeInterval:1.0
                                         target:self
                                       selector:@selector(deviceTimerTick:)
                                       userInfo:nil
                                        repeats:YES];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    return NSTerminateNow;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.deviceTimer invalidate];
    self.deviceTimer = nil;
}

- (void)terminateApp:(id)sender {
    [NSApp terminate:sender];
}

- (void)buildMenu {
    NSMenu *main = [[NSMenu alloc] initWithTitle:@"Main Menu"];

    NSMenuItem *appItem =
        [[NSMenuItem alloc] initWithTitle:@"Android Drop"
                                   action:nil
                            keyEquivalent:@""];

    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Android Drop"];

    [appMenu addItemWithTitle:@"About Android Drop"
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit =
        [[NSMenuItem alloc] initWithTitle:@"Quit Android Drop"
                                   action:@selector(terminateApp:)
                            keyEquivalent:@"q"];
    quit.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    quit.target = self;

    [appMenu addItem:quit];
    appItem.submenu = appMenu;
    [main addItem:appItem];

    NSMenuItem *editItem =
        [[NSMenuItem alloc] initWithTitle:@"Edit"
                                   action:nil
                            keyEquivalent:@""];

    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];

    NSMenuItem *copy =
        [[NSMenuItem alloc] initWithTitle:@"Copy"
                                   action:@selector(copy:)
                            keyEquivalent:@"c"];
    copy.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [edit addItem:copy];

    NSMenuItem *paste =
        [[NSMenuItem alloc] initWithTitle:@"Paste"
                                   action:@selector(paste:)
                            keyEquivalent:@"v"];
    paste.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [edit addItem:paste];

    NSMenuItem *selectAll =
        [[NSMenuItem alloc] initWithTitle:@"Select All"
                                   action:@selector(selectAll:)
                            keyEquivalent:@"a"];
    selectAll.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [edit addItem:selectAll];

    editItem.submenu = edit;
    [main addItem:editItem];

    [NSApp setMainMenu:main];
}

- (void)buildUI {
    const CGFloat width = 700.0;
    const CGFloat height = 560.0;

    NSRect screen = NSScreen.mainScreen.visibleFrame;
    NSRect frame = NSMakeRect(NSMidX(screen) - width / 2.0,
                              NSMidY(screen) - height / 2.0,
                              width,
                              height);

    self.window =
        [[NSWindow alloc] initWithContentRect:frame
                                    styleMask:(NSWindowStyleMaskTitled |
                                               NSWindowStyleMaskClosable |
                                               NSWindowStyleMaskMiniaturizable |
                                               NSWindowStyleMaskResizable)
                                      backing:NSBackingStoreBuffered
                                        defer:NO];

    self.window.title = @"Android Drop";
    self.window.minSize = NSMakeSize(620.0, 500.0);
    self.window.releasedWhenClosed = NO;

    NSView *content = self.window.contentView;

    self.deviceLabel = [NSTextField labelWithString:@"●  Checking for Android device…"];
    self.deviceLabel.frame = NSMakeRect(32, height - 58, width - 64, 26);
    self.deviceLabel.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
    self.deviceLabel.textColor = NSColor.secondaryLabelColor;
    self.deviceLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:self.deviceLabel];

    NSTextField *sendLabel = [NSTextField labelWithString:@"Send to"];
    sendLabel.frame = NSMakeRect(32, height - 105, 70, 28);
    sendLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    sendLabel.autoresizingMask = NSViewMinYMargin;
    [content addSubview:sendLabel];

    self.pathField = [NSTextField textFieldWithString:kDefaultRemote];
    self.pathField.frame = NSMakeRect(105, height - 108, width - 225, 34);
    self.pathField.font = [NSFont systemFontOfSize:14];
    self.pathField.placeholderString = @"/sdcard/";
    self.pathField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.pathField.target = self;
    self.pathField.action = @selector(pathFieldChanged:);
    [content addSubview:self.pathField];

    NSButton *browse =
        [NSButton buttonWithTitle:@"Browse…"
                           target:self
                           action:@selector(browse:)];
    browse.frame = NSMakeRect(width - 110, height - 109, 82, 36);
    browse.bezelStyle = NSBezelStyleRounded;
    browse.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [content addSubview:browse];

    self.drop =
        [[DropView alloc] initWithFrame:NSMakeRect(32, 125, width - 64, height - 250)];
    self.drop.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    __weak AppController *weakSelf = self;
    self.drop.handler = ^(NSArray<NSURL *> *urls) {
        [weakSelf sendURLs:urls];
    };

    [content addSubview:self.drop];

    self.progress =
        [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(72, 84, width - 144, 8)];
    self.progress.indeterminate = NO;
    self.progress.minValue = 0.0;
    self.progress.maxValue = 1.0;
    self.progress.doubleValue = 0.0;
    self.progress.style = NSProgressIndicatorStyleBar;
    self.progress.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:self.progress];

    self.statusLabel = [NSTextField labelWithString:@"Ready · drop files or folders"];
    self.statusLabel.frame = NSMakeRect(32, 48, width - 64, 26);
    self.statusLabel.alignment = NSTextAlignmentCenter;
    self.statusLabel.font = [NSFont systemFontOfSize:13];
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:self.statusLabel];

    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)pathFieldChanged:(id)sender {
    (void)sender;
    self.remotePath = [self normalizedPath:self.pathField.stringValue];
    self.pathField.stringValue = self.remotePath;
}

- (NSString *)adbPath {
    NSArray<NSString *> *paths = @[
        @"/opt/homebrew/bin/adb",
        @"/usr/local/bin/adb",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Android/sdk/platform-tools/adb"],
        @"/usr/bin/adb"
    ];

    for (NSString *path in paths) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
            return path;
        }
    }

    return @"adb";
}

- (void)appendLog:(NSString *)message {
    NSString *dir =
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];

    [[NSFileManager defaultManager]
        createDirectoryAtPath:dir
        withIntermediateDirectories:YES
        attributes:nil
        error:nil];

    NSString *path = [dir stringByAppendingPathComponent:@"AndroidDrop.log"];

    NSString *line =
        [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message ?: @""];

    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    [fh seekToEndOfFile];
    [fh writeData:data];
    [fh closeFile];
}

- (BOOL)runADB:(NSArray<NSString *> *)arguments
        output:(NSString **)output
         error:(NSString **)errorText {

    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:[self adbPath]];
    task.arguments = arguments;

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    [self appendLog:
        [NSString stringWithFormat:@"ADB %@", [arguments componentsJoinedByString:@" "]]];

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        NSString *msg = launchError.localizedDescription ?: @"Could not start adb";
        [self appendLog:[NSString stringWithFormat:@"ADB LAUNCH ERROR: %@", msg]];
        if (errorText) *errorText = msg;
        return NO;
    }

    [task waitUntilExit];

    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];

    NSString *text =
        [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    if (!text) {
        text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }

    if (!text) text = @"";

    if (output) *output = text;

    if (task.terminationStatus != 0) {
        NSString *msg = text.length ? text : @"ADB command failed";
        [self appendLog:
            [NSString stringWithFormat:@"ADB FAILED (%d): %@",
             task.terminationStatus, msg]];

        if (errorText) *errorText = msg;
        return NO;
    }

    return YES;
}

- (BOOL)runADBShell:(NSString *)command
            serial:(NSString *)serial
            output:(NSString **)output
             error:(NSString **)errorText {

    return [self runADB:@[
        @"-s", serial ?: @"",
        @"shell",
        command ?: @""
    ] output:output error:errorText];
}

- (NSString *)normalizedPath:(NSString *)path {
    NSString *p =
        [path stringByTrimmingCharactersInSet:
                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (!p.length) return @"/";

    if (![p hasPrefix:@"/"]) {
        p = [@"/" stringByAppendingString:p];
    }

    while (p.length > 1 && [p hasSuffix:@"/"]) {
        p = [p substringToIndex:p.length - 1];
    }

    return p;
}

- (NSString *)shellQuote:(NSString *)value {
    NSString *v = value ?: @"";
    v = [v stringByReplacingOccurrencesOfString:@"'"
                                     withString:@"'\\''"];
    return [NSString stringWithFormat:@"'%@'", v];
}

- (NSString *)safeName:(NSString *)name {
    NSString *n = [name precomposedStringWithCanonicalMapping];
    NSMutableString *result = [NSMutableString string];

    for (NSUInteger i = 0; i < n.length; i++) {
        unichar c = [n characterAtIndex:i];

        BOOL bad =
            c < 32 || c == 127 ||
            c == '"' || c == '*' || c == '/' ||
            c == ':' || c == '<' || c == '>' ||
            c == '?' || c == '\\' || c == '|';

        [result appendString:
            bad ? @"_" : [NSString stringWithCharacters:&c length:1]];
    }

    while (result.length &&
           ([result hasSuffix:@" "] || [result hasSuffix:@"."])) {
        [result deleteCharactersInRange:
            NSMakeRange(result.length - 1, 1)];
    }

    if (!result.length ||
        [result isEqualToString:@"."] ||
        [result isEqualToString:@".."]) {
        return @"file";
    }

    NSData *data = [result dataUsingEncoding:NSUTF8StringEncoding];

    if (data.length > 255) {
        NSString *suffix = @"...";
        NSUInteger maxBytes =
            255 - [suffix lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

        NSMutableString *left = [NSMutableString string];
        NSUInteger leftBytes = 0;

        for (NSUInteger i = 0; i < result.length; i++) {
            NSString *ch = [result substringWithRange:NSMakeRange(i, 1)];
            NSUInteger bytes =
                [ch lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

            if (leftBytes + bytes > maxBytes / 2) break;

            [left appendString:ch];
            leftBytes += bytes;
        }

        NSMutableString *right = [NSMutableString string];
        NSUInteger rightBytes = 0;

        for (NSInteger i = (NSInteger)result.length - 1; i >= 0; i--) {
            NSString *ch =
                [result substringWithRange:NSMakeRange((NSUInteger)i, 1)];

            NSUInteger bytes =
                [ch lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

            if (leftBytes + rightBytes + bytes > maxBytes) break;

            [right insertString:ch atIndex:0];
            rightBytes += bytes;
        }

        result =
            [NSMutableString stringWithFormat:@"%@%@%@",
                                               left, suffix, right];
    }

    return result;
}

- (NSString *)deviceDisplayNameForSerial:(NSString *)serial {
    NSString *out = nil;
    NSString *err = nil;

    if ([self runADBShell:@"getprop ro.product.marketname"
                   serial:serial
                   output:&out
                    error:&err]) {

        NSString *name =
            [out stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        if (name.length) {
            return [name stringByReplacingOccurrencesOfString:@"_"
                                                    withString:@" "];
        }
    }

    out = nil;
    err = nil;

    if ([self runADBShell:@"getprop ro.product.model"
                   serial:serial
                   output:&out
                    error:&err]) {

        NSString *name =
            [out stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        if (name.length) {
            return [name stringByReplacingOccurrencesOfString:@"_"
                                                    withString:@" "];
        }
    }

    return serial;
}

- (void)deviceTimerTick:(NSTimer *)timer {
    (void)timer;

    if (!self.deviceRefreshRunning && !self.transferring) {
        [self refreshDevice];
    }
}

- (void)refreshDevice {
    if (self.deviceRefreshRunning) return;

    self.deviceRefreshRunning = YES;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *out = nil;
        NSString *err = nil;

        BOOL ok = [self runADB:@[@"devices", @"-l"]
                        output:&out
                         error:&err];

        NSString *found = nil;

        if (ok) {
            for (NSString *rawLine in [out componentsSeparatedByString:@"\n"]) {
                NSString *line =
                    [rawLine stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];

                if (!line.length || [line hasPrefix:@"List of devices"]) {
                    continue;
                }

                NSArray<NSString *> *parts =
                    [line componentsSeparatedByCharactersInSet:
                              [NSCharacterSet whitespaceCharacterSet]];

                NSString *serial = nil;
                NSString *state = nil;

                for (NSString *part in parts) {
                    if (!part.length) continue;

                    if (!serial) {
                        serial = part;
                    } else {
                        state = part;
                        break;
                    }
                }

                if (serial.length && [state isEqualToString:@"device"]) {
                    found = serial;
                    break;
                }
            }
        }

        NSString *displayName =
            found ? [self deviceDisplayNameForSerial:found] : nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            self.deviceRefreshRunning = NO;

            NSString *old = self.serial;
            self.serial = found;

            if (found.length) {
                self.deviceLabel.stringValue =
                    [NSString stringWithFormat:@"●  Connected  ·  %@",
                                               displayName ?: found];

                self.deviceLabel.textColor = NSColor.systemGreenColor;

                if (!old.length) {
                    self.statusLabel.stringValue =
                        @"Ready · drop files or folders";
                }
            } else {
                self.deviceLabel.stringValue = @"●  No Android device";
                self.deviceLabel.textColor = NSColor.systemOrangeColor;

                if (!self.transferring) {
                    self.statusLabel.stringValue =
                        ok ? @"Connect Android and enable USB debugging"
                           : @"ADB is not available";
                }

                if (self.browser) {
                    [self.browser close];
                }
            }
        });
    });
}

- (void)browse:(id)sender {
    (void)sender;

    if (!self.serial.length) {
        self.statusLabel.stringValue =
            @"Connect Android and enable USB debugging";
        return;
    }

    if (self.browser) {
        [self.browser close];
        self.browser = nil;
    }

    BrowserController *browser = [BrowserController new];
    browser.owner = self;

    // IMPORTANT:
    // The main address field remains /sdcard/Downloads.
    // The Browse window ALWAYS starts at /sdcard.
    browser.current = @"/sdcard";

    self.browser = browser;
    [browser show];
}

- (void)sendURLs:(NSArray<NSURL *> *)urls {
    if (self.transferring) return;

    if (!self.serial.length || !urls.count) {
        self.statusLabel.stringValue = @"No Android device connected";
        return;
    }

    self.transferring = YES;

    NSString *serial = [self.serial copy];
    NSString *dest =
        [self normalizedPath:self.remotePath.length
            ? self.remotePath
            : kDefaultRemote];

    self.statusLabel.stringValue = @"Preparing transfer…";
    self.progress.doubleValue = 0.0;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];

        NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];

        for (NSURL *url in urls) {
            BOOL isDir = NO;

            if (![fm fileExistsAtPath:url.path isDirectory:&isDir]) {
                continue;
            }

            NSString *top = [self safeName:url.lastPathComponent];
            NSString *rootRemote =
                [dest stringByAppendingFormat:@"/%@", top];

            [entries addObject:@{
                @"local": url.path,
                @"remote": rootRemote,
                @"dir": @(isDir)
            }];

            if (!isDir) continue;

            NSDirectoryEnumerator *enumerator =
                [fm enumeratorAtURL:url
         includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                            options:0
                       errorHandler:^BOOL(NSURL *u, NSError *e) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.statusLabel.stringValue =
                        [NSString stringWithFormat:@"Read error: %@",
                                                   e.localizedDescription ?: @"unknown"];
                });
                (void)u;
                return YES;
            }];

            for (NSURL *child in enumerator) {
                NSNumber *dirFlag = @NO;

                [child getResourceValue:&dirFlag
                                 forKey:NSURLIsDirectoryKey
                                  error:nil];

                NSString *relative =
                    [child.path substringFromIndex:url.path.length];

                while ([relative hasPrefix:@"/"]) {
                    relative = [relative substringFromIndex:1];
                }

                NSString *remote = rootRemote;

                for (NSString *part in [relative pathComponents]) {
                    remote =
                        [remote stringByAppendingFormat:@"/%@",
                                                       [self safeName:part]];
                }

                [entries addObject:@{
                    @"local": child.path,
                    @"remote": remote,
                    @"dir": @(dirFlag.boolValue)
                }];
            }
        }

        NSString *errText = nil;

        NSString *destMkdir =
            [NSString stringWithFormat:@"mkdir -p %@",
                                       [self shellQuote:dest]];

        if (![self runADBShell:destMkdir
                        serial:serial
                        output:NULL
                         error:&errText]) {

            [self finishTransferWithError:
                [NSString stringWithFormat:@"Cannot create destination:\n%@\nADB: %@",
                                           dest,
                                           errText ?: @"unknown error"]];
            return;
        }

        for (NSDictionary *entry in entries) {
            if (![entry[@"dir"] boolValue]) continue;

            NSString *remote = entry[@"remote"];

            NSString *mkdirCommand =
                [NSString stringWithFormat:@"mkdir -p %@",
                                           [self shellQuote:remote]];

            NSString *detail = nil;

            [self runADBShell:mkdirCommand
                       serial:serial
                       output:NULL
                        error:&detail];
        }

        NSMutableArray<NSDictionary *> *files = [NSMutableArray array];

        for (NSDictionary *entry in entries) {
            if (![entry[@"dir"] boolValue]) {
                [files addObject:entry];
            }
        }

        NSUInteger total = files.count;
        NSUInteger done = 0;
        NSUInteger failed = 0;

        NSMutableArray<NSString *> *failures = [NSMutableArray array];

        for (NSDictionary *entry in files) {
            NSString *local = entry[@"local"];
            NSString *remote = entry[@"remote"];
            NSString *parent = [remote stringByDeletingLastPathComponent];

            NSString *mkdirError = nil;

            NSString *parentMkdir =
                [NSString stringWithFormat:@"mkdir -p %@",
                                           [self shellQuote:parent]];

            if (![self runADBShell:parentMkdir
                            serial:serial
                            output:NULL
                             error:&mkdirError]) {

                failed++;

                [failures addObject:
                    [NSString stringWithFormat:
                        @"%@\n→ parent folder could not be created\nADB: %@",
                        local,
                        mkdirError ?: @"unknown error"]];

                continue;
            }

            NSString *pushOutput = nil;
            NSString *pushError = nil;

            BOOL pushed =
                [self runADB:@[
                    @"-s",
                    serial,
                    @"push",
                    local,
                    remote
                ] output:&pushOutput error:&pushError];

            if (!pushed) {
                failed++;

                NSString *detail =
                    pushError.length
                        ? pushError
                        : (pushOutput.length
                           ? pushOutput
                           : @"ADB returned an error without details");

                [failures addObject:
                    [NSString stringWithFormat:@"%@\n→ %@\nADB: %@",
                                               local,
                                               remote,
                                               detail]];
            } else {
                done++;
            }

            NSUInteger current = done + failed;

            dispatch_async(dispatch_get_main_queue(), ^{
                self.progress.doubleValue =
                    total ? (double)current / (double)total : 1.0;

                self.statusLabel.stringValue =
                    [NSString stringWithFormat:
                        @"Sending · %lu of %lu · %lu failed",
                        (unsigned long)current,
                        (unsigned long)total,
                        (unsigned long)failed];
            });
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.transferring = NO;
            self.progress.doubleValue = 1.0;

            if (failed == 0) {
                self.statusLabel.stringValue =
                    [NSString stringWithFormat:
                        @"Done · %lu file(s)",
                        (unsigned long)done];
                return;
            }

            self.statusLabel.stringValue =
                [NSString stringWithFormat:
                    @"Finished · %lu sent · %lu failed",
                    (unsigned long)done,
                    (unsigned long)failed];

            NSAlert *alert = [NSAlert new];

            alert.messageText =
                [NSString stringWithFormat:
                    @"Transfer finished with %lu error(s)",
                    (unsigned long)failed];

            alert.informativeText =
                [failures componentsJoinedByString:@"\n\n"];

            [alert addButtonWithTitle:@"OK"];
            [alert runModal];
        });
    });
}

- (void)finishTransferWithError:(NSString *)message {
    [self appendLog:
        [NSString stringWithFormat:@"TRANSFER FAILED: %@",
                                   message ?: @"Unknown error"]];

    dispatch_async(dispatch_get_main_queue(), ^{
        self.transferring = NO;
        self.statusLabel.stringValue = @"Transfer failed · see details";

        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Transfer failed";
        alert.informativeText = message ?: @"Unknown error";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    });
}

@end

@implementation BrowserController

- (void)show {
    NSRect frame = NSMakeRect(0, 0, 820, 600);

    self.window =
        [[NSWindow alloc] initWithContentRect:frame
                                    styleMask:(NSWindowStyleMaskTitled |
                                               NSWindowStyleMaskClosable |
                                               NSWindowStyleMaskResizable)
                                      backing:NSBackingStoreBuffered
                                        defer:NO];

    self.window.title = @"Browse Android Storage";
    self.window.minSize = NSMakeSize(680, 480);
    self.window.delegate = self;

    NSView *content = self.window.contentView;

    NSButton *up =
        [NSButton buttonWithTitle:@"Up"
                           target:self
                           action:@selector(goUp:)];
    up.frame = NSMakeRect(18, 558, 60, 30);
    [content addSubview:up];

    self.pathField =
        [NSTextField textFieldWithString:self.current ?: @"/sdcard"];
    self.pathField.frame = NSMakeRect(88, 558, 714, 30);
    self.pathField.font =
        [NSFont monospacedSystemFontOfSize:12
                                    weight:NSFontWeightRegular];
    self.pathField.target = self;
    self.pathField.action = @selector(pathEntered:);
    [content addSubview:self.pathField];

    NSScrollView *scroll =
        [[NSScrollView alloc] initWithFrame:NSMakeRect(18, 82, 784, 462)];

    scroll.hasVerticalScroller = YES;
    scroll.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable;

    self.table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.doubleAction = @selector(doubleClick:);
    self.table.target = self;
    self.table.usesAlternatingRowBackgroundColors = YES;

    NSTableColumn *column =
        [[NSTableColumn alloc] initWithIdentifier:@"name"];

    column.title = @"Name";
    column.width = 760;

    [self.table addTableColumn:column];

    scroll.documentView = self.table;
    [content addSubview:scroll];

    self.footer = [NSTextField labelWithString:@"Loading…"];
    self.footer.frame = NSMakeRect(22, 48, 520, 22);
    self.footer.font = [NSFont systemFontOfSize:12];
    self.footer.textColor = NSColor.secondaryLabelColor;
    [content addSubview:self.footer];

    NSButton *cancel =
        [NSButton buttonWithTitle:@"Cancel"
                           target:self
                           action:@selector(cancel:)];
    cancel.frame = NSMakeRect(570, 18, 100, 30);
    [content addSubview:cancel];

    NSButton *send =
        [NSButton buttonWithTitle:@"Send Here"
                           target:self
                           action:@selector(selectHere:)];
    send.frame = NSMakeRect(680, 18, 122, 30);
    send.keyEquivalent = @"\r";
    [content addSubview:send];

    [self.window center];

    [self.owner.window beginSheet:self.window completionHandler:nil];

    // Immediately load /sdcard. No separate Refresh button.
    [self load:self.current ?: @"/sdcard"];
}

- (void)load:(NSString *)path {
    if (self.loading || !self.owner.serial.length) return;

    self.loading = YES;
    self.current = [self.owner normalizedPath:path];
    self.pathField.stringValue = self.current;
    self.footer.stringValue = @"Loading…";

    NSString *serial = [self.owner.serial copy];
    NSString *remote = [self.current copy];

    __weak BrowserController *weakSelf = self;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *out = nil;
        NSString *err = nil;

        NSString *command =
            [NSString stringWithFormat:
                @"ls -1p %@",
                [self.owner shellQuote:remote]];

        BOOL ok =
            [self.owner runADBShell:command
                             serial:serial
                             output:&out
                              error:&err];

        NSMutableArray<NSDictionary *> *items = [NSMutableArray array];

        if (ok) {
            for (NSString *raw in [out componentsSeparatedByString:@"\n"]) {
                NSString *line =
                    [raw stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];

                if (!line.length || [line isEqualToString:@"."] ||
                    [line isEqualToString:@".."] ||
                    [line hasPrefix:@"ls:"]) {
                    continue;
                }

                BOOL isDir = [line hasSuffix:@"/"];

                NSString *name =
                    isDir
                        ? [line substringToIndex:line.length - 1]
                        : line;

                if (name.length) {
                    [items addObject:@{
                        @"name": name,
                        @"dir": @(isDir)
                    }];
                }
            }
        }

        [items sortUsingComparator:
            ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {

            BOOL da = [a[@"dir"] boolValue];
            BOOL db = [b[@"dir"] boolValue];

            if (da != db) {
                return da ? NSOrderedAscending : NSOrderedDescending;
            }

            NSString *an = a[@"name"];
            NSString *bn = b[@"name"];

            return [an localizedCaseInsensitiveCompare:bn];
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            BrowserController *strongSelf = weakSelf;

            if (!strongSelf) return;

            strongSelf.loading = NO;

            if (![strongSelf.current isEqualToString:remote]) {
                return;
            }

            if (ok) {
                strongSelf.items = items;
                [strongSelf.table reloadData];

                NSUInteger folders = 0;
                NSUInteger files = 0;

                for (NSDictionary *item in items) {
                    if ([item[@"dir"] boolValue]) {
                        folders++;
                    } else {
                        files++;
                    }
                }

                strongSelf.footer.stringValue =
                    [NSString stringWithFormat:
                        @"%lu folders · %lu files · %lu items",
                        (unsigned long)folders,
                        (unsigned long)files,
                        (unsigned long)items.count];
            } else {
                strongSelf.items = @[];
                [strongSelf.table reloadData];

                strongSelf.footer.stringValue =
                    err.length
                        ? [NSString stringWithFormat:
                            @"Unable to read folder · %@", err]
                        : @"Unable to read folder";
            }
        });
    });
}

- (void)pathEntered:(id)sender {
    (void)sender;
    [self load:self.pathField.stringValue];
}

- (void)goUp:(id)sender {
    (void)sender;

    // /sdcard is the browser root.
    if ([self.current isEqualToString:@"/sdcard"] ||
        [self.current isEqualToString:@"/"]) {
        return;
    }

    NSString *parent = [self.current stringByDeletingLastPathComponent];

    if (!parent.length || [parent isEqualToString:@"/"]) {
        parent = @"/sdcard";
    }

    [self load:parent];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)self.items.count;
}

- (NSView *)tableView:(NSTableView *)tableView
    viewForTableColumn:(NSTableColumn *)column
                   row:(NSInteger)row {

    (void)tableView;

    NSTableCellView *cell =
        [self.table makeViewWithIdentifier:@"cell" owner:self];

    if (!cell) {
        cell =
            [[NSTableCellView alloc]
                initWithFrame:NSMakeRect(0, 0, column.width, 28)];

        cell.identifier = @"cell";

        NSTextField *field =
            [NSTextField labelWithString:@""];

        field.frame =
            NSMakeRect(8, 2, column.width - 16, 24);

        field.autoresizingMask = NSViewWidthSizable;
        cell.textField = field;

        [cell addSubview:field];
    }

    NSDictionary *item =
        self.items[(NSUInteger)row];

    NSString *prefix =
        [item[@"dir"] boolValue] ? @"📁" : @"•";

    cell.textField.stringValue =
        [NSString stringWithFormat:@"%@  %@",
                                   prefix,
                                   item[@"name"]];

    return cell;
}

- (void)doubleClick:(id)sender {
    (void)sender;

    NSInteger row = self.table.clickedRow;

    if (row < 0 || (NSUInteger)row >= self.items.count) {
        return;
    }

    NSDictionary *item =
        self.items[(NSUInteger)row];

    if (![item[@"dir"] boolValue]) {
        return;
    }

    NSString *name = item[@"name"];

    NSString *next =
        [self.current isEqualToString:@"/"]
            ? [@"/" stringByAppendingString:name]
            : [self.current stringByAppendingFormat:@"/%@", name];

    [self load:next];
}

- (void)cancel:(id)sender {
    (void)sender;
    [self close];
}

- (void)selectHere:(id)sender {
    (void)sender;

    // This changes the main Send to address field.
    self.owner.remotePath = self.current;
    self.owner.pathField.stringValue = self.current;

    [self close];
}

- (void)close {
    if (!self.window) return;

    NSWindow *w = self.window;
    self.window = nil;

    if (w.sheetParent) {
        [w.sheetParent endSheet:w];
    } else {
        [w close];
    }

    if (self.owner.browser == self) {
        self.owner.browser = nil;
    }
}

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;

    NSWindow *w = self.window;

    self.window = nil;

    if (w.sheetParent) {
        [w.sheetParent endSheet:w];
    }

    if (self.owner.browser == self) {
        self.owner.browser = nil;
    }
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];

        AppController *delegate = [AppController new];
        app.delegate = delegate;

        [app run];
    }

    return 0;
}
