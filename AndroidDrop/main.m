#import <Cocoa/Cocoa.h>
#import <spawn.h>
#import <signal.h>
#import <sys/wait.h>
#import <fcntl.h>
#import <unistd.h>

extern char **environ;

// Android's shared download folder is "Download" (singular).
static NSString * const kDefaultRemote = @"/sdcard/Download";
static NSString * const kBrowserRoot = @"/sdcard";
static NSString * const kDestinationKey = @"Destination";
static NSString * const kRecentDestinationsKey = @"RecentDestinations";

static const NSUInteger kMaxRecentDestinations = 10;
static const NSUInteger kMaxShellCommandBytes = 3000;
static const NSUInteger kPushAttempts = 3;
static const unsigned long long kLargeFileBytes = 24ull * 1024 * 1024;
static const unsigned long long kMaxLogBytes = 4ull * 1024 * 1024;

@class AppController;
@class BrowserController;

#pragma mark - Process runner

// Runs a process with stdin = /dev/null and stdout + stderr captured into one buffer.
//
// This replaces NSTask + NSPipe. Launching hundreds of short-lived adb processes in a
// row through NSTask intermittently failed with "Bad file descriptor" (EBADF): pipe
// handles released later could close a descriptor number that had already been
// reused by the next pipe. Here every descriptor is owned and closed exactly once,
// and POSIX_SPAWN_CLOEXEC_DEFAULT makes sure the child inherits only fds 0-2, so a
// concurrently spawned process (or a forked adb server) never holds our pipe open.
//
// Returns 0 on success or an errno value if the process could not be started.
static int ADBSpawnCapture(NSString *executable,
                           NSArray<NSString *> *arguments,
                           void (^started)(pid_t pid),
                           NSData **output,
                           int *exitStatus) {
    int fds[2];
    if (pipe(fds) != 0) return errno;
    fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    fcntl(fds[1], F_SETFD, FD_CLOEXEC);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    sigset_t mask;
    sigemptyset(&mask);
    sigset_t defaults;
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGPIPE);
    posix_spawnattr_setsigmask(&attr, &mask);
    posix_spawnattr_setsigdefault(&attr, &defaults);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT |
                                    POSIX_SPAWN_SETSIGMASK |
                                    POSIX_SPAWN_SETSIGDEF);

    NSUInteger argc = arguments.count + 1;
    char **argv = calloc(argc + 1, sizeof(char *));
    argv[0] = strdup(executable.fileSystemRepresentation);
    for (NSUInteger i = 0; i < arguments.count; i++) {
        argv[i + 1] = strdup(arguments[i].UTF8String ?: "");
    }

    pid_t pid = 0;
    int rc = [executable hasPrefix:@"/"]
        ? posix_spawn(&pid, argv[0], &actions, &attr, argv, environ)
        : posix_spawnp(&pid, argv[0], &actions, &attr, argv, environ);

    for (NSUInteger i = 0; i < argc; i++) free(argv[i]);
    free(argv);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);

    close(fds[1]);

    if (rc != 0) {
        close(fds[0]);
        return rc;
    }

    if (started) started(pid);

    NSMutableData *data = [NSMutableData data];
    char buffer[65536];
    for (;;) {
        ssize_t n = read(fds[0], buffer, sizeof(buffer));
        if (n > 0) {
            [data appendBytes:buffer length:(NSUInteger)n];
        } else if (n == 0) {
            break;
        } else if (errno != EINTR) {
            break;
        }
    }
    close(fds[0]);

    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}

    if (exitStatus) {
        *exitStatus = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    }
    if (output) *output = data;
    return 0;
}

static NSString *ADBStringFromData(NSData *data) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return [(text ?: @"") stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *ADBFormatBytes(unsigned long long bytes) {
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes
                                          countStyle:NSByteCountFormatterCountStyleFile];
}

static NSString *ADBFormatDuration(NSTimeInterval seconds) {
    if (seconds < 1) return @"<1 s";
    NSUInteger s = (NSUInteger)llround(seconds);
    if (s < 60) return [NSString stringWithFormat:@"%lu s", (unsigned long)s];
    if (s < 3600) {
        return [NSString stringWithFormat:@"%lu:%02lu",
                (unsigned long)(s / 60), (unsigned long)(s % 60)];
    }
    return [NSString stringWithFormat:@"%lu:%02lu:%02lu",
            (unsigned long)(s / 3600), (unsigned long)((s / 60) % 60), (unsigned long)(s % 60)];
}

static NSImage *ADBSymbol(NSString *name, CGFloat size, NSFontWeight weight) {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    NSImageSymbolConfiguration *config =
        [NSImageSymbolConfiguration configurationWithPointSize:size weight:weight];
    return [image imageWithSymbolConfiguration:config];
}

#pragma mark - Small helpers

// Shared between a push and the thread polling its progress.
@interface ADBFlag : NSObject
@property(atomic, assign) BOOL value;
@end

@implementation ADBFlag
@end

@interface DropView : NSView
@property(nonatomic, copy) void (^handler)(NSArray<NSURL *> *urls);
@property(nonatomic, copy) void (^clickHandler)(void);
@property(nonatomic, assign) BOOL highlighted;
@property(nonatomic, assign) BOOL active;
@property(nonatomic, strong) NSImageView *iconView;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *subtitleLabel;
- (void)setTitle:(NSString *)title subtitle:(NSString *)subtitle symbol:(NSString *)symbol;
@end

@interface BrowserController : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, weak) AppController *owner;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTableView *table;
@property(nonatomic, strong) NSTextField *pathField;
@property(nonatomic, strong) NSTextField *footer;
@property(nonatomic, strong) NSButton *upButton;
@property(nonatomic, strong) NSProgressIndicator *spinner;
@property(nonatomic, strong) NSArray<NSDictionary *> *items;
@property(nonatomic, copy) NSString *current;
@property(nonatomic, assign) NSUInteger generation;
- (void)show;
- (void)close;
@end

// A label that can act as a link (the transfer summary opens the list of files).
@interface LinkLabel : NSTextField
@property(nonatomic, copy) void (^clickHandler)(void);
@end

@interface ResultsController : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTableView *table;
@property(nonatomic, strong) NSSegmentedControl *filter;
@property(nonatomic, strong) NSTextField *footer;
@property(nonatomic, strong) NSArray<NSDictionary *> *results;
@property(nonatomic, strong) NSArray<NSDictionary *> *visible;
- (void)showResults:(NSArray<NSDictionary *> *)results title:(NSString *)title;
@end

@interface AppController : NSObject <NSApplicationDelegate, NSComboBoxDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) DropView *drop;
@property(nonatomic, strong) NSView *deviceDot;
@property(nonatomic, strong) NSTextField *deviceLabel;
@property(nonatomic, strong) NSTextField *deviceInfoLabel;
@property(nonatomic, strong) NSComboBox *pathField;
@property(nonatomic, strong) NSButton *browseButton;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) LinkLabel *detailLabel;
@property(nonatomic, strong) NSArray<NSDictionary *> *lastResults;
@property(nonatomic, copy) NSString *lastResultsTitle;
@property(nonatomic, strong) ResultsController *resultsController;
@property(nonatomic, strong) NSProgressIndicator *progress;
@property(nonatomic, strong) NSButton *cancelButton;
@property(nonatomic, copy) NSString *serial;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *deviceInfo;
@property(nonatomic, strong) NSTimer *deviceTimer;
@property(nonatomic, assign) BOOL deviceRefreshRunning;
@property(nonatomic, strong) BrowserController *browser;
@property(nonatomic, assign) BOOL transferring;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *pendingDrops;
@property(nonatomic, strong) NSArray<NSURL *> *launchURLs;
@property(nonatomic, strong) id activity;
@property(nonatomic, copy) NSString *cachedADBPath;
@property(nonatomic, strong) dispatch_queue_t logQueue;

// Touched from the transfer thread and from the main thread (Cancel / Quit).
@property(atomic, assign) BOOL cancelRequested;
@property(atomic, assign) pid_t activePid;
@property(atomic, copy) NSString *activeRemote;

- (NSString *)normalizedPath:(NSString *)path;
- (BOOL)runADB:(NSArray<NSString *> *)arguments output:(NSString **)output error:(NSString **)errorText;
- (BOOL)runADBShell:(NSString *)command serial:(NSString *)serial output:(NSString **)output error:(NSString **)errorText;
- (NSString *)shellQuote:(NSString *)value;
- (void)setDestination:(NSString *)path;
- (void)appendLog:(NSString *)message;
@end

#pragma mark - DropView

@implementation DropView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
        _active = YES;

        _iconView = [NSImageView imageViewWithImage:ADBSymbol(@"arrow.down.doc", 44, NSFontWeightLight)];
        _iconView.contentTintColor = NSColor.controlAccentColor;
        [_iconView unregisterDraggedTypes];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;

        _titleLabel = [NSTextField labelWithString:@""];
        _titleLabel.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
        _titleLabel.alignment = NSTextAlignmentCenter;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _subtitleLabel = [NSTextField labelWithString:@""];
        _subtitleLabel.font = [NSFont systemFontOfSize:13];
        _subtitleLabel.textColor = NSColor.secondaryLabelColor;
        _subtitleLabel.alignment = NSTextAlignmentCenter;
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        NSStackView *stack = [NSStackView stackViewWithViews:@[_iconView, _titleLabel, _subtitleLabel]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeCenterX;
        stack.spacing = 6;
        [stack setCustomSpacing:14 afterView:_iconView];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:stack];

        [NSLayoutConstraint activateConstraints:@[
            [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:16],
            [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-16],
        ]];

        [self setTitle:@"Drop files or folders" subtitle:@"or click to choose" symbol:@"arrow.down.doc"];
    }
    return self;
}

- (void)setTitle:(NSString *)title subtitle:(NSString *)subtitle symbol:(NSString *)symbol {
    self.titleLabel.stringValue = title ?: @"";
    self.subtitleLabel.stringValue = subtitle ?: @"";
    if (symbol) self.iconView.image = ADBSymbol(symbol, 44, NSFontWeightLight);
}

- (void)setActive:(BOOL)active {
    _active = active;
    self.iconView.contentTintColor = active ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor;
    self.titleLabel.textColor = active ? NSColor.labelColor : NSColor.secondaryLabelColor;
    [self setNeedsDisplay:YES];
}

- (void)setHighlighted:(BOOL)highlighted {
    _highlighted = highlighted;
    [self setNeedsDisplay:YES];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    (void)sender;
    if (!self.active) return NSDragOperationNone;
    self.highlighted = YES;
    return NSDragOperationCopy;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    (void)sender;
    self.highlighted = NO;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    self.highlighted = NO;

    NSArray<NSURL *> *urls =
        [sender.draggingPasteboard readObjectsForClasses:@[[NSURL class]]
                                                 options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];

    if (urls.count > 0 && self.handler) {
        self.handler(urls);
    }
    return urls.count > 0;
}

- (NSView *)hitTest:(NSPoint)point {
    // Clicks on the icon and labels belong to the drop zone.
    NSView *hit = [super hitTest:point];
    return hit ? self : nil;
}

- (void)mouseDown:(NSEvent *)event {
    (void)event;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(p, self.bounds) && self.clickHandler) {
        self.clickHandler();
    }
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;

    NSRect r = NSInsetRect(self.bounds, 1.5, 1.5);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:r xRadius:16 yRadius:16];

    NSColor *accent = self.active ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor;

    [[accent colorWithAlphaComponent:self.highlighted ? 0.16 : 0.05] setFill];
    [path fill];

    [[accent colorWithAlphaComponent:self.highlighted ? 0.9 : 0.45] setStroke];
    path.lineWidth = self.highlighted ? 2.5 : 1.5;
    if (!self.highlighted) {
        CGFloat dash[] = {7, 5};
        [path setLineDash:dash count:2 phase:0];
    }
    [path stroke];
}

@end

#pragma mark - AppController

@implementation AppController

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    self.logQueue = dispatch_queue_create("androiddrop.log", DISPATCH_QUEUE_SERIAL);
    self.deviceInfo = [NSMutableDictionary dictionary];
    self.pendingDrops = [NSMutableArray array];

    [self buildMenu];
    [self buildUI];
    [self refreshDevice];

    if (self.launchURLs) {
        [self sendURLs:self.launchURLs];
        self.launchURLs = nil;
    }

    self.deviceTimer =
        [NSTimer scheduledTimerWithTimeInterval:1.5
                                         target:self
                                       selector:@selector(deviceTimerTick:)
                                       userInfo:nil
                                        repeats:YES];
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    (void)application;
    // Files dropped on the Dock icon. At launch this arrives before the window exists.
    if (!self.window) {
        self.launchURLs = [(self.launchURLs ?: @[]) arrayByAddingObjectsFromArray:urls];
        return;
    }
    [self sendURLs:urls];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    if (!self.transferring) return NSTerminateNow;

    NSAlert *alert = [NSAlert new];
    alert.messageText = @"A transfer is in progress";
    alert.informativeText = @"Quitting stops it. Files already sent stay on the device.";
    [alert addButtonWithTitle:@"Keep Sending"];
    [alert addButtonWithTitle:@"Stop and Quit"];

    if ([alert runModal] != NSAlertSecondButtonReturn) {
        return NSTerminateCancel;
    }

    [self.pendingDrops removeAllObjects];
    self.cancelRequested = YES;
    pid_t pid = self.activePid;
    if (pid > 0) kill(pid, SIGTERM);

    // Don't leave a truncated file behind.
    NSString *remote = self.activeRemote;
    if (remote.length && self.serial.length) {
        [self runADBShell:[NSString stringWithFormat:@"rm -f %@", [self shellQuote:remote]]
                   serial:self.serial
                   output:NULL
                    error:NULL];
    }
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
    [self commitDestination];
}

#pragma mark Menu

- (NSMenuItem *)itemWithTitle:(NSString *)title action:(SEL)action key:(NSString *)key target:(id)target {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key ?: @""];
    item.target = target;
    return item;
}

- (void)buildMenu {
    NSMenu *main = [[NSMenu alloc] initWithTitle:@"Main Menu"];

    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"Android Drop" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Android Drop"];
    [appMenu addItem:[self itemWithTitle:@"About Android Drop" action:@selector(orderFrontStandardAboutPanel:) key:nil target:nil]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[self itemWithTitle:@"Hide Android Drop" action:@selector(hide:) key:@"h" target:nil]];
    NSMenuItem *hideOthers = [self itemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) key:@"h" target:nil];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [appMenu addItem:hideOthers];
    [appMenu addItem:[self itemWithTitle:@"Show All" action:@selector(unhideAllApplications:) key:nil target:nil]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[self itemWithTitle:@"Quit Android Drop" action:@selector(terminate:) key:@"q" target:nil]];
    appItem.submenu = appMenu;
    [main addItem:appItem];

    NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
    NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
    [file addItem:[self itemWithTitle:@"Send Files…" action:@selector(chooseFiles:) key:@"o" target:self]];
    [file addItem:[self itemWithTitle:@"Browse Device…" action:@selector(browse:) key:@"b" target:self]];
    [file addItem:[NSMenuItem separatorItem]];
    [file addItem:[self itemWithTitle:@"Show Last Transfer" action:@selector(showResults:) key:@"r" target:self]];
    [file addItem:[self itemWithTitle:@"Show Log" action:@selector(showLog:) key:@"l" target:self]];
    [file addItem:[NSMenuItem separatorItem]];
    [file addItem:[self itemWithTitle:@"Close Window" action:@selector(performClose:) key:@"w" target:nil]];
    fileItem.submenu = file;
    [main addItem:fileItem];

    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit addItem:[self itemWithTitle:@"Undo" action:@selector(undo:) key:@"z" target:nil]];
    NSMenuItem *redo = [self itemWithTitle:@"Redo" action:@selector(redo:) key:@"z" target:nil];
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [edit addItem:redo];
    [edit addItem:[NSMenuItem separatorItem]];
    [edit addItem:[self itemWithTitle:@"Cut" action:@selector(cut:) key:@"x" target:nil]];
    [edit addItem:[self itemWithTitle:@"Copy" action:@selector(copy:) key:@"c" target:nil]];
    [edit addItem:[self itemWithTitle:@"Paste" action:@selector(paste:) key:@"v" target:nil]];
    [edit addItem:[self itemWithTitle:@"Select All" action:@selector(selectAll:) key:@"a" target:nil]];
    editItem.submenu = edit;
    [main addItem:editItem];

    NSMenuItem *windowItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItem:[self itemWithTitle:@"Minimize" action:@selector(performMiniaturize:) key:@"m" target:nil]];
    [windowMenu addItem:[self itemWithTitle:@"Zoom" action:@selector(performZoom:) key:nil target:nil]];
    windowItem.submenu = windowMenu;
    [main addItem:windowItem];
    NSApp.windowsMenu = windowMenu;

    [NSApp setMainMenu:main];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(chooseFiles:)) return self.serial.length > 0;
    if (item.action == @selector(browse:)) return self.serial.length > 0 && !self.browser;
    if (item.action == @selector(showResults:)) return self.lastResults.count > 0;
    return YES;
}

#pragma mark UI

- (NSTextField *)label:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight color:(NSColor *)color {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

- (void)buildUI {
    self.window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 520)
                                    styleMask:(NSWindowStyleMaskTitled |
                                               NSWindowStyleMaskClosable |
                                               NSWindowStyleMaskMiniaturizable |
                                               NSWindowStyleMaskResizable)
                                      backing:NSBackingStoreBuffered
                                        defer:NO];

    self.window.title = @"Android Drop";
    self.window.minSize = NSMakeSize(520, 440);
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    self.window.frameAutosaveName = @"MainWindow";

    NSView *content = self.window.contentView;
    const CGFloat margin = 24;

    // Device header.
    self.deviceDot = [NSView new];
    self.deviceDot.wantsLayer = YES;
    self.deviceDot.layer.cornerRadius = 5;
    self.deviceDot.layer.backgroundColor = NSColor.tertiaryLabelColor.CGColor;
    self.deviceDot.translatesAutoresizingMaskIntoConstraints = NO;

    NSImageView *phone = [NSImageView imageViewWithImage:ADBSymbol(@"iphone.gen2", 26, NSFontWeightRegular)];
    phone.contentTintColor = NSColor.secondaryLabelColor;
    phone.translatesAutoresizingMaskIntoConstraints = NO;

    self.deviceLabel = [self label:@"Looking for a device…" size:15 weight:NSFontWeightSemibold color:NSColor.labelColor];
    self.deviceInfoLabel = [self label:@" " size:12 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];

    // Destination row.
    NSTextField *sendLabel = [self label:@"Send to" size:13 weight:NSFontWeightMedium color:NSColor.secondaryLabelColor];
    [sendLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:kDestinationKey];
    // Older versions defaulted to the non-existent "/sdcard/Downloads".
    if (!saved.length || [saved isEqualToString:@"/sdcard/Downloads"]) saved = kDefaultRemote;

    self.pathField = [NSComboBox new];
    self.pathField.stringValue = [self normalizedPath:saved];
    self.pathField.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
    self.pathField.placeholderString = kDefaultRemote;
    self.pathField.completes = NO;
    self.pathField.numberOfVisibleItems = 10;
    self.pathField.delegate = self;
    self.pathField.target = self;
    self.pathField.action = @selector(pathFieldChanged:);
    self.pathField.translatesAutoresizingMaskIntoConstraints = NO;
    self.pathField.toolTip = @"Folder on the device. Missing folders are created. "
                             @"Relative paths like Music/Rock are placed under /sdcard.";
    [self reloadRecentDestinations];

    self.browseButton = [NSButton buttonWithTitle:@"Browse…" target:self action:@selector(browse:)];
    self.browseButton.bezelStyle = NSBezelStyleRounded;
    self.browseButton.translatesAutoresizingMaskIntoConstraints = NO;

    // Drop zone.
    self.drop = [[DropView alloc] initWithFrame:NSZeroRect];
    self.drop.translatesAutoresizingMaskIntoConstraints = NO;
    __weak AppController *weakSelf = self;
    self.drop.handler = ^(NSArray<NSURL *> *urls) {
        [weakSelf sendURLs:urls];
    };
    self.drop.clickHandler = ^{
        [weakSelf chooseFiles:nil];
    };

    // Progress area.
    self.progress = [NSProgressIndicator new];
    self.progress.indeterminate = NO;
    self.progress.minValue = 0.0;
    self.progress.maxValue = 1.0;
    self.progress.style = NSProgressIndicatorStyleBar;
    self.progress.controlSize = NSControlSizeSmall;
    self.progress.translatesAutoresizingMaskIntoConstraints = NO;
    self.progress.hidden = YES;

    self.statusLabel = [self label:@"" size:13 weight:NSFontWeightMedium color:NSColor.labelColor];
    self.detailLabel = [[LinkLabel alloc] initWithFrame:NSZeroRect];
    self.detailLabel.editable = NO;
    self.detailLabel.selectable = NO;
    self.detailLabel.bezeled = NO;
    self.detailLabel.drawsBackground = NO;
    self.detailLabel.textColor = NSColor.secondaryLabelColor;
    self.detailLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.detailLabel.alignment = NSTextAlignmentRight;
    [self.detailLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelTransfer:)];
    self.cancelButton.bezelStyle = NSBezelStyleRounded;
    self.cancelButton.controlSize = NSControlSizeSmall;
    self.cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.cancelButton.hidden = YES;

    for (NSView *v in @[self.deviceDot, phone, self.deviceLabel, self.deviceInfoLabel,
                        sendLabel, self.pathField, self.browseButton, self.drop,
                        self.progress, self.statusLabel, self.detailLabel, self.cancelButton]) {
        [content addSubview:v];
    }

    [NSLayoutConstraint activateConstraints:@[
        [phone.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:margin],
        [phone.topAnchor constraintEqualToAnchor:content.topAnchor constant:20],
        [phone.widthAnchor constraintEqualToConstant:26],

        [self.deviceLabel.leadingAnchor constraintEqualToAnchor:phone.trailingAnchor constant:12],
        [self.deviceLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:18],
        [self.deviceDot.leadingAnchor constraintEqualToAnchor:self.deviceLabel.trailingAnchor constant:8],
        [self.deviceDot.centerYAnchor constraintEqualToAnchor:self.deviceLabel.centerYAnchor],
        [self.deviceDot.widthAnchor constraintEqualToConstant:10],
        [self.deviceDot.heightAnchor constraintEqualToConstant:10],
        [self.deviceDot.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-margin],
        [self.deviceInfoLabel.leadingAnchor constraintEqualToAnchor:self.deviceLabel.leadingAnchor],
        [self.deviceInfoLabel.topAnchor constraintEqualToAnchor:self.deviceLabel.bottomAnchor constant:2],
        [self.deviceInfoLabel.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-margin],
        [phone.centerYAnchor constraintEqualToAnchor:self.deviceLabel.bottomAnchor constant:1],

        [sendLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:margin],
        [sendLabel.centerYAnchor constraintEqualToAnchor:self.pathField.centerYAnchor],
        [self.pathField.leadingAnchor constraintEqualToAnchor:sendLabel.trailingAnchor constant:10],
        [self.pathField.topAnchor constraintEqualToAnchor:self.deviceInfoLabel.bottomAnchor constant:20],
        [self.browseButton.leadingAnchor constraintEqualToAnchor:self.pathField.trailingAnchor constant:8],
        [self.browseButton.centerYAnchor constraintEqualToAnchor:self.pathField.centerYAnchor],
        [self.browseButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-margin],

        [self.drop.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:margin],
        [self.drop.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-margin],
        [self.drop.topAnchor constraintEqualToAnchor:self.pathField.bottomAnchor constant:18],

        [self.progress.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:margin],
        [self.progress.trailingAnchor constraintEqualToAnchor:self.cancelButton.leadingAnchor constant:-10],
        [self.progress.topAnchor constraintEqualToAnchor:self.drop.bottomAnchor constant:18],
        [self.cancelButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-margin],
        [self.cancelButton.centerYAnchor constraintEqualToAnchor:self.progress.centerYAnchor],

        [self.statusLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:margin],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.progress.bottomAnchor constant:8],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-18],
        [self.detailLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.statusLabel.trailingAnchor constant:12],
        [self.detailLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-margin],
        [self.detailLabel.firstBaselineAnchor constraintEqualToAnchor:self.statusLabel.firstBaselineAnchor],
    ]];

    [self updateDeviceUIWithState:@"searching" name:nil info:nil];

    if (![self.window setFrameUsingName:@"MainWindow"]) {
        [self.window center];
    }
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)setStatus:(NSString *)status detail:(NSString *)detail {
    self.statusLabel.stringValue = status ?: @"";
    self.detailLabel.stringValue = detail ?: @"";
    self.detailLabel.textColor = NSColor.secondaryLabelColor;
    self.detailLabel.clickHandler = nil;
    self.detailLabel.toolTip = nil;
    [self.window invalidateCursorRectsForView:self.detailLabel];
}

// Shows the summary as a link that opens the list of files from the last transfer.
- (void)setStatus:(NSString *)status results:(NSArray<NSDictionary *> *)results summary:(NSString *)summary {
    [self setStatus:status detail:@""];
    self.lastResults = results;
    self.lastResultsTitle = [NSString stringWithFormat:@"%@ · %@",
                             status, [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                                    dateStyle:NSDateFormatterNoStyle
                                                                    timeStyle:NSDateFormatterShortStyle]];
    if (!results.count) {
        self.detailLabel.stringValue = summary ?: @"";
        return;
    }

    NSDictionary *attrs = @{
        NSFontAttributeName: self.detailLabel.font,
        NSForegroundColorAttributeName: NSColor.linkColor,
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
    };
    self.detailLabel.attributedStringValue =
        [[NSAttributedString alloc] initWithString:[summary stringByAppendingString:@" ›"] attributes:attrs];
    self.detailLabel.toolTip = @"Show the files from this transfer";
    __weak AppController *weakSelf = self;
    self.detailLabel.clickHandler = ^{
        [weakSelf showResults:nil];
    };
    [self.window invalidateCursorRectsForView:self.detailLabel];
}

- (void)showResults:(id)sender {
    (void)sender;
    if (!self.lastResults.count) {
        NSBeep();
        return;
    }
    if (!self.resultsController) self.resultsController = [ResultsController new];
    [self.resultsController showResults:self.lastResults title:self.lastResultsTitle];
}

- (void)updateDeviceUIWithState:(NSString *)state name:(NSString *)name info:(NSString *)info {
    NSColor *dot = NSColor.tertiaryLabelColor;
    BOOL connected = [state isEqualToString:@"device"];

    if (connected) {
        dot = NSColor.systemGreenColor;
        self.deviceLabel.stringValue = name ?: @"Android device";
        self.deviceInfoLabel.stringValue = info.length ? info : @"Connected";
    } else if ([state isEqualToString:@"unauthorized"]) {
        dot = NSColor.systemOrangeColor;
        self.deviceLabel.stringValue = @"Waiting for permission";
        self.deviceInfoLabel.stringValue = @"Unlock the phone and tap “Allow” on the USB debugging prompt";
    } else if ([state isEqualToString:@"offline"]) {
        dot = NSColor.systemOrangeColor;
        self.deviceLabel.stringValue = @"Device offline";
        self.deviceInfoLabel.stringValue = @"Reconnect the cable or toggle USB debugging";
    } else if ([state isEqualToString:@"noadb"]) {
        dot = NSColor.systemRedColor;
        self.deviceLabel.stringValue = @"adb not found";
        self.deviceInfoLabel.stringValue = @"Install it with: brew install android-platform-tools";
    } else if ([state isEqualToString:@"searching"]) {
        self.deviceLabel.stringValue = @"Looking for a device…";
        self.deviceInfoLabel.stringValue = @" ";
    } else {
        dot = NSColor.systemOrangeColor;
        self.deviceLabel.stringValue = @"No device connected";
        self.deviceInfoLabel.stringValue = @"Connect an Android phone with USB debugging enabled";
    }

    self.deviceDot.layer.backgroundColor = dot.CGColor;
    self.browseButton.enabled = connected;
    self.drop.active = connected || self.transferring;

    if (!self.transferring) {
        if (connected) {
            [self.drop setTitle:@"Drop files or folders" subtitle:@"or click to choose" symbol:@"arrow.down.doc"];
        } else {
            [self.drop setTitle:@"Connect a device" subtitle:@"Files can be dropped once a phone is connected" symbol:@"cable.connector"];
        }
    }
}

#pragma mark Destination

- (void)pathFieldChanged:(id)sender {
    (void)sender;
    [self commitDestination];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    (void)notification;
    [self commitDestination];
}

- (void)comboBoxSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    // The new value isn't in stringValue until the selection change is processed.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self commitDestination];
    });
}

// Always reads what's in the field right now, so a path that was typed but never
// confirmed with Return is still the one used for the next transfer.
- (NSString *)commitDestination {
    NSString *path = [self normalizedPath:self.pathField.stringValue];
    if (![self.pathField.stringValue isEqualToString:path] && !self.pathField.currentEditor) {
        self.pathField.stringValue = path;
    }
    [NSUserDefaults.standardUserDefaults setObject:path forKey:kDestinationKey];
    return path;
}

- (void)setDestination:(NSString *)path {
    self.pathField.stringValue = [self normalizedPath:path];
    [self commitDestination];
}

- (void)rememberDestination:(NSString *)path {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray *recent = [[defaults stringArrayForKey:kRecentDestinationsKey] ?: @[] mutableCopy];
    [recent removeObject:path];
    [recent insertObject:path atIndex:0];
    while (recent.count > kMaxRecentDestinations) [recent removeLastObject];
    [defaults setObject:recent forKey:kRecentDestinationsKey];
    [self reloadRecentDestinations];
}

- (void)reloadRecentDestinations {
    NSMutableArray *items = [[NSUserDefaults.standardUserDefaults stringArrayForKey:kRecentDestinationsKey] ?: @[] mutableCopy];
    for (NSString *common in @[kDefaultRemote, @"/sdcard/Music", @"/sdcard/Movies", @"/sdcard/Pictures", @"/sdcard/Documents"]) {
        if (![items containsObject:common]) [items addObject:common];
    }
    [self.pathField removeAllItems];
    [self.pathField addItemsWithObjectValues:items];
}

- (NSString *)normalizedPath:(NSString *)path {
    NSString *p =
        [path stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (!p.length) return kDefaultRemote;

    if ([p hasPrefix:@"~"]) {
        p = [@"/sdcard" stringByAppendingString:[p substringFromIndex:1]];
    } else if (![p hasPrefix:@"/"]) {
        // "Music/Rock" means /sdcard/Music/Rock; "sdcard/Music" and "storage/..." get a leading slash.
        NSString *first = [p componentsSeparatedByString:@"/"].firstObject;
        if ([first isEqualToString:@"sdcard"] || [first isEqualToString:@"storage"]) {
            p = [@"/" stringByAppendingString:p];
        } else {
            p = [@"/sdcard/" stringByAppendingString:p];
        }
    }

    while ([p rangeOfString:@"//"].location != NSNotFound) {
        p = [p stringByReplacingOccurrencesOfString:@"//" withString:@"/"];
    }

    while (p.length > 1 && [p hasSuffix:@"/"]) {
        p = [p substringToIndex:p.length - 1];
    }

    return p;
}

#pragma mark ADB

- (NSString *)adbPath {
    if (self.cachedADBPath) return self.cachedADBPath;

    NSDictionary *env = NSProcessInfo.processInfo.environment;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    // Explicit override for unusual installs.
    if ([env[@"ANDROID_DROP_ADB"] length]) [paths addObject:env[@"ANDROID_DROP_ADB"]];
    [paths addObjectsFromArray:@[
        @"/opt/homebrew/bin/adb",
        @"/usr/local/bin/adb",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Android/sdk/platform-tools/adb"],
    ]];

    for (NSString *key in @[@"ANDROID_HOME", @"ANDROID_SDK_ROOT"]) {
        if ([env[key] length]) [paths addObject:[env[key] stringByAppendingPathComponent:@"platform-tools/adb"]];
    }
    for (NSString *dir in [env[@"PATH"] componentsSeparatedByString:@":"]) {
        if (dir.length) [paths addObject:[dir stringByAppendingPathComponent:@"adb"]];
    }
    [paths addObject:@"/usr/bin/adb"];

    for (NSString *path in paths) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
            self.cachedADBPath = path;
            return path;
        }
    }

    // Not cached, so installing adb while the app is running is picked up.
    return @"adb";
}

- (void)appendLog:(NSString *)message {
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message ?: @""];

    dispatch_async(self.logQueue, ^{
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
        NSString *path = [dir stringByAppendingPathComponent:@"AndroidDrop.log"];
        NSFileManager *fm = [NSFileManager defaultManager];

        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

        unsigned long long size = [[fm attributesOfItemAtPath:path error:nil] fileSize];
        if (size > kMaxLogBytes) {
            NSString *old = [dir stringByAppendingPathComponent:@"AndroidDrop.old.log"];
            [fm removeItemAtPath:old error:nil];
            [fm moveItemAtPath:path toPath:old error:nil];
        }

        FILE *f = fopen(path.fileSystemRepresentation, "a");
        if (!f) return;
        fputs(line.UTF8String, f);
        fclose(f);
    });
}

- (BOOL)runADB:(NSArray<NSString *> *)arguments
        output:(NSString **)output
         error:(NSString **)errorText {
    return [self runADB:arguments quiet:NO started:nil output:output error:errorText];
}

- (BOOL)runADB:(NSArray<NSString *> *)arguments
         quiet:(BOOL)quiet
       started:(void (^)(pid_t pid))started
        output:(NSString **)output
         error:(NSString **)errorText {

    NSString *adb = [self adbPath];

    if (!quiet) {
        [self appendLog:[NSString stringWithFormat:@"ADB %@", [arguments componentsJoinedByString:@" "]]];
    }

    NSData *data = nil;
    int status = 0;
    int rc = 0;

    // Transient launch failures (EAGAIN, EINTR, EMFILE…) are retried.
    for (int attempt = 0; attempt < 4; attempt++) {
        rc = ADBSpawnCapture(adb, arguments, started, &data, &status);
        if (rc == 0 || rc == ENOENT || rc == EACCES) break;
        [self appendLog:[NSString stringWithFormat:@"ADB LAUNCH RETRY (%s): %@",
                         strerror(rc), [arguments componentsJoinedByString:@" "]]];
        usleep((useconds_t)(150000 * (attempt + 1)));
    }

    if (rc != 0) {
        NSString *msg = (rc == ENOENT)
            ? @"adb was not found. Install it with: brew install android-platform-tools"
            : [NSString stringWithFormat:@"Could not start adb: %s", strerror(rc)];
        [self appendLog:[NSString stringWithFormat:@"ADB LAUNCH ERROR: %@ (%@)",
                         msg, [arguments componentsJoinedByString:@" "]]];
        if (output) *output = @"";
        if (errorText) *errorText = msg;
        return NO;
    }

    NSString *text = ADBStringFromData(data);
    if (output) *output = text;

    if (status != 0) {
        NSString *msg = text.length ? text : [NSString stringWithFormat:@"adb exited with code %d", status];
        [self appendLog:[NSString stringWithFormat:@"ADB FAILED (%d): %@ (%@)",
                         status, msg, [arguments componentsJoinedByString:@" "]]];
        if (errorText) *errorText = msg;
        return NO;
    }

    return YES;
}

- (BOOL)runADBShell:(NSString *)command
             serial:(NSString *)serial
             output:(NSString **)output
              error:(NSString **)errorText {
    return [self runADB:@[@"-s", serial ?: @"", @"shell", command ?: @""]
                 output:output
                  error:errorText];
}

- (BOOL)runQuietShell:(NSString *)command serial:(NSString *)serial output:(NSString **)output {
    return [self runADB:@[@"-s", serial ?: @"", @"shell", command ?: @""]
                  quiet:YES
                started:nil
                 output:output
                  error:NULL];
}

- (NSString *)shellQuote:(NSString *)value {
    NSString *v = value ?: @"";
    v = [v stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    return [NSString stringWithFormat:@"'%@'", v];
}

// Free bytes on the filesystem holding `path`, or 0 if unknown.
- (unsigned long long)freeBytesAt:(NSString *)path serial:(NSString *)serial {
    NSString *out = nil;
    if (![self runQuietShell:[NSString stringWithFormat:@"df -k %@", [self shellQuote:path]]
                      serial:serial
                      output:&out]) {
        return 0;
    }
    NSString *last = [[out componentsSeparatedByString:@"\n"] lastObject];
    NSMutableArray *columns = [NSMutableArray array];
    for (NSString *c in [last componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (c.length) [columns addObject:c];
    }
    if (columns.count < 4) return 0;
    return strtoull([columns[3] UTF8String], NULL, 10) * 1024ull;
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

        [result appendString:bad ? @"_" : [NSString stringWithCharacters:&c length:1]];
    }

    while (result.length && ([result hasSuffix:@" "] || [result hasSuffix:@"."])) {
        [result deleteCharactersInRange:NSMakeRange(result.length - 1, 1)];
    }

    if (!result.length || [result isEqualToString:@"."] || [result isEqualToString:@".."]) {
        return @"file";
    }

    NSData *data = [result dataUsingEncoding:NSUTF8StringEncoding];

    if (data.length > 255) {
        NSString *suffix = @"...";
        NSUInteger maxBytes = 255 - [suffix lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

        NSMutableString *left = [NSMutableString string];
        __block NSUInteger leftBytes = 0;

        [result enumerateSubstringsInRange:NSMakeRange(0, result.length)
                                   options:NSStringEnumerationByComposedCharacterSequences
                                usingBlock:^(NSString *ch, NSRange r1, NSRange r2, BOOL *stop) {
            (void)r1; (void)r2;
            NSUInteger bytes = [ch lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            if (leftBytes + bytes > maxBytes / 2) { *stop = YES; return; }
            [left appendString:ch];
            leftBytes += bytes;
        }];

        NSMutableString *right = [NSMutableString string];
        __block NSUInteger rightBytes = 0;

        [result enumerateSubstringsInRange:NSMakeRange(0, result.length)
                                   options:NSStringEnumerationByComposedCharacterSequences |
                                           NSStringEnumerationReverse
                                usingBlock:^(NSString *ch, NSRange r1, NSRange r2, BOOL *stop) {
            (void)r1; (void)r2;
            NSUInteger bytes = [ch lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            if (leftBytes + rightBytes + bytes > maxBytes) { *stop = YES; return; }
            [right insertString:ch atIndex:0];
            rightBytes += bytes;
        }];

        result = [NSMutableString stringWithFormat:@"%@%@%@", left, suffix, right];
    }

    return result;
}

// Finder litter that shouldn't end up on the phone.
- (BOOL)isJunkFileName:(NSString *)name {
    return [name isEqualToString:@".DS_Store"] ||
           [name isEqualToString:@".localized"] ||
           [name isEqualToString:@"Icon\r"] ||
           [name hasPrefix:@"._"];
}

#pragma mark Device

- (void)deviceTimerTick:(NSTimer *)timer {
    (void)timer;
    if (!self.deviceRefreshRunning && !self.transferring) {
        [self refreshDevice];
    }
}

- (NSDictionary *)loadInfoForSerial:(NSString *)serial modelHint:(NSString *)modelHint {
    NSString *out = nil;
    [self runQuietShell:@"echo \"$(getprop ro.product.marketname)|$(getprop ro.product.vendor.marketname)|"
                        @"$(getprop ro.product.model)|$(getprop ro.build.version.release)\""
                 serial:serial
                 output:&out];

    NSArray<NSString *> *lines = [out ?: @"" componentsSeparatedByString:@"|"];
    NSString *(^line)(NSUInteger) = ^NSString *(NSUInteger i) {
        if (i >= lines.count) return @"";
        return [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    };

    NSString *name = line(0).length ? line(0) : (line(1).length ? line(1) : line(2));
    if (!name.length) name = modelHint.length ? modelHint : serial;
    name = [name stringByReplacingOccurrencesOfString:@"_" withString:@" "];

    return @{@"name": name, @"android": line(3)};
}

- (void)refreshDevice {
    if (self.deviceRefreshRunning) return;
    self.deviceRefreshRunning = YES;

    NSString *preferred = [self.serial copy];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *out = nil;
        NSString *err = nil;
        BOOL ok = [self runADB:@[@"devices", @"-l"] quiet:YES started:nil output:&out error:&err];

        NSString *found = nil;
        NSString *foundModel = nil;
        NSString *otherState = nil;
        NSUInteger readyCount = 0;

        if (ok) {
            for (NSString *rawLine in [out componentsSeparatedByString:@"\n"]) {
                NSString *line = [rawLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (!line.length || [line hasPrefix:@"List of devices"] || [line hasPrefix:@"*"]) continue;

                NSMutableArray<NSString *> *parts = [NSMutableArray array];
                for (NSString *part in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
                    if (part.length) [parts addObject:part];
                }
                if (parts.count < 2) continue;

                NSString *serial = parts[0];
                NSString *state = parts[1];
                NSString *model = nil;
                for (NSString *part in parts) {
                    if ([part hasPrefix:@"model:"]) model = [part substringFromIndex:6];
                }

                if ([state isEqualToString:@"device"]) {
                    readyCount++;
                    // Stick with the current phone while it stays connected.
                    if (!found || [serial isEqualToString:preferred]) {
                        found = serial;
                        foundModel = model;
                    }
                } else if (!otherState) {
                    otherState = state;
                }
            }
        }

        NSDictionary *info = nil;
        if (found) {
            info = self.deviceInfo[found];
            if (!info) info = [self loadInfoForSerial:found modelHint:foundModel];
        }

        // df is cheap but not free; refresh it occasionally, not on every poll.
        NSNumber *cachedFree = info[@"free"];
        NSDate *checked = info[@"freeCheckedAt"];
        unsigned long long freeBytes = cachedFree.unsignedLongLongValue;
        if (found && (!checked || -checked.timeIntervalSinceNow > 20)) {
            freeBytes = [self freeBytesAt:@"/sdcard" serial:found];
            NSMutableDictionary *updated = [info mutableCopy];
            updated[@"free"] = @(freeBytes);
            updated[@"freeCheckedAt"] = [NSDate date];
            info = updated;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.deviceRefreshRunning = NO;
            if (self.transferring) return;

            NSString *old = self.serial;
            self.serial = found;

            if (found) {
                self.deviceInfo[found] = info;

                NSMutableArray *parts = [NSMutableArray array];
                if ([info[@"android"] length]) [parts addObject:[@"Android " stringByAppendingString:info[@"android"]]];
                if (freeBytes) [parts addObject:[NSString stringWithFormat:@"%@ free", ADBFormatBytes(freeBytes)]];
                if (readyCount > 1) {
                    [parts addObject:[NSString stringWithFormat:@"%lu devices connected, using %@",
                                      (unsigned long)readyCount, found]];
                }

                [self updateDeviceUIWithState:@"device" name:info[@"name"] info:[parts componentsJoinedByString:@"  ·  "]];

                if (!old.length) {
                    [self setStatus:@"" detail:@""];
                    [self startNextPendingDrop];
                }
            } else {
                NSString *state = otherState ?: @"none";
                BOOL noADB = !ok && [err containsString:@"adb was not found"];
                [self updateDeviceUIWithState:noADB ? @"noadb" : state name:nil info:nil];

                if (self.browser) [self.browser close];
            }
        });
    });
}

- (void)browse:(id)sender {
    (void)sender;

    if (!self.serial.length) {
        NSBeep();
        return;
    }

    if (self.browser) [self.browser close];

    BrowserController *browser = [BrowserController new];
    browser.owner = self;
    // The browser always starts at the root of shared storage.
    browser.current = kBrowserRoot;

    self.browser = browser;
    [browser show];
}

- (void)showLog:(id)sender {
    (void)sender;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/AndroidDrop.log"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:@""];
    } else {
        NSBeep();
    }
}

- (void)chooseFiles:(id)sender {
    (void)sender;

    if (!self.serial.length) {
        NSBeep();
        return;
    }

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = YES;
    panel.prompt = @"Send";
    panel.message = [NSString stringWithFormat:@"Choose files or folders to send to %@", [self commitDestination]];

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            [self sendURLs:panel.URLs];
        }
    }];
}

#pragma mark Transfer

- (void)sendURLs:(NSArray<NSURL *> *)urls {
    if (!urls.count) return;

    NSString *dest = [self commitDestination];

    if (self.transferring) {
        // Picked up when the current transfer finishes.
        [self.pendingDrops addObject:@{@"urls": urls, @"dest": dest}];
        [self.drop setTitle:@"Sending…"
                   subtitle:[NSString stringWithFormat:@"%lu more drop(s) queued", (unsigned long)self.pendingDrops.count]
                     symbol:nil];
        return;
    }

    if (!self.serial.length) {
        if (self.deviceRefreshRunning) {
            // Still looking for the phone (e.g. right after launch); send once it's found.
            [self.pendingDrops addObject:@{@"urls": urls, @"dest": dest}];
            return;
        }
        NSBeep();
        [self setStatus:@"No Android device connected" detail:@""];
        return;
    }

    [self beginTransferWithURLs:urls files:nil destination:dest];
}

- (void)invalidateFreeSpace {
    NSMutableDictionary *info = [self.deviceInfo[self.serial ?: @""] mutableCopy];
    if (!info) return;
    [info removeObjectForKey:@"freeCheckedAt"];
    self.deviceInfo[self.serial] = info;
}

- (void)startNextPendingDrop {
    if (self.transferring || !self.pendingDrops.count || !self.serial.length) return;
    NSDictionary *next = self.pendingDrops.firstObject;
    [self.pendingDrops removeObjectAtIndex:0];
    [self beginTransferWithURLs:next[@"urls"] files:nil destination:next[@"dest"]];
}

- (void)setTransferUIActive:(BOOL)active {
    self.transferring = active;
    if (!active) [self invalidateFreeSpace];
    self.cancelButton.hidden = !active;
    self.cancelButton.enabled = YES;
    self.progress.hidden = !active;
    self.pathField.enabled = !active;
    self.browseButton.enabled = !active && self.serial.length > 0;

    if (active) {
        self.cancelRequested = NO;
        self.progress.doubleValue = 0;
        self.activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated
                                                                     reason:@"Sending files to Android"];
        [self.drop setTitle:@"Sending…" subtitle:@"Drop more files to queue them" symbol:@"arrow.up.circle"];
    } else {
        if (self.activity) [NSProcessInfo.processInfo endActivity:self.activity];
        self.activity = nil;
        NSApp.dockTile.badgeLabel = nil;
        [self.drop setTitle:@"Drop files or folders" subtitle:@"or click to choose" symbol:@"arrow.down.doc"];
    }
}

- (void)cancelTransfer:(id)sender {
    (void)sender;
    [self.pendingDrops removeAllObjects];
    self.cancelRequested = YES;
    self.cancelButton.enabled = NO;
    [self setStatus:@"Cancelling…" detail:@""];
    pid_t pid = self.activePid;
    if (pid > 0) kill(pid, SIGTERM);
}

// Either `urls` (fresh drop, scanned in the background) or `files` (retry) is given.
- (void)beginTransferWithURLs:(NSArray<NSURL *> *)urls
                        files:(NSArray<NSDictionary *> *)retryFiles
                  destination:(NSString *)dest {
    [self setTransferUIActive:YES];
    [self rememberDestination:dest];
    [self setStatus:@"Preparing…" detail:@""];

    NSString *serial = [self.serial copy];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
        NSMutableOrderedSet<NSString *> *dirs = [NSMutableOrderedSet orderedSet];

        if (retryFiles) {
            [files addObjectsFromArray:retryFiles];
        } else {
            [self collectFilesFromURLs:urls destination:dest files:files dirs:dirs];
            // Finder order (01, 02 … 10), not the order the file system happens to return.
            [files sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [a[@"local"] localizedStandardCompare:b[@"local"]];
            }];
        }

        [self performTransferOfFiles:files dirs:dirs.array destination:dest serial:serial];
    });
}

- (void)collectFilesFromURLs:(NSArray<NSURL *> *)urls
                 destination:(NSString *)dest
                       files:(NSMutableArray<NSDictionary *> *)files
                        dirs:(NSMutableOrderedSet<NSString *> *)dirs {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *keys = @[NSURLIsDirectoryKey, NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey];

    NSDictionary *(^fileEntry)(NSURL *, NSString *) = ^NSDictionary *(NSURL *url, NSString *remote) {
        NSURL *resolved = url;
        NSNumber *link = nil;
        [url getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
        if (link.boolValue) resolved = url.URLByResolvingSymlinksInPath;

        NSNumber *regular = nil;
        NSNumber *size = nil;
        [resolved getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        [resolved getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (!regular.boolValue) return nil;

        return @{@"local": url.path, @"remote": remote, @"size": size ?: @0};
    };

    for (NSURL *url in urls) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:url.path isDirectory:&isDir]) continue;

        NSString *rootRemote = [dest stringByAppendingFormat:@"/%@", [self safeName:url.lastPathComponent]];

        if (!isDir) {
            NSDictionary *entry = fileEntry(url, rootRemote);
            if (entry) [files addObject:entry];
            continue;
        }

        [dirs addObject:rootRemote];

        NSDirectoryEnumerator *enumerator =
            [fm enumeratorAtURL:url
     includingPropertiesForKeys:keys
                        options:0
                   errorHandler:^BOOL(NSURL *u, NSError *e) {
                [self appendLog:[NSString stringWithFormat:@"READ ERROR %@: %@", u.path, e.localizedDescription]];
                return YES;
            }];

        NSUInteger baseLength = url.path.length;

        for (NSURL *child in enumerator) {
            if ([self isJunkFileName:child.lastPathComponent]) continue;

            NSString *relative = [child.path substringFromIndex:MIN(baseLength, child.path.length)];
            NSString *remote = rootRemote;
            for (NSString *part in relative.pathComponents) {
                if ([part isEqualToString:@"/"]) continue;
                remote = [remote stringByAppendingFormat:@"/%@", [self safeName:part]];
            }

            NSNumber *dirFlag = nil;
            [child getResourceValue:&dirFlag forKey:NSURLIsDirectoryKey error:nil];

            if (dirFlag.boolValue) {
                [dirs addObject:remote];
            } else {
                NSDictionary *entry = fileEntry(child, remote);
                if (entry) [files addObject:entry];
            }
        }
    }
}

// mkdir -p for many folders in as few adb calls as possible.
- (BOOL)makeDirectories:(NSArray<NSString *> *)dirs serial:(NSString *)serial error:(NSString **)errorText {
    NSMutableString *command = [NSMutableString string];
    BOOL ok = YES;

    for (NSUInteger i = 0; i <= dirs.count; i++) {
        NSString *quoted = i < dirs.count ? [self shellQuote:dirs[i]] : nil;
        NSUInteger pending = [command lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

        if (command.length &&
            (!quoted || pending + [quoted lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1 > kMaxShellCommandBytes)) {
            NSString *err = nil;
            if (![self runADBShell:[@"mkdir -p" stringByAppendingString:command] serial:serial output:NULL error:&err]) {
                ok = NO;
                if (errorText && !*errorText) *errorText = err;
            }
            [command setString:@""];
        }

        if (quoted) [command appendFormat:@" %@", quoted];
    }
    return ok;
}

- (BOOL)deviceIsReady:(NSString *)serial {
    NSString *out = nil;
    return [self runADB:@[@"-s", serial, @"get-state"] quiet:YES started:nil output:&out error:NULL] &&
           [out isEqualToString:@"device"];
}

- (void)performTransferOfFiles:(NSArray<NSDictionary *> *)files
                          dirs:(NSArray<NSString *> *)dirs
                   destination:(NSString *)dest
                        serial:(NSString *)serial {

    unsigned long long totalBytes = 0;
    for (NSDictionary *f in files) totalBytes += [f[@"size"] unsignedLongLongValue];

    if (!files.count && !dirs.count) {
        [self finishWithTitle:@"Nothing to send" message:@"The dropped items contain no files." failures:nil destination:dest];
        return;
    }

    [self appendLog:[NSString stringWithFormat:@"TRANSFER START %lu file(s), %@ → %@",
                     (unsigned long)files.count, ADBFormatBytes(totalBytes), dest]];

    NSString *errText = nil;
    if (![self makeDirectories:@[dest] serial:serial error:&errText]) {
        [self finishWithTitle:@"Can't create the destination folder"
                      message:[NSString stringWithFormat:@"%@\n\n%@\n\nOnly folders in shared storage (/sdcard/…) are writable without root.",
                               dest, errText ?: @"Unknown error"]
                     failures:nil
                  destination:dest];
        return;
    }

    unsigned long long freeBytes = [self freeBytesAt:dest serial:serial];
    if (freeBytes && totalBytes > freeBytes) {
        [self finishWithTitle:@"Not enough space on the device"
                      message:[NSString stringWithFormat:@"Need %@, but only %@ is free in %@.",
                               ADBFormatBytes(totalBytes), ADBFormatBytes(freeBytes), dest]
                     failures:nil
                  destination:dest];
        return;
    }

    if (dirs.count) {
        // Failures here aren't fatal: adb push creates missing parents itself,
        // and any real problem shows up as a failed push with the adb message.
        [self makeDirectories:dirs serial:serial error:NULL];
    }

    NSUInteger total = files.count;
    __block NSUInteger done = 0;
    __block NSUInteger failedCount = 0;
    NSMutableArray<NSDictionary *> *failures = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    __block unsigned long long bytesDone = 0;
    NSDate *start = [NSDate date];
    NSString *abortReason = nil;

    void (^report)(NSString *, unsigned long long) = ^(NSString *name, unsigned long long partial) {
        unsigned long long sent = bytesDone + partial;
        NSUInteger index = MIN(done + failedCount + 1, total);
        NSTimeInterval elapsed = -start.timeIntervalSinceNow;
        double rate = elapsed > 1.0 ? sent / elapsed : 0;

        NSString *status = [NSString stringWithFormat:@"Sending %lu of %lu · %@",
                            (unsigned long)index, (unsigned long)total, name];
        NSMutableString *detail = [NSMutableString stringWithFormat:@"%@ of %@",
                                   ADBFormatBytes(sent), ADBFormatBytes(totalBytes)];
        if (rate > 0) {
            [detail appendFormat:@"  ·  %@/s", ADBFormatBytes((unsigned long long)rate)];
            if (totalBytes > sent) {
                [detail appendFormat:@"  ·  %@ left", ADBFormatDuration((totalBytes - sent) / rate)];
            }
        }
        double fraction = totalBytes ? (double)sent / (double)totalBytes
                                     : (total ? (double)(index - 1) / (double)total : 1.0);
        NSString *badge = [NSString stringWithFormat:@"%d%%", (int)floor(fraction * 100)];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.cancelRequested) return;
            self.progress.doubleValue = fraction;
            [self setStatus:status detail:detail];
            NSApp.dockTile.badgeLabel = badge;
        });
    };

    for (NSUInteger i = 0; i < files.count; i++) {
        if (self.cancelRequested) break;

        NSDictionary *entry = files[i];
        NSString *local = entry[@"local"];
        NSString *remote = entry[@"remote"];
        unsigned long long size = [entry[@"size"] unsignedLongLongValue];
        NSString *name = local.lastPathComponent;

        report(name, 0);

        NSString *lastError = nil;
        BOOL pushed = NO;

        for (NSUInteger attempt = 0; attempt < kPushAttempts && !pushed && !self.cancelRequested; attempt++) {
            if (attempt > 0) {
                [self appendLog:[NSString stringWithFormat:@"RETRY %lu: %@", (unsigned long)attempt, local]];
                usleep((useconds_t)(400000 * attempt));
                if (![self deviceIsReady:serial]) break;
            }

            // Large files: poll the size on the device so the bar moves during the push.
            ADBFlag *running = nil;
            if (size >= kLargeFileBytes) {
                running = [ADBFlag new];
                running.value = YES;
                NSString *statCommand = [NSString stringWithFormat:@"stat -c %%s %@", [self shellQuote:remote]];
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    while (running.value) {
                        usleep(700000);
                        if (!running.value) break;
                        NSString *out = nil;
                        if ([self runQuietShell:statCommand serial:serial output:&out] && running.value) {
                            unsigned long long partial = MIN(strtoull(out.UTF8String, NULL, 10), size);
                            report(name, partial);
                        }
                    }
                });
            }

            NSString *pushOutput = nil;
            NSString *pushError = nil;
            self.activeRemote = remote;

            pushed = [self runADB:@[@"-s", serial, @"push", local, remote]
                            quiet:NO
                          started:^(pid_t pid) {
                              self.activePid = pid;
                              if (self.cancelRequested) kill(pid, SIGTERM);
                          }
                           output:&pushOutput
                            error:&pushError];

            self.activePid = 0;
            running.value = NO;

            if (!pushed) {
                lastError = pushError.length ? pushError
                          : (pushOutput.length ? pushOutput : @"adb returned an error without details");
            }
        }

        if (self.cancelRequested) {
            if (!pushed) {
                // Remove the partially written file.
                [self runADBShell:[NSString stringWithFormat:@"rm -f %@", [self shellQuote:remote]]
                           serial:serial output:NULL error:NULL];
            }
            break;
        }

        self.activeRemote = nil;

        if (pushed) {
            done++;
            bytesDone += size;
            [results addObject:@{@"file": entry, @"ok": @YES}];
            continue;
        }

        [failures addObject:@{@"file": entry, @"error": lastError ?: @"Unknown error"}];
        [results addObject:failures.lastObject];
        failedCount++;

        if (![self deviceIsReady:serial]) {
            abortReason = @"The device was disconnected.";
            for (NSUInteger j = i + 1; j < files.count; j++) {
                [failures addObject:@{@"file": files[j], @"error": @"Not sent: device disconnected"}];
                [results addObject:failures.lastObject];
            }
            break;
        }
    }

    self.activeRemote = nil;
    NSTimeInterval elapsed = -start.timeIntervalSinceNow;

    [self appendLog:[NSString stringWithFormat:@"TRANSFER END %lu sent, %lu failed%@, %.1fs",
                     (unsigned long)done, (unsigned long)failures.count,
                     self.cancelRequested ? @", cancelled" : @"", elapsed]];

    NSString *summary = [NSString stringWithFormat:@"%lu file(s) · %@ in %@",
                         (unsigned long)done, ADBFormatBytes(bytesDone), ADBFormatDuration(elapsed)];

    if (self.cancelRequested) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setTransferUIActive:NO];
            [self setStatus:@"Cancelled" results:results summary:summary];
        });
        return;
    }

    if (!failures.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setTransferUIActive:NO];
            [self setStatus:@"Done" results:results summary:summary];
            [NSApp requestUserAttention:NSInformationalRequest];
            [self refreshDevice];
            [self startNextPendingDrop];
        });
        return;
    }

    NSString *title = abortReason
        ? @"Transfer stopped"
        : [NSString stringWithFormat:@"%lu of %lu file(s) failed", (unsigned long)failures.count, (unsigned long)total];

    NSMutableArray *lines = [NSMutableArray array];
    if (abortReason) [lines addObject:abortReason];
    for (NSUInteger i = 0; i < failures.count && i < 6; i++) {
        NSDictionary *f = failures[i];
        [lines addObject:[NSString stringWithFormat:@"%@\n→ %@\n%@",
                          [f[@"file"][@"local"] lastPathComponent], f[@"file"][@"remote"], f[@"error"]]];
    }
    if (failures.count > 6) {
        [lines addObject:[NSString stringWithFormat:@"…and %lu more (see the log)", (unsigned long)(failures.count - 6)]];
    }

    NSString *failedSummary = [NSString stringWithFormat:@"%@ · %lu failed", summary, (unsigned long)failures.count];
    [self finishWithTitle:title message:[lines componentsJoinedByString:@"\n\n"] failures:failures
              destination:dest results:results summary:failedSummary];
}

- (void)finishWithTitle:(NSString *)title
                message:(NSString *)message
               failures:(NSArray<NSDictionary *> *)failures
            destination:(NSString *)dest {
    [self finishWithTitle:title message:message failures:failures destination:dest results:nil summary:nil];
}

- (void)finishWithTitle:(NSString *)title
                message:(NSString *)message
               failures:(NSArray<NSDictionary *> *)failures
            destination:(NSString *)dest
                results:(NSArray<NSDictionary *> *)results
                summary:(NSString *)summary {

    [self appendLog:[NSString stringWithFormat:@"%@: %@", title, message]];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self setTransferUIActive:NO];
        if (results.count) {
            [self setStatus:title results:results summary:summary];
        } else {
            [self setStatus:title detail:@""];
        }
        [NSApp requestUserAttention:NSCriticalRequest];

        NSAlert *alert = [NSAlert new];
        alert.alertStyle = failures.count ? NSAlertStyleWarning : NSAlertStyleInformational;
        alert.messageText = title;
        alert.informativeText = message ?: @"";

        if (failures.count) [alert addButtonWithTitle:@"Retry Failed"];
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:results.count ? @"Show Files" : @"Show Log"];

        [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
            NSInteger index = response - NSAlertFirstButtonReturn;
            NSString *button = (index >= 0 && index < (NSInteger)alert.buttons.count)
                ? alert.buttons[(NSUInteger)index].title : @"";

            if ([button isEqualToString:@"Show Log"]) [self showLog:nil];
            if ([button isEqualToString:@"Show Files"]) [self showResults:nil];

            if ([button isEqualToString:@"Retry Failed"] && self.serial.length) {
                NSMutableArray *retry = [NSMutableArray array];
                for (NSDictionary *f in failures) [retry addObject:f[@"file"]];
                [self beginTransferWithURLs:nil files:retry destination:dest];
                return;
            }

            [self refreshDevice];
            [self startNextPendingDrop];
        }];
    });
}

@end

#pragma mark - LinkLabel

@implementation LinkLabel

- (void)mouseDown:(NSEvent *)event {
    if (self.clickHandler) {
        self.clickHandler();
    } else {
        [super mouseDown:event];
    }
}

- (void)resetCursorRects {
    if (self.clickHandler) [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}

@end

#pragma mark - ResultsController

@implementation ResultsController

- (void)buildWindow {
    self.window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 480)
                                    styleMask:(NSWindowStyleMaskTitled |
                                               NSWindowStyleMaskClosable |
                                               NSWindowStyleMaskMiniaturizable |
                                               NSWindowStyleMaskResizable)
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    self.window.minSize = NSMakeSize(520, 300);
    self.window.releasedWhenClosed = NO;
    self.window.frameAutosaveName = @"ResultsWindow";

    NSView *content = self.window.contentView;

    self.filter = [NSSegmentedControl segmentedControlWithLabels:@[@"All", @"Sent", @"Failed"]
                                                    trackingMode:NSSegmentSwitchTrackingSelectOne
                                                          target:self
                                                          action:@selector(filterChanged:)];
    self.filter.selectedSegment = 0;
    self.filter.translatesAutoresizingMaskIntoConstraints = NO;

    NSScrollView *scroll = [NSScrollView new];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;

    self.table = [NSTableView new];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 24;
    self.table.style = NSTableViewStyleFullWidth;
    self.table.usesAlternatingRowBackgroundColors = YES;
    self.table.allowsMultipleSelection = YES;
    self.table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;

    NSArray *columns = @[@[@"file", @"File", @330], @[@"remote", @"On device", @330], @[@"size", @"Size", @70]];
    for (NSArray *c in columns) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:c[0]];
        column.title = c[1];
        column.width = [c[2] doubleValue];
        column.minWidth = [c[0] isEqualToString:@"size"] ? 60 : 120;
        if ([c[0] isEqualToString:@"size"]) column.maxWidth = 90;
        column.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
        [self.table addTableColumn:column];
    }
    scroll.documentView = self.table;

    self.footer = [NSTextField labelWithString:@""];
    self.footer.font = [NSFont systemFontOfSize:12];
    self.footer.textColor = NSColor.secondaryLabelColor;
    self.footer.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.footer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.footer setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSButton *copy = [NSButton buttonWithTitle:@"Copy List" target:self action:@selector(copyList:)];
    copy.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *done = [NSButton buttonWithTitle:@"Done" target:self action:@selector(done:)];
    done.keyEquivalent = @"\r";
    done.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *v in @[self.filter, scroll, self.footer, copy, done]) [content addSubview:v];

    [NSLayoutConstraint activateConstraints:@[
        [self.filter.topAnchor constraintEqualToAnchor:content.topAnchor constant:14],
        [self.filter.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],

        [scroll.topAnchor constraintEqualToAnchor:self.filter.bottomAnchor constant:12],
        [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],

        [done.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:14],
        [done.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
        [done.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [copy.trailingAnchor constraintEqualToAnchor:done.leadingAnchor constant:-8],
        [copy.centerYAnchor constraintEqualToAnchor:done.centerYAnchor],
        [self.footer.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:18],
        [self.footer.centerYAnchor constraintEqualToAnchor:done.centerYAnchor],
        [self.footer.trailingAnchor constraintLessThanOrEqualToAnchor:copy.leadingAnchor constant:-12],
    ]];

    if (![self.window setFrameUsingName:@"ResultsWindow"]) [self.window center];
}

- (void)showResults:(NSArray<NSDictionary *> *)results title:(NSString *)title {
    if (!self.window) [self buildWindow];

    self.results = results;
    self.window.title = @"Transferred Files";
    self.window.subtitle = title ?: @"";

    NSUInteger failed = 0;
    unsigned long long bytes = 0;
    for (NSDictionary *r in results) {
        if ([r[@"ok"] boolValue]) {
            bytes += [r[@"file"][@"size"] unsignedLongLongValue];
        } else {
            failed++;
        }
    }
    NSUInteger sent = results.count - failed;

    [self.filter setLabel:[NSString stringWithFormat:@"All  %lu", (unsigned long)results.count] forSegment:0];
    [self.filter setLabel:[NSString stringWithFormat:@"Sent  %lu", (unsigned long)sent] forSegment:1];
    [self.filter setLabel:[NSString stringWithFormat:@"Failed  %lu", (unsigned long)failed] forSegment:2];
    [self.filter setEnabled:failed > 0 forSegment:2];
    // Open on the failures if there are any — that's what needs attention.
    self.filter.selectedSegment = failed ? 2 : 0;

    self.footer.stringValue = [NSString stringWithFormat:@"%lu sent · %@%@", (unsigned long)sent, ADBFormatBytes(bytes),
                               failed ? [NSString stringWithFormat:@" · %lu failed", (unsigned long)failed] : @""];

    [self applyFilter];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)applyFilter {
    NSInteger segment = self.filter.selectedSegment;
    if (segment <= 0) {
        self.visible = self.results;
    } else {
        BOOL wantOK = segment == 1;
        NSMutableArray *rows = [NSMutableArray array];
        for (NSDictionary *r in self.results) {
            if ([r[@"ok"] boolValue] == wantOK) [rows addObject:r];
        }
        self.visible = rows;
    }
    [self.table reloadData];
}

- (void)filterChanged:(id)sender {
    (void)sender;
    [self applyFilter];
}

- (void)copyList:(id)sender {
    (void)sender;
    NSIndexSet *selected = self.table.selectedRowIndexes;
    NSMutableArray *lines = [NSMutableArray array];

    [self.visible enumerateObjectsUsingBlock:^(NSDictionary *r, NSUInteger i, BOOL *stop) {
        (void)stop;
        if (selected.count && ![selected containsIndex:i]) return;
        BOOL ok = [r[@"ok"] boolValue];
        NSString *line = [NSString stringWithFormat:@"%@\t%@\t%@", ok ? @"sent" : @"failed",
                          r[@"file"][@"local"], r[@"file"][@"remote"]];
        if (!ok) line = [line stringByAppendingFormat:@"\t%@",
                         [r[@"error"] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]];
        [lines addObject:line];
    }];

    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:[lines componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
}

- (void)done:(id)sender {
    (void)sender;
    [self.window close];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)self.visible.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSString *identifier = column.identifier;
    NSTableCellView *cell = [tableView makeViewWithIdentifier:identifier owner:self];

    if (!cell) {
        cell = [NSTableCellView new];
        cell.identifier = identifier;

        NSTextField *field = [NSTextField labelWithString:@""];
        field.lineBreakMode = NSLineBreakByTruncatingMiddle;
        field.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:field];
        cell.textField = field;

        NSLayoutXAxisAnchor *leading = cell.leadingAnchor;
        CGFloat inset = 4;
        if ([identifier isEqualToString:@"file"]) {
            NSImageView *icon = [NSImageView new];
            icon.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:icon];
            cell.imageView = icon;
            [NSLayoutConstraint activateConstraints:@[
                [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
                [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
                [icon.widthAnchor constraintEqualToConstant:18],
            ]];
            leading = icon.trailingAnchor;
            inset = 6;
        }
        if ([identifier isEqualToString:@"size"]) {
            field.alignment = NSTextAlignmentRight;
            field.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];
        }
        [NSLayoutConstraint activateConstraints:@[
            [field.leadingAnchor constraintEqualToAnchor:leading constant:inset],
            [field.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [field.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    NSDictionary *r = self.visible[(NSUInteger)row];
    NSDictionary *file = r[@"file"];
    BOOL ok = [r[@"ok"] boolValue];
    // adb repeats the full local path in its message; the File column already shows it.
    NSString *error = [r[@"error"] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    error = [error stringByReplacingOccurrencesOfString:file[@"local"] withString:[file[@"local"] lastPathComponent]];

    cell.textField.textColor = NSColor.labelColor;
    cell.toolTip = nil;

    if ([identifier isEqualToString:@"file"]) {
        cell.imageView.image = ADBSymbol(ok ? @"checkmark.circle.fill" : @"exclamationmark.triangle.fill",
                                         13, NSFontWeightRegular);
        cell.imageView.contentTintColor = ok ? NSColor.systemGreenColor : NSColor.systemOrangeColor;
        cell.textField.stringValue = [file[@"local"] lastPathComponent];
        cell.toolTip = file[@"local"];
    } else if ([identifier isEqualToString:@"remote"]) {
        if (ok) {
            cell.textField.stringValue = [file[@"remote"] stringByDeletingLastPathComponent];
            cell.textField.lineBreakMode = NSLineBreakByTruncatingMiddle;
            cell.textField.textColor = NSColor.secondaryLabelColor;
            cell.toolTip = file[@"remote"];
        } else {
            cell.textField.stringValue = error ?: @"Failed";
            cell.textField.lineBreakMode = NSLineBreakByTruncatingTail;
            cell.textField.textColor = NSColor.systemRedColor;
            cell.toolTip = [NSString stringWithFormat:@"%@\n\n%@", file[@"remote"], error ?: @""];
        }
    } else {
        cell.textField.stringValue = ADBFormatBytes([file[@"size"] unsignedLongLongValue]);
        cell.textField.textColor = NSColor.secondaryLabelColor;
    }

    return cell;
}

@end

#pragma mark - BrowserController

@implementation BrowserController

- (void)show {
    self.window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 480)
                                    styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskResizable)
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    self.window.title = @"Choose a Folder on the Device";
    self.window.minSize = NSMakeSize(520, 360);

    NSView *content = self.window.contentView;

    self.upButton = [NSButton buttonWithImage:ADBSymbol(@"chevron.up", 13, NSFontWeightSemibold)
                                       target:self
                                       action:@selector(goUp:)];
    self.upButton.bezelStyle = NSBezelStyleRounded;
    self.upButton.toolTip = @"Enclosing folder";
    self.upButton.translatesAutoresizingMaskIntoConstraints = NO;

    self.pathField = [NSTextField textFieldWithString:self.current ?: kBrowserRoot];
    self.pathField.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.pathField.target = self;
    self.pathField.action = @selector(pathEntered:);
    self.pathField.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *newFolder = [NSButton buttonWithImage:ADBSymbol(@"folder.badge.plus", 14, NSFontWeightRegular)
                                             target:self
                                             action:@selector(newFolder:)];
    newFolder.bezelStyle = NSBezelStyleRounded;
    newFolder.toolTip = @"New Folder";
    newFolder.translatesAutoresizingMaskIntoConstraints = NO;

    NSScrollView *scroll = [NSScrollView new];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;

    self.table = [NSTableView new];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.headerView = nil;
    self.table.rowHeight = 26;
    self.table.style = NSTableViewStyleFullWidth;
    self.table.usesAlternatingRowBackgroundColors = YES;
    self.table.doubleAction = @selector(doubleClick:);
    self.table.target = self;

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [self.table addTableColumn:column];
    self.table.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;

    scroll.documentView = self.table;

    self.spinner = [NSProgressIndicator new];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.displayedWhenStopped = NO;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;

    self.footer = [NSTextField labelWithString:@""];
    self.footer.font = [NSFont systemFontOfSize:12];
    self.footer.textColor = NSColor.secondaryLabelColor;
    self.footer.lineBreakMode = NSLineBreakByTruncatingTail;
    self.footer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.footer setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.keyEquivalent = @"\033";
    cancel.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *send = [NSButton buttonWithTitle:@"Send Here" target:self action:@selector(selectHere:)];
    send.keyEquivalent = @"\r";
    send.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *v in @[self.upButton, self.pathField, newFolder, scroll, self.spinner, self.footer, cancel, send]) {
        [content addSubview:v];
    }

    [NSLayoutConstraint activateConstraints:@[
        [self.upButton.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [self.upButton.centerYAnchor constraintEqualToAnchor:self.pathField.centerYAnchor],
        [self.pathField.leadingAnchor constraintEqualToAnchor:self.upButton.trailingAnchor constant:8],
        [self.pathField.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
        [newFolder.leadingAnchor constraintEqualToAnchor:self.pathField.trailingAnchor constant:8],
        [newFolder.centerYAnchor constraintEqualToAnchor:self.pathField.centerYAnchor],
        [newFolder.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],

        [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [scroll.topAnchor constraintEqualToAnchor:self.pathField.bottomAnchor constant:12],

        [self.spinner.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:18],
        [self.spinner.centerYAnchor constraintEqualToAnchor:send.centerYAnchor],
        [self.footer.leadingAnchor constraintEqualToAnchor:self.spinner.trailingAnchor constant:6],
        [self.footer.centerYAnchor constraintEqualToAnchor:send.centerYAnchor],
        [self.footer.trailingAnchor constraintLessThanOrEqualToAnchor:cancel.leadingAnchor constant:-12],

        [send.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:14],
        [send.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
        [send.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [cancel.trailingAnchor constraintEqualToAnchor:send.leadingAnchor constant:-8],
        [cancel.centerYAnchor constraintEqualToAnchor:send.centerYAnchor],
    ]];

    [self.owner.window beginSheet:self.window completionHandler:nil];
    [self load:self.current ?: kBrowserRoot];
}

- (NSString *)childPath:(NSString *)name {
    return [self.current isEqualToString:@"/"]
        ? [@"/" stringByAppendingString:name]
        : [self.current stringByAppendingFormat:@"/%@", name];
}

- (void)load:(NSString *)path {
    AppController *owner = self.owner;
    if (!owner.serial.length) return;

    // Only the most recent request updates the list.
    NSUInteger generation = ++self.generation;

    self.current = [owner normalizedPath:path];
    self.pathField.stringValue = self.current;
    self.footer.stringValue = @"Loading…";
    self.upButton.enabled = ![self.current isEqualToString:kBrowserRoot] && ![self.current isEqualToString:@"/"];
    [self.spinner startAnimation:nil];

    NSString *serial = [owner.serial copy];
    NSString *remote = [self.current copy];
    __weak BrowserController *weakSelf = self;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *out = nil;
        NSString *err = nil;

        // The trailing slash makes ls list a symlinked folder (like /sdcard) itself.
        NSString *command = [NSString stringWithFormat:@"ls -1p %@", [owner shellQuote:[remote stringByAppendingString:@"/"]]];
        BOOL ok = [owner runADBShell:command serial:serial output:&out error:&err];

        NSMutableArray<NSDictionary *> *items = [NSMutableArray array];

        if (ok) {
            for (NSString *raw in [out componentsSeparatedByString:@"\n"]) {
                NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
                if (!line.length || [line isEqualToString:@"./"] || [line isEqualToString:@"../"]) continue;

                BOOL isDir = [line hasSuffix:@"/"];
                NSString *name = isDir ? [line substringToIndex:line.length - 1] : line;
                if (name.length) [items addObject:@{@"name": name, @"dir": @(isDir)}];
            }
        }

        [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            BOOL da = [a[@"dir"] boolValue];
            BOOL db = [b[@"dir"] boolValue];
            if (da != db) return da ? NSOrderedAscending : NSOrderedDescending;
            return [a[@"name"] localizedStandardCompare:b[@"name"]];
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            BrowserController *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.generation != generation) return;

            [strongSelf.spinner stopAnimation:nil];
            strongSelf.items = ok ? items : @[];
            [strongSelf.table reloadData];

            if (ok) {
                NSUInteger folders = 0;
                for (NSDictionary *item in items) folders += [item[@"dir"] boolValue];
                strongSelf.footer.stringValue =
                    [NSString stringWithFormat:@"%lu folder(s), %lu file(s)",
                     (unsigned long)folders, (unsigned long)(items.count - folders)];
            } else {
                strongSelf.footer.stringValue = err.length
                    ? [NSString stringWithFormat:@"Can't open this folder: %@", err]
                    : @"Can't open this folder";
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

    if ([self.current isEqualToString:kBrowserRoot] || [self.current isEqualToString:@"/"]) return;

    NSString *parent = [self.current stringByDeletingLastPathComponent];
    if (!parent.length || [parent isEqualToString:@"/"]) parent = kBrowserRoot;

    [self load:parent];
}

- (void)newFolder:(id)sender {
    (void)sender;

    NSAlert *alert = [NSAlert new];
    alert.messageText = @"New Folder";
    alert.informativeText = [NSString stringWithFormat:@"Create a folder in %@", self.current];
    [alert addButtonWithTitle:@"Create"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *field = [NSTextField textFieldWithString:@""];
    field.placeholderString = @"Folder name";
    field.frame = NSMakeRect(0, 0, 260, 24);
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;

    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSString *name = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length) return;
    name = [name stringByReplacingOccurrencesOfString:@"/" withString:@"_"];

    NSString *path = [self childPath:name];
    AppController *owner = self.owner;
    NSString *serial = [owner.serial copy];
    __weak BrowserController *weakSelf = self;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        BOOL ok = [owner runADBShell:[NSString stringWithFormat:@"mkdir -p %@", [owner shellQuote:path]]
                              serial:serial output:NULL error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            BrowserController *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (ok) {
                [strongSelf load:path];
            } else {
                strongSelf.footer.stringValue = [NSString stringWithFormat:@"Can't create folder: %@", err ?: @"unknown error"];
            }
        });
    });
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)self.items.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)column;

    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"cell" owner:self];

    if (!cell) {
        cell = [NSTableCellView new];
        cell.identifier = @"cell";

        NSImageView *icon = [NSImageView new];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *field = [NSTextField labelWithString:@""];
        field.lineBreakMode = NSLineBreakByTruncatingMiddle;
        field.translatesAutoresizingMaskIntoConstraints = NO;

        [cell addSubview:icon];
        [cell addSubview:field];
        cell.imageView = icon;
        cell.textField = field;

        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:6],
            [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:20],
            [field.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:6],
            [field.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-6],
            [field.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    NSDictionary *item = self.items[(NSUInteger)row];
    BOOL dir = [item[@"dir"] boolValue];

    cell.imageView.image = ADBSymbol(dir ? @"folder.fill" : @"doc", 14, NSFontWeightRegular);
    cell.imageView.contentTintColor = dir ? NSColor.systemBlueColor : NSColor.tertiaryLabelColor;
    cell.textField.stringValue = item[@"name"];
    cell.textField.textColor = dir ? NSColor.labelColor : NSColor.secondaryLabelColor;

    return cell;
}

- (void)doubleClick:(id)sender {
    (void)sender;

    NSInteger row = self.table.clickedRow;
    if (row < 0 || (NSUInteger)row >= self.items.count) return;

    NSDictionary *item = self.items[(NSUInteger)row];
    if (![item[@"dir"] boolValue]) return;

    [self load:[self childPath:item[@"name"]]];
}

- (void)cancel:(id)sender {
    (void)sender;
    [self close];
}

- (void)selectHere:(id)sender {
    (void)sender;
    [self.owner setDestination:self.current];
    [self close];
}

- (void)close {
    NSWindow *w = self.window;
    if (!w) return;
    self.window = nil;
    self.generation++;

    if (w.sheetParent) {
        [w.sheetParent endSheet:w];
    } else {
        [w close];
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
