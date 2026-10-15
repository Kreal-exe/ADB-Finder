#import <Cocoa/Cocoa.h>
#import <Quartz/Quartz.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <spawn.h>
#import <signal.h>
#import <sys/wait.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>

extern char **environ;

static NSString * const kAppName = @"ADB Finder";
// Shared storage. On every modern device this is a symlink to /storage/emulated/0.
static NSString * const kStorageRoot = @"/sdcard";
static NSString * const kLastFolderKey = @"LastFolder";
static NSString * const kShowHiddenKey = @"ShowHidden";
static NSString * const kViewModeKey = @"ViewMode";
// Phones connected over Wi-Fi: [{address: "192.168.1.5:5555", name: "Anna's Pixel"}].
static NSString * const kWirelessDevicesKey = @"WirelessDevices";
static NSString * const kRemotePathType = @"local.adbfinder.remote-path";
static NSString * const kRemoteSerialType = @"local.adbfinder.serial";
static NSString * const kLogName = @"ADBFinder";

static const NSUInteger kMaxShellCommandBytes = 3000;
static const NSUInteger kPushAttempts = 3;
static const unsigned long long kLargeFileBytes = 24ull * 1024 * 1024;
static const unsigned long long kMaxLogBytes = 4ull * 1024 * 1024;
// Media previews: whole images up to this size are read for a thumbnail; larger
// JPEGs only use the thumbnail embedded in their EXIF header.
static const unsigned long long kMaxThumbnailImageBytes = 30ull * 1024 * 1024;
static const unsigned long long kVideoProbeBytes = 3ull * 1024 * 1024;
// The EXIF block (with its preview) is at most 64 KB and comes first in a JPEG.
static const unsigned long long kJPEGHeadBytes = 72 * 1024;
static const unsigned long long kMaxThumbnailPDFBytes = 40ull * 1024 * 1024;
static const NSUInteger kThumbnailBatch = 16;
// Thumbnails of a phone that hasn't been connected for this long are deleted.
static const NSTimeInterval kThumbnailKeepSeconds = 30 * 24 * 3600;
static const unsigned long long kThumbnailCacheLimit = 1024ull * 1024 * 1024;

typedef NS_ENUM(NSInteger, ADBViewMode) {
    ADBViewModeIcons = 0,
    ADBViewModeList = 1,
    ADBViewModeColumns = 2,
};

@class AppController;

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
    if (!image) image = [NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:nil];
    NSImageSymbolConfiguration *config =
        [NSImageSymbolConfiguration configurationWithPointSize:size weight:weight];
    return [image imageWithSymbolConfiguration:config];
}

static NSString *ADBJoinPath(NSString *dir, NSString *name) {
    if ([dir isEqualToString:@"/"]) return [@"/" stringByAppendingString:name];
    return [dir stringByAppendingFormat:@"/%@", name];
}

static NSString *ADBParentPath(NSString *path) {
    NSString *parent = [path stringByDeletingLastPathComponent];
    return parent.length ? parent : @"/";
}

static BOOL ADBPathIsInside(NSString *path, NSString *folder) {
    if ([path isEqualToString:folder]) return YES;
    NSString *prefix = [folder isEqualToString:@"/"] ? folder : [folder stringByAppendingString:@"/"];
    return [path hasPrefix:prefix];
}

// Bytes on disk under a local file or folder (used to show pull progress).
static unsigned long long ADBLocalSize(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) return 0;
    if (!isDir) return [[fm attributesOfItemAtPath:path error:nil] fileSize];

    unsigned long long total = 0;
    NSDirectoryEnumerator *e = [fm enumeratorAtURL:[NSURL fileURLWithPath:path]
                        includingPropertiesForKeys:@[NSURLFileSizeKey]
                                           options:0
                                      errorHandler:nil];
    for (NSURL *url in e) {
        NSNumber *size = nil;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        total += size.unsignedLongLongValue;
    }
    return total;
}

// "name.ext" → "name 2.ext", "name 3.ext"… until nothing with that name exists.
static NSString *ADBUniqueName(NSString *name, BOOL (^exists)(NSString *candidate)) {
    if (!exists(name)) return name;
    NSString *ext = name.pathExtension;
    NSString *base = ext.length && ![name hasPrefix:@"."] ? name.stringByDeletingPathExtension : name;
    if (!ext.length || [name hasPrefix:@"."]) ext = @"";
    for (NSUInteger i = 2; i < 10000; i++) {
        NSString *candidate = [NSString stringWithFormat:@"%@ %lu", base, (unsigned long)i];
        if (ext.length) candidate = [candidate stringByAppendingPathExtension:ext];
        if (!exists(candidate)) return candidate;
    }
    return name;
}

#pragma mark - Media previews

static BOOL ADBIsImageName(NSString *name) {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"gif", @"webp", @"heic", @"heif", @"bmp", @"dng", @"tif", @"tiff"]];
    });
    return [set containsObject:name.pathExtension.lowercaseString];
}

static BOOL ADBIsVideoName(NSString *name) {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSSet setWithArray:@[@"mp4", @"m4v", @"mov", @"3gp"]]; });
    return [set containsObject:name.pathExtension.lowercaseString];
}

static BOOL ADBIsPDFName(NSString *name) {
    return [name.pathExtension.lowercaseString isEqualToString:@"pdf"];
}

static BOOL ADBIsJPEGName(NSString *name) {
    NSString *ext = name.pathExtension.lowercaseString;
    return [ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"];
}

static uint64_t ADBReadBE(const uint8_t *b, int bytes) {
    uint64_t v = 0;
    for (int i = 0; i < bytes; i++) v = (v << 8) | b[i];
    return v;
}

// Finds the first MP4 box of `type` in [start, end) and returns its payload range.
static BOOL ADBFindBox(const uint8_t *b, size_t start, size_t end, const char *type, size_t *payload, size_t *boxEnd) {
    size_t off = start;
    while (off + 8 <= end) {
        uint64_t size = ADBReadBE(b + off, 4);
        size_t header = 8;
        if (size == 1) {
            if (off + 16 > end) return NO;
            size = ADBReadBE(b + off + 8, 8);
            header = 16;
        } else if (size == 0) {
            size = end - off;
        }
        if (size < header || off + size > end) return NO;
        if (memcmp(b + off + 4, type, 4) == 0) {
            *payload = off + header;
            *boxEnd = off + (size_t)size;
            return YES;
        }
        off += (size_t)size;
    }
    return NO;
}

// Where the first video frame lives, from a 'moov' box: file offset and size.
static BOOL ADBFirstVideoSample(NSData *moov, uint64_t *offset, uint64_t *length) {
    const uint8_t *b = moov.bytes;
    size_t end = moov.length, from = 0, p, e;
    while (ADBFindBox(b, from, end, "trak", &p, &e)) {
        from = e;
        size_t mp, me, hp, he, ip, ie, sp, se, xp, xe;
        if (!ADBFindBox(b, p, e, "mdia", &mp, &me)) continue;
        if (!ADBFindBox(b, mp, me, "hdlr", &hp, &he) || he - hp < 12 || memcmp(b + hp + 8, "vide", 4) != 0) continue;
        if (!ADBFindBox(b, mp, me, "minf", &ip, &ie) || !ADBFindBox(b, ip, ie, "stbl", &sp, &se)) continue;
        if (!ADBFindBox(b, sp, se, "stsz", &xp, &xe) || xe - xp < 12) continue;
        uint64_t sampleSize = ADBReadBE(b + xp + 4, 4);
        if (!sampleSize && xe - xp >= 16) sampleSize = ADBReadBE(b + xp + 12, 4);
        uint64_t chunk = 0;
        if (ADBFindBox(b, sp, se, "stco", &xp, &xe) && xe - xp >= 12) {
            chunk = ADBReadBE(b + xp + 8, 4);
        } else if (ADBFindBox(b, sp, se, "co64", &xp, &xe) && xe - xp >= 16) {
            chunk = ADBReadBE(b + xp + 8, 8);
        } else {
            continue;
        }
        if (!sampleSize) continue;
        *offset = chunk;
        *length = sampleSize;
        return YES;
    }
    return NO;
}

static NSString *ADBSHA1(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

// Rotates a CGImage according to an EXIF orientation (1, 3, 6, 8; mirrored ones are rare on phones).
static CGImageRef ADBCreateOrientedImage(CGImageRef image, int orientation) CF_RETURNS_RETAINED;
static CGImageRef ADBCreateOrientedImage(CGImageRef image, int orientation) {
    if (orientation != 3 && orientation != 6 && orientation != 8) return CGImageRetain(image);
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    BOOL swap = orientation != 3;
    size_t ow = swap ? h : w, oh = swap ? w : h;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, ow, oh, 8, 0, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(space);
    if (!ctx) return CGImageRetain(image);
    if (orientation == 3) {
        CGContextTranslateCTM(ctx, ow, oh);
        CGContextRotateCTM(ctx, M_PI);
    } else if (orientation == 6) {
        CGContextTranslateCTM(ctx, 0, oh);
        CGContextRotateCTM(ctx, -M_PI_2);
    } else {
        CGContextTranslateCTM(ctx, ow, 0);
        CGContextRotateCTM(ctx, M_PI_2);
    }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
    CGImageRef result = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return result;
}

// EXIF orientation (tag 0x0112 in IFD0) read straight from an APP1 segment's TIFF data.
static int ADBExifOrientation(const uint8_t *tiff, size_t length) {
    if (length < 8) return 1;
    BOOL little = tiff[0] == 'I';
    uint32_t (^u32)(size_t) = ^uint32_t(size_t o) {
        return little ? (uint32_t)(tiff[o] | tiff[o + 1] << 8 | tiff[o + 2] << 16 | (uint32_t)tiff[o + 3] << 24)
                      : (uint32_t)ADBReadBE(tiff + o, 4);
    };
    uint16_t (^u16)(size_t) = ^uint16_t(size_t o) {
        return little ? (uint16_t)(tiff[o] | tiff[o + 1] << 8) : (uint16_t)ADBReadBE(tiff + o, 2);
    };
    size_t ifd = u32(4);
    if (ifd + 2 > length) return 1;
    uint16_t count = u16(ifd);
    for (uint16_t i = 0; i < count; i++) {
        size_t entry = ifd + 2 + 12 * (size_t)i;
        if (entry + 12 > length) break;
        if (u16(entry) == 0x0112) {
            int value = u16(entry + 8);
            return value >= 1 && value <= 8 ? value : 1;
        }
    }
    return 1;
}

// Camera JPEGs carry a small preview inside their EXIF block, within the first
// few kilobytes. Reading just the head of the file is ~100× cheaper than the photo.
static CGImageRef ADBCreateExifThumbnail(NSData *head) CF_RETURNS_RETAINED;
static CGImageRef ADBCreateExifThumbnail(NSData *head) {
    const uint8_t *b = head.bytes;
    NSUInteger n = head.length;
    if (n < 4 || b[0] != 0xFF || b[1] != 0xD8) return NULL;

    NSUInteger i = 2;
    while (i + 4 <= n && b[i] == 0xFF) {
        uint8_t marker = b[i + 1];
        NSUInteger length = ((NSUInteger)b[i + 2] << 8) | b[i + 3];
        NSUInteger end = MIN(i + 2 + length, n);
        if (marker == 0xE1 && i + 10 <= n && memcmp(b + i + 4, "Exif", 4) == 0) {
            for (NSUInteger s = i + 10; s + 1 < end; s++) {
                if (b[s] != 0xFF || b[s + 1] != 0xD8) continue;
                for (NSUInteger e = s + 2; e + 1 < end; e++) {
                    if (b[e] != 0xFF || b[e + 1] != 0xD9) continue;
                    NSData *jpeg = [head subdataWithRange:NSMakeRange(s, e + 2 - s)];
                    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
                    CGImageRef thumb = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
                    if (src) CFRelease(src);
                    if (!thumb) return NULL;

                    // The preview isn't rotated; the main image's orientation applies.
                    int orientation = ADBExifOrientation(b + i + 10, end - (i + 10));
                    CGImageRef oriented = ADBCreateOrientedImage(thumb, orientation);
                    CGImageRelease(thumb);
                    return oriented;
                }
                return NULL;
            }
            return NULL;
        }
        if (marker == 0xDA) break;
        i += 2 + length;
    }
    return NULL;
}

// First page of a PDF on white, at most `maxPixels` on the long side.
static CGImageRef ADBCreatePDFThumbnail(NSData *data, CGFloat maxPixels) CF_RETURNS_RETAINED;
static CGImageRef ADBCreatePDFThumbnail(NSData *data, CGFloat maxPixels) {
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGPDFDocumentRef doc = provider ? CGPDFDocumentCreateWithProvider(provider) : NULL;
    if (provider) CGDataProviderRelease(provider);
    if (!doc) return NULL;
    CGPDFPageRef page = CGPDFDocumentGetNumberOfPages(doc) ? CGPDFDocumentGetPage(doc, 1) : NULL;
    CGImageRef result = NULL;
    if (page) {
        CGRect box = CGPDFPageGetBoxRect(page, kCGPDFCropBox);
        int rotation = CGPDFPageGetRotationAngle(page) % 180;
        CGFloat w = rotation ? box.size.height : box.size.width, h = rotation ? box.size.width : box.size.height;
        CGFloat scale = maxPixels / MAX(MAX(w, h), 1);
        size_t pw = (size_t)MAX(1, w * scale), ph = (size_t)MAX(1, h * scale);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(NULL, pw, ph, 8, 0, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
        CGColorSpaceRelease(space);
        if (ctx) {
            CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
            CGContextFillRect(ctx, CGRectMake(0, 0, pw, ph));
            CGContextConcatCTM(ctx, CGPDFPageGetDrawingTransform(page, kCGPDFCropBox, CGRectMake(0, 0, pw, ph), 0, true));
            CGContextDrawPDFPage(ctx, page);
            result = CGBitmapContextCreateImage(ctx);
            CGContextRelease(ctx);
        }
    }
    CGPDFDocumentRelease(doc);
    return result;
}

#pragma mark - Model

@interface RemoteItem : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *path;
@property(nonatomic, assign) BOOL directory;
@property(nonatomic, assign) BOOL detailsKnown;
// Folders: number of entries inside (all / not hidden); -1 until counted.
@property(nonatomic, assign) NSInteger childCount;
@property(nonatomic, assign) NSInteger visibleChildCount;
@property(nonatomic, assign) unsigned long long size;
@property(nonatomic, strong) NSDate *modified;
@property(nonatomic, readonly) BOOL hidden;
@property(nonatomic, readonly) UTType *contentType;
@property(nonatomic, readonly) NSString *kind;
@end

@implementation RemoteItem

- (instancetype)init {
    self = [super init];
    if (self) {
        _childCount = -1;
        _visibleChildCount = -1;
    }
    return self;
}

- (BOOL)hidden {
    return [self.name hasPrefix:@"."];
}

- (UTType *)contentType {
    if (self.directory) return UTTypeFolder;
    NSString *ext = self.name.pathExtension;
    UTType *type = ext.length ? [UTType typeWithFilenameExtension:ext] : nil;
    if (type.dynamic) type = nil;
    return type ?: UTTypeData;
}

- (NSString *)kind {
    if (self.directory) return @"Folder";
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });

    NSString *ext = self.name.pathExtension.lowercaseString;
    NSString *kind = [cache objectForKey:ext];
    if (!kind) {
        if ([ext isEqualToString:@"apk"]) {
            kind = @"Android app";
        } else {
            UTType *type = self.contentType;
            kind = (type == UTTypeData || !type.localizedDescription.length)
                ? (ext.length ? [NSString stringWithFormat:@"%@ file", ext.uppercaseString] : @"Document")
                : type.localizedDescription;
            kind = [[kind substringToIndex:1].uppercaseString stringByAppendingString:[kind substringFromIndex:1]];
        }
        [cache setObject:kind forKey:ext];
    }
    return kind;
}

@end

static NSImage *ADBIconForItem(RemoteItem *item) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });

    UTType *type = item.contentType;
    NSImage *icon = [cache objectForKey:type.identifier];
    if (!icon) {
        icon = [[NSWorkspace sharedWorkspace] iconForContentType:type];
        [cache setObject:icon forKey:type.identifier];
    }
    return icon;
}

#pragma mark - Small helpers

// Shared between a transfer and the thread polling its progress.
@interface ADBFlag : NSObject
@property(atomic, assign) BOOL value;
@end

@implementation ADBFlag
@end

// A drag from the file list: a file promise for Finder plus the remote path, so a drag
// inside the window can be turned into a move on the device.
@interface RemoteFilePromiseProvider : NSFilePromiseProvider
@property(nonatomic, strong) RemoteItem *item;
@end

@implementation RemoteFilePromiseProvider

- (NSArray<NSPasteboardType> *)writableTypesForPasteboard:(NSPasteboard *)pasteboard {
    return [[super writableTypesForPasteboard:pasteboard] arrayByAddingObject:kRemotePathType];
}

- (NSPasteboardWritingOptions)writingOptionsForType:(NSPasteboardType)type pasteboard:(NSPasteboard *)pasteboard {
    if ([type isEqualToString:kRemotePathType]) return 0;
    return [super writingOptionsForType:type pasteboard:pasteboard];
}

- (id)pasteboardPropertyListForType:(NSPasteboardType)type {
    if ([type isEqualToString:kRemotePathType]) return self.item.path;
    return [super pasteboardPropertyListForType:type];
}

@end

// One page in Quick Look: a local copy of a file, or a summary page for a folder.
@interface PreviewEntry : NSObject <QLPreviewItem>
@property(nonatomic, strong) NSURL *url;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *path;  // on the phone, to find the item's icon for the zoom
@end

@implementation PreviewEntry

- (NSURL *)previewItemURL {
    return self.url;
}

- (NSString *)previewItemTitle {
    return self.title;
}

- (BOOL)isEqual:(id)other {
    return [other isKindOfClass:PreviewEntry.class] && [self.url isEqual:((PreviewEntry *)other).url] &&
           [self.title isEqualToString:((PreviewEntry *)other).title];
}

- (NSUInteger)hash {
    return self.url.hash;
}

@end

// A label that can act as a link (the transfer summary opens the list of files).
@interface LinkLabel : NSTextField
@property(nonatomic, copy) void (^clickHandler)(void);
@end

@interface FileTableView : NSTableView
@property(nonatomic, weak) AppController *controller;
@property(nonatomic, assign) BOOL columnTable;
@end

@interface IconCollectionView : NSCollectionView
@property(nonatomic, weak) AppController *controller;
@end

@interface IconItemView : NSView
@property(nonatomic, weak) AppController *controller;
@property(nonatomic, strong) RemoteItem *item;
@property(nonatomic, assign) BOOL selected;
@property(nonatomic, strong) NSImageView *iconView;
@property(nonatomic, strong) NSTextField *label;
@property(nonatomic, strong) NSTextField *info;
@end

@interface IconItem : NSCollectionViewItem
@end

@interface EmptyStateView : NSView
@property(nonatomic, strong) NSImageView *iconView;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *subtitleLabel;
- (void)setSymbol:(NSString *)symbol title:(NSString *)title subtitle:(NSString *)subtitle;
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

@interface AppController : NSObject <NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate,
                                     NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate,
                                     NSCollectionViewDataSource, NSCollectionViewDelegate,
                                     NSMenuItemValidation, NSToolbarItemValidation, NSMenuDelegate,
                                     NSFilePromiseProviderDelegate,
                                     QLPreviewPanelDataSource, QLPreviewPanelDelegate>
@property(nonatomic, strong) NSWindow *window;

// Sidebar.
@property(nonatomic, strong) NSTableView *sidebar;
@property(nonatomic, strong) NSArray<NSDictionary *> *sidebarRows;
@property(nonatomic, assign) BOOL updatingSidebar;
@property(nonatomic, strong) NSView *storageCard;
@property(nonatomic, strong) NSTextField *storageLabel;
@property(nonatomic, strong) NSProgressIndicator *storageBar;

// File list.
@property(nonatomic, strong) FileTableView *table;
@property(nonatomic, strong) NSScrollView *tableScroll;
@property(nonatomic, strong) EmptyStateView *emptyView;
@property(nonatomic, strong) NSArray<RemoteItem *> *allItems;
@property(nonatomic, strong) NSArray<RemoteItem *> *items;
@property(nonatomic, copy) NSString *currentPath;
@property(nonatomic, copy) NSString *loadError;
@property(nonatomic, assign) BOOL loading;
@property(nonatomic, assign) NSUInteger listGeneration;
@property(nonatomic, strong) NSMutableArray<NSString *> *backStack;
@property(nonatomic, strong) NSMutableArray<NSString *> *forwardStack;
@property(nonatomic, copy) NSString *filterText;
@property(nonatomic, assign) BOOL showHidden;
@property(nonatomic, copy) NSString *renamingPath;
@property(nonatomic, copy) NSString *pendingRenamePath;
@property(nonatomic, strong) NSDateFormatter *dateFormatter;

// View modes.
@property(nonatomic, assign) ADBViewMode viewMode;
@property(nonatomic, strong) IconCollectionView *collection;
@property(nonatomic, strong) NSScrollView *collectionScroll;
@property(nonatomic, strong) NSScrollView *columnScroll;
@property(nonatomic, strong) NSView *columnDoc;
@property(nonatomic, strong) NSLayoutConstraint *columnContentWidth;
@property(nonatomic, strong) NSLayoutConstraint *previewLeading;
@property(nonatomic, strong) NSMutableSet<NSString *> *staleListings;
@property(nonatomic, strong) NSMutableArray<FileTableView *> *columnTables;
@property(nonatomic, strong) NSMutableArray<NSView *> *columnUnits;
@property(nonatomic, strong) NSArray<NSString *> *columnPaths;
@property(nonatomic, strong) NSArray<NSArray<RemoteItem *> *> *columnItems;
@property(nonatomic, assign) BOOL updatingColumns;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSArray<RemoteItem *> *> *listingCache;
@property(nonatomic, strong) NSMutableSet<NSString *> *listingPending;
@property(nonatomic, strong) NSView *previewPane;
@property(nonatomic, strong) NSImageView *previewImage;
@property(nonatomic, strong) NSTextField *previewName;
@property(nonatomic, strong) NSTextField *previewInfo;
@property(nonatomic, strong) RemoteItem *previewItem;

// Thumbnails.
@property(nonatomic, strong) NSCache<NSString *, id> *thumbCache;
@property(nonatomic, strong) NSMutableSet<NSString *> *thumbPending;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *thumbStack;
@property(nonatomic, assign) NSUInteger thumbWorkers;

// Toolbar.
@property(nonatomic, strong) NSSegmentedControl *navControl;
@property(nonatomic, strong) NSSegmentedControl *viewControl;
@property(nonatomic, strong) NSSearchField *searchField;

// Bottom bars.
@property(nonatomic, strong) NSPathControl *pathControl;
@property(nonatomic, strong) NSArray<NSString *> *pathControlPaths;
@property(nonatomic, strong) NSTextField *infoLabel;
@property(nonatomic, strong) NSView *transferBar;
@property(nonatomic, strong) NSImageView *transferIcon;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) LinkLabel *detailLabel;
@property(nonatomic, strong) NSProgressIndicator *progress;
@property(nonatomic, strong) NSButton *cancelButton;
@property(nonatomic, strong) NSButton *closeBarButton;
@property(nonatomic, strong) NSTimer *hideBarTimer;

// Device.
@property(nonatomic, copy) NSString *serial;
@property(nonatomic, strong) NSArray<NSDictionary *> *devices;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *deviceInfo;
@property(nonatomic, copy) NSString *deviceState;
@property(nonatomic, strong) NSTimer *deviceTimer;
@property(nonatomic, assign) BOOL deviceRefreshRunning;
@property(nonatomic, assign) BOOL deviceRefreshQueued;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *reconnectAttempts;
@property(atomic, strong) NSDate *adbServerRestartedAt;

// Transfers.
@property(nonatomic, strong) NSArray<NSDictionary *> *lastResults;
@property(nonatomic, copy) NSString *lastResultsTitle;
@property(nonatomic, strong) ResultsController *resultsController;
@property(nonatomic, assign) BOOL transferring;
@property(nonatomic, assign) NSUInteger pullsActive;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *pendingDrops;
@property(nonatomic, strong) NSArray<NSURL *> *launchURLs;
@property(nonatomic, strong) id activity;
@property(nonatomic, copy) NSString *cachedADBPath;
@property(nonatomic, strong) dispatch_queue_t logQueue;
@property(nonatomic, strong) NSOperationQueue *pullQueue;

// Quick Look.
@property(nonatomic, strong) NSArray<PreviewEntry *> *previewURLs;
@property(nonatomic, strong) NSPanel *folderPanel;
@property(nonatomic, strong) NSTextField *folderPanelName;
@property(nonatomic, strong) NSTextField *folderPanelSize;
@property(nonatomic, strong) NSTextField *folderPanelDate;
@property(nonatomic, strong) RemoteItem *folderPanelItem;
@property(nonatomic, assign) NSUInteger folderZoomGeneration;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *folderStats;
@property(nonatomic, strong) NSMutableSet<NSString *> *folderStatsPending;
@property(nonatomic, strong) NSMutableArray<NSWindow *> *infoWindows;
@property(nonatomic, strong) NSArray<NSString *> *previewPaths;
@property(nonatomic, assign) NSUInteger previewGeneration;

// Touched from transfer threads and from the main thread (Cancel / Quit).
@property(atomic, assign) BOOL cancelRequested;
@property(atomic, assign) BOOL pullCancelRequested;
@property(atomic, assign) pid_t activePid;
@property(atomic, assign) pid_t pullPid;
@property(atomic, copy) NSString *activeRemote;

- (void)openSelection:(id)sender;
- (void)renameSelection:(id)sender;
- (void)quickLook:(id)sender;
- (NSMenu *)contextMenu;
- (BOOL)previewAvailable;
- (void)openItems:(NSArray<RemoteItem *> *)items;
- (void)fileViewSelectionChanged;
- (BOOL)closePreviews;
- (BOOL)handleColumnKey:(NSEvent *)event table:(FileTableView *)table;
- (NSImage *)thumbnailForItem:(RemoteItem *)item request:(BOOL)request;
- (NSString *)countTextForItem:(RemoteItem *)item;
@end

#pragma mark - FileTableView

@implementation FileTableView

- (void)keyDown:(NSEvent *)event {
    NSString *chars = event.charactersIgnoringModifiers;
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL plain = (flags & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl)) == 0;

    if (chars.length == 1 && plain) {
        unichar c = [chars characterAtIndex:0];
        if (c == '\r' || c == 3) {
            // Return renames, like in Finder.
            [self.controller renameSelection:nil];
            return;
        }
        if (c == ' ') {
            [self.controller quickLook:nil];
            return;
        }
        if (c == 27 && [self.controller closePreviews]) return;
    }
    if (self.columnTable && [self.controller handleColumnKey:event table:self]) return;
    [super keyDown:event];
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:p];
    [self.window makeFirstResponder:self];
    if (row < 0) {
        [self deselectAll:nil];
    } else if (![self.selectedRowIndexes containsIndex:(NSUInteger)row]) {
        [self selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    }
    return [self.controller contextMenu];
}

- (BOOL)acceptsPreviewPanelControl:(QLPreviewPanel *)panel {
    (void)panel;
    return YES;
}

- (void)beginPreviewPanelControl:(QLPreviewPanel *)panel {
    panel.dataSource = self.controller;
    panel.delegate = self.controller;
}

- (void)endPreviewPanelControl:(QLPreviewPanel *)panel {
    panel.dataSource = nil;
    panel.delegate = nil;
}

@end

#pragma mark - Icon view

@implementation IconItemView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _iconView = [NSImageView new];
        _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
        _iconView.wantsLayer = YES;
        _iconView.layer.cornerRadius = 7;
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;

        _label = [NSTextField wrappingLabelWithString:@""];
        _label.font = [NSFont systemFontOfSize:12];
        _label.alignment = NSTextAlignmentCenter;
        _label.selectable = NO;
        _label.maximumNumberOfLines = 2;
        _label.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _label.cell.truncatesLastVisibleLine = YES;
        _label.wantsLayer = YES;
        _label.layer.cornerRadius = 4;
        _label.translatesAutoresizingMaskIntoConstraints = NO;

        // Like Finder's "Show item info": how many items a folder holds.
        _info = [NSTextField labelWithString:@""];
        _info.font = [NSFont systemFontOfSize:11];
        _info.textColor = NSColor.systemBlueColor;
        _info.alignment = NSTextAlignmentCenter;
        _info.translatesAutoresizingMaskIntoConstraints = NO;

        [self addSubview:_iconView];
        [self addSubview:_label];
        [self addSubview:_info];
        [NSLayoutConstraint activateConstraints:@[
            [_info.topAnchor constraintEqualToAnchor:_label.bottomAnchor constant:1],
            [_info.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_info.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor constant:-6],
            [_iconView.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
            [_iconView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:80],
            [_iconView.heightAnchor constraintEqualToConstant:80],
            [_label.topAnchor constraintEqualToAnchor:_iconView.bottomAnchor constant:4],
            [_label.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_label.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor constant:-6],
        ]];
    }
    return self;
}

- (void)setItem:(RemoteItem *)item {
    _item = item;
    self.label.stringValue = item.name ?: @"";
    self.label.toolTip = item.name;
    self.alphaValue = item.hidden ? 0.55 : 1.0;
    self.info.stringValue = [self.controller countTextForItem:item] ?: @"";
    [self updateImage];
}

- (void)updateImage {
    NSImage *thumb = [self.controller thumbnailForItem:self.item request:YES];
    self.iconView.image = thumb ?: ADBIconForItem(self.item);
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    [self updateLayer];
    [self setNeedsDisplay:YES];
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.iconView.layer.backgroundColor = self.selected ? NSColor.quaternaryLabelColor.CGColor : NSColor.clearColor.CGColor;
        BOOL key = self.window.isKeyWindow && [self.window.firstResponder isKindOfClass:NSCollectionView.class];
        NSColor *fill = key ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor;
        self.label.layer.backgroundColor = self.selected ? fill.CGColor : NSColor.clearColor.CGColor;
        self.label.textColor = self.selected && key ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor;
    }];
}

- (NSView *)hitTest:(NSPoint)point {
    return [super hitTest:point] ? self : nil;
}

- (void)mouseDown:(NSEvent *)event {
    [super mouseDown:event];
    if (event.clickCount == 2 && self.item) [self.controller openItems:@[self.item]];
}

@end

@implementation IconItem

- (void)loadView {
    self.view = [[IconItemView alloc] initWithFrame:NSMakeRect(0, 0, 112, 138)];
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    ((IconItemView *)self.view).selected = selected;
}

@end

@implementation IconCollectionView

- (void)keyDown:(NSEvent *)event {
    NSString *chars = event.charactersIgnoringModifiers;
    // Arrow keys move the selection ourselves: NSCollectionView keeps its own "current
    // item", which selections made in code (after Back, a rename, opening a folder…)
    // don't update, so its arrows would stop or jump to the first item. Shift keeps
    // the built-in behaviour for extending a selection.
    NSEventModifierFlags arrowFlags = event.modifierFlags & (NSEventModifierFlagShift | NSEventModifierFlagCommand |
                                                             NSEventModifierFlagOption | NSEventModifierFlagControl);
    NSInteger count = [self numberOfItemsInSection:0];
    if (chars.length == 1 && !arrowFlags && count > 0) {
        unichar k = [chars characterAtIndex:0];
        NSInteger step = 0;
        NSCollectionViewFlowLayout *flow = (NSCollectionViewFlowLayout *)self.collectionViewLayout;
        CGFloat usable = self.bounds.size.width - flow.sectionInset.left - flow.sectionInset.right + flow.minimumInteritemSpacing;
        NSInteger perRow = MAX(1, (NSInteger)floor(usable / (flow.itemSize.width + flow.minimumInteritemSpacing)));
        if (k == NSRightArrowFunctionKey) step = 1;
        else if (k == NSLeftArrowFunctionKey) step = -1;
        else if (k == NSDownArrowFunctionKey) step = perRow;
        else if (k == NSUpArrowFunctionKey) step = -perRow;
        if (step) {
            NSInteger current = -1;
            for (NSIndexPath *p in self.selectionIndexPaths) current = MAX(current, (NSInteger)p.item);
            if (step < 0) {
                current = NSIntegerMax;
                for (NSIndexPath *p in self.selectionIndexPaths) current = MIN(current, (NSInteger)p.item);
                if (current == NSIntegerMax) current = -1;
            }
            NSInteger next = current < 0 ? 0 : MIN(MAX(current + step, 0), count - 1);
            NSIndexPath *path = [NSIndexPath indexPathForItem:next inSection:0];
            self.selectionIndexPaths = [NSSet setWithObject:path];
            [self scrollToItemsAtIndexPaths:[NSSet setWithObject:path] scrollPosition:NSCollectionViewScrollPositionNearestHorizontalEdge];
            [self.controller fileViewSelectionChanged];
            return;
        }
    }
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL plain = (flags & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl)) == 0;
    if (chars.length == 1 && plain) {
        unichar c = [chars characterAtIndex:0];
        if (c == '\r' || c == 3) {
            [self.controller renameSelection:nil];
            return;
        }
        if (c == ' ') {
            [self.controller quickLook:nil];
            return;
        }
        if (c == 27 && [self.controller closePreviews]) return;
    }
    [super keyDown:event];
}

- (BOOL)becomeFirstResponder {
    BOOL ok = [super becomeFirstResponder];
    for (NSCollectionViewItem *item in self.visibleItems) [item.view setNeedsDisplay:YES];
    return ok;
}

- (BOOL)resignFirstResponder {
    BOOL ok = [super resignFirstResponder];
    for (NSCollectionViewItem *item in self.visibleItems) [item.view setNeedsDisplay:YES];
    return ok;
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSIndexPath *path = [self indexPathForItemAtPoint:p];
    if (!path) {
        self.selectionIndexPaths = [NSSet set];
    } else if (![self.selectionIndexPaths containsObject:path]) {
        self.selectionIndexPaths = [NSSet setWithObject:path];
    }
    [self.controller fileViewSelectionChanged];
    return [self.controller contextMenu];
}

- (BOOL)acceptsPreviewPanelControl:(QLPreviewPanel *)panel {
    (void)panel;
    return YES;
}

- (void)beginPreviewPanelControl:(QLPreviewPanel *)panel {
    panel.dataSource = self.controller;
    panel.delegate = self.controller;
}

- (void)endPreviewPanelControl:(QLPreviewPanel *)panel {
    panel.dataSource = nil;
    panel.delegate = nil;
}

@end

#pragma mark - EmptyStateView

@implementation EmptyStateView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _iconView = [NSImageView new];
        _iconView.contentTintColor = NSColor.tertiaryLabelColor;
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;

        _titleLabel = [NSTextField labelWithString:@""];
        _titleLabel.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
        _titleLabel.textColor = NSColor.secondaryLabelColor;
        _titleLabel.alignment = NSTextAlignmentCenter;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _subtitleLabel = [NSTextField wrappingLabelWithString:@""];
        _subtitleLabel.font = [NSFont systemFontOfSize:13];
        _subtitleLabel.textColor = NSColor.tertiaryLabelColor;
        _subtitleLabel.alignment = NSTextAlignmentCenter;
        _subtitleLabel.selectable = NO;
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _subtitleLabel.preferredMaxLayoutWidth = 360;

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
            [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:24],
            [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-24],
            [_subtitleLabel.widthAnchor constraintLessThanOrEqualToConstant:360],
        ]];
    }
    return self;
}

- (void)setSymbol:(NSString *)symbol title:(NSString *)title subtitle:(NSString *)subtitle {
    self.iconView.image = symbol ? ADBSymbol(symbol, 46, NSFontWeightLight) : nil;
    self.iconView.hidden = symbol == nil;
    self.titleLabel.stringValue = title ?: @"";
    self.subtitleLabel.stringValue = subtitle ?: @"";
    self.subtitleLabel.hidden = !subtitle.length;
}

// Clicks and drops go through to the table underneath.
- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

@end

#pragma mark - AppController

@implementation AppController

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    self.logQueue = dispatch_queue_create("adbfinder.log", DISPATCH_QUEUE_SERIAL);
    self.deviceInfo = [NSMutableDictionary dictionary];
    self.pendingDrops = [NSMutableArray array];
    self.backStack = [NSMutableArray array];
    self.forwardStack = [NSMutableArray array];
    self.devices = @[];
    self.allItems = @[];
    self.items = @[];
    self.showHidden = [NSUserDefaults.standardUserDefaults boolForKey:kShowHiddenKey];
    // Icons (with media previews) unless the user picked something else.
    NSNumber *mode = [NSUserDefaults.standardUserDefaults objectForKey:kViewModeKey];
    self.viewMode = mode ? (ADBViewMode)MIN(MAX(mode.integerValue, 0), 2) : ADBViewModeIcons;
    self.listingCache = [NSMutableDictionary dictionary];
    self.listingPending = [NSMutableSet set];
    self.staleListings = [NSMutableSet set];
    self.columnTables = [NSMutableArray array];
    self.columnUnits = [NSMutableArray array];
    self.columnPaths = @[];
    self.columnItems = @[];

    self.thumbCache = [NSCache new];
    self.thumbCache.totalCostLimit = 256 * 1024 * 1024;
    self.thumbPending = [NSMutableSet set];
    self.thumbStack = [NSMutableArray array];
    self.folderStats = [NSMutableDictionary dictionary];
    self.folderStatsPending = [NSMutableSet set];
    self.infoWindows = [NSMutableArray array];
    self.reconnectAttempts = [NSMutableDictionary dictionary];
    [self pruneThumbnailCache];

    self.pullQueue = [NSOperationQueue new];
    self.pullQueue.maxConcurrentOperationCount = 1;
    self.pullQueue.qualityOfService = NSQualityOfServiceUserInitiated;
    self.pullQueue.name = @"adbfinder.pull";

    self.dateFormatter = [NSDateFormatter new];
    self.dateFormatter.dateStyle = NSDateFormatterMediumStyle;
    self.dateFormatter.timeStyle = NSDateFormatterShortStyle;
    self.dateFormatter.doesRelativeDateFormatting = YES;

    // Files opened from the device are pulled here; nothing in it outlives a session.
    [[NSFileManager defaultManager] removeItemAtPath:[self cacheDirectory] error:nil];

    [self buildMenu];
    [self buildUI];

    // While a preview is open, Space and Escape close it whatever has the keyboard
    // focus in the window (except while typing in a text field).
    __weak AppController *weakSelf = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        AppController *me = weakSelf;
        BOOL previewOpen = me.folderPanel.visible ||
                           ([QLPreviewPanel sharedPreviewPanelExists] && [QLPreviewPanel sharedPreviewPanel].visible);
        if (!me || !previewOpen) return event;
        NSEventModifierFlags mods = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl);
        if (mods || [event.window.firstResponder isKindOfClass:NSTextView.class]) return event;
        if (event.keyCode == 49 || event.keyCode == 53) {  // Space, Escape
            [me closePreviews];
            return nil;
        }
        return event;
    }];
    [self updateEmptyState];
    [self refreshDevice];

    self.deviceTimer =
        [NSTimer scheduledTimerWithTimeInterval:2.0
                                         target:self
                                       selector:@selector(deviceTimerTick:)
                                       userInfo:nil
                                        repeats:YES];
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    (void)application;
    // Files dropped on the Dock icon go to the folder that is open.
    if (!self.window || !self.currentPath) {
        self.launchURLs = [(self.launchURLs ?: @[]) arrayByAddingObjectsFromArray:urls];
        return;
    }
    [self uploadURLs:urls toFolder:self.currentPath];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    if (!self.transferring && !self.pullsActive) return NSTerminateNow;

    NSAlert *alert = [NSAlert new];
    alert.messageText = @"A transfer is in progress";
    alert.informativeText = @"Quitting stops it. Files that were already copied are kept.";
    [alert addButtonWithTitle:@"Keep Copying"];
    [alert addButtonWithTitle:@"Stop and Quit"];

    if ([alert runModal] != NSAlertSecondButtonReturn) {
        return NSTerminateCancel;
    }

    [self.pendingDrops removeAllObjects];
    self.cancelRequested = YES;
    self.pullCancelRequested = YES;
    pid_t pid = self.activePid;
    if (pid > 0) kill(pid, SIGTERM);
    pid = self.pullPid;
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
    [[NSFileManager defaultManager] removeItemAtPath:[self cacheDirectory] error:nil];
}

#pragma mark Menu

- (NSMenuItem *)itemWithTitle:(NSString *)title action:(SEL)action key:(NSString *)key target:(id)target {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key ?: @""];
    item.target = target;
    return item;
}

- (NSMenuItem *)itemWithTitle:(NSString *)title action:(SEL)action key:(NSString *)key
                    modifiers:(NSEventModifierFlags)modifiers target:(id)target {
    NSMenuItem *item = [self itemWithTitle:title action:action key:key target:target];
    item.keyEquivalentModifierMask = modifiers;
    return item;
}

- (void)buildMenu {
    NSMenu *main = [[NSMenu alloc] initWithTitle:@"Main Menu"];
    const NSEventModifierFlags cmd = NSEventModifierFlagCommand;
    const NSEventModifierFlags cmdShift = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    const NSEventModifierFlags cmdOption = NSEventModifierFlagCommand | NSEventModifierFlagOption;

    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:kAppName action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:kAppName];
    [appMenu addItem:[self itemWithTitle:@"About ADB Finder" action:@selector(orderFrontStandardAboutPanel:) key:nil target:nil]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[self itemWithTitle:@"Hide ADB Finder" action:@selector(hide:) key:@"h" target:nil]];
    [appMenu addItem:[self itemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) key:@"h" modifiers:cmdOption target:nil]];
    [appMenu addItem:[self itemWithTitle:@"Show All" action:@selector(unhideAllApplications:) key:nil target:nil]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[self itemWithTitle:@"Quit ADB Finder" action:@selector(terminate:) key:@"q" target:nil]];
    appItem.submenu = appMenu;
    [main addItem:appItem];

    NSString *down = [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey];
    NSString *up = [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey];
    NSString *backspace = [NSString stringWithFormat:@"%C", (unichar)NSBackspaceCharacter];

    NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
    NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
    [file addItem:[self itemWithTitle:@"New Folder" action:@selector(newFolder:) key:@"n" modifiers:cmdShift target:self]];
    [file addItem:[self itemWithTitle:@"Open" action:@selector(openSelection:) key:down modifiers:cmd target:self]];
    [file addItem:[self itemWithTitle:@"Quick Look" action:@selector(quickLook:) key:@"y" target:self]];
    [file addItem:[self itemWithTitle:@"Get Info" action:@selector(getInfo:) key:@"i" target:self]];
    [file addItem:[NSMenuItem separatorItem]];
    [file addItem:[self itemWithTitle:@"Upload to Device…" action:@selector(uploadFiles:) key:@"u" modifiers:cmdShift target:self]];
    [file addItem:[self itemWithTitle:@"Download to Mac…" action:@selector(downloadSelection:) key:@"d" modifiers:cmdShift target:self]];
    [file addItem:[NSMenuItem separatorItem]];
    [file addItem:[self itemWithTitle:@"Rename" action:@selector(renameSelection:) key:nil target:self]];
    [file addItem:[self itemWithTitle:@"Duplicate" action:@selector(duplicateSelection:) key:@"d" target:self]];
    [file addItem:[self itemWithTitle:@"Delete…" action:@selector(deleteSelection:) key:backspace modifiers:cmd target:self]];
    [file addItem:[self itemWithTitle:@"Copy Path" action:@selector(copyPath:) key:@"c" modifiers:cmdOption target:self]];
    [file addItem:[NSMenuItem separatorItem]];
    [file addItem:[self itemWithTitle:@"Show Last Transfer" action:@selector(showResults:) key:@"r" modifiers:cmdOption target:self]];
    [file addItem:[self itemWithTitle:@"Show Log" action:@selector(showLog:) key:@"l" modifiers:cmdOption target:self]];
    [file addItem:[NSMenuItem separatorItem]];
    [file addItem:[self itemWithTitle:@"Close Window" action:@selector(performClose:) key:@"w" target:nil]];
    fileItem.submenu = file;
    [main addItem:fileItem];

    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit addItem:[self itemWithTitle:@"Undo" action:@selector(undo:) key:@"z" target:nil]];
    [edit addItem:[self itemWithTitle:@"Redo" action:@selector(redo:) key:@"z" modifiers:cmdShift target:nil]];
    [edit addItem:[NSMenuItem separatorItem]];
    [edit addItem:[self itemWithTitle:@"Cut" action:@selector(cut:) key:@"x" target:nil]];
    [edit addItem:[self itemWithTitle:@"Copy" action:@selector(copy:) key:@"c" target:nil]];
    [edit addItem:[self itemWithTitle:@"Paste" action:@selector(paste:) key:@"v" target:nil]];
    [edit addItem:[self itemWithTitle:@"Select All" action:@selector(selectAll:) key:@"a" target:nil]];
    [edit addItem:[NSMenuItem separatorItem]];
    [edit addItem:[self itemWithTitle:@"Find" action:@selector(focusSearch:) key:@"f" target:self]];
    editItem.submenu = edit;
    [main addItem:editItem];

    NSMenuItem *viewItem = [[NSMenuItem alloc] initWithTitle:@"View" action:nil keyEquivalent:@""];
    NSMenu *view = [[NSMenu alloc] initWithTitle:@"View"];
    NSArray *modes = @[@"as Icons", @"as List", @"as Columns"];
    for (NSUInteger i = 0; i < modes.count; i++) {
        NSMenuItem *item = [self itemWithTitle:modes[i] action:@selector(setViewModeFromMenu:)
                                           key:[NSString stringWithFormat:@"%lu", (unsigned long)i + 1] target:self];
        item.tag = (NSInteger)i;
        [view addItem:item];
    }
    [view addItem:[NSMenuItem separatorItem]];
    NSMenuItem *sortItem = [[NSMenuItem alloc] initWithTitle:@"Sort By" action:nil keyEquivalent:@""];
    NSMenu *sortMenu = [[NSMenu alloc] initWithTitle:@"Sort By"];
    NSArray *sorts = @[@[@"Name", @"name"], @[@"Kind", @"kind"], @[@"Date Modified", @"modified"], @[@"Size", @"size"]];
    for (NSUInteger i = 0; i < sorts.count; i++) {
        NSMenuItem *item = [self itemWithTitle:sorts[i][0] action:@selector(sortByMenu:)
                                           key:[NSString stringWithFormat:@"%lu", (unsigned long)i + 1]
                                     modifiers:NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl
                                        target:self];
        item.representedObject = sorts[i][1];
        [sortMenu addItem:item];
    }
    sortItem.submenu = sortMenu;
    [view addItem:sortItem];
    [view addItem:[NSMenuItem separatorItem]];
    [view addItem:[self itemWithTitle:@"Show Hidden Files" action:@selector(toggleHidden:) key:@"." modifiers:cmdShift target:self]];
    [view addItem:[self itemWithTitle:@"Refresh" action:@selector(refresh:) key:@"r" target:self]];
    [view addItem:[NSMenuItem separatorItem]];
    [view addItem:[self itemWithTitle:@"Show Sidebar" action:@selector(toggleSidebar:) key:@"s" modifiers:cmdOption|NSEventModifierFlagControl target:nil]];
    viewItem.submenu = view;
    [main addItem:viewItem];

    NSMenuItem *goItem = [[NSMenuItem alloc] initWithTitle:@"Go" action:nil keyEquivalent:@""];
    NSMenu *go = [[NSMenu alloc] initWithTitle:@"Go"];
    [go addItem:[self itemWithTitle:@"Back" action:@selector(goBack:) key:@"[" target:self]];
    [go addItem:[self itemWithTitle:@"Forward" action:@selector(goForward:) key:@"]" target:self]];
    [go addItem:[self itemWithTitle:@"Enclosing Folder" action:@selector(goUp:) key:up modifiers:cmd target:self]];
    [go addItem:[NSMenuItem separatorItem]];
    NSArray *places = @[@[@"Internal Storage", kStorageRoot, @"h"], @[@"Download", @"/sdcard/Download", @"l"],
                        @[@"Camera (DCIM)", @"/sdcard/DCIM", @"c"], @[@"Documents", @"/sdcard/Documents", @"o"]];
    for (NSArray *place in places) {
        NSMenuItem *item = [self itemWithTitle:place[0] action:@selector(goToPlace:) key:place[2] modifiers:cmdShift target:self];
        item.representedObject = place[1];
        [go addItem:item];
    }
    [go addItem:[NSMenuItem separatorItem]];
    [go addItem:[self itemWithTitle:@"Go to Folder…" action:@selector(goToFolder:) key:@"g" modifiers:cmdShift target:self]];
    goItem.submenu = go;
    [main addItem:goItem];

    NSMenuItem *windowItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItem:[self itemWithTitle:@"Minimize" action:@selector(performMiniaturize:) key:@"m" target:nil]];
    [windowMenu addItem:[self itemWithTitle:@"Zoom" action:@selector(performZoom:) key:nil target:nil]];
    windowItem.submenu = windowMenu;
    [main addItem:windowItem];
    NSApp.windowsMenu = windowMenu;

    [NSApp setMainMenu:main];
}

- (NSMenu *)contextMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    NSArray<RemoteItem *> *selected = [self selectedItems];

    if (selected.count) {
        [menu addItem:[self itemWithTitle:@"Open" action:@selector(openSelection:) key:nil target:self]];
        [menu addItem:[self itemWithTitle:@"Quick Look" action:@selector(quickLook:) key:nil target:self]];
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItem:[self itemWithTitle:@"Download to Mac…" action:@selector(downloadSelection:) key:nil target:self]];
        [menu addItem:[self itemWithTitle:@"Download to Downloads" action:@selector(downloadToDownloads:) key:nil target:self]];
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItem:[self itemWithTitle:@"Get Info" action:@selector(getInfo:) key:nil target:self]];
        [menu addItem:[self itemWithTitle:@"Rename" action:@selector(renameSelection:) key:nil target:self]];
        [menu addItem:[self itemWithTitle:@"Duplicate" action:@selector(duplicateSelection:) key:nil target:self]];
        [menu addItem:[self itemWithTitle:@"Copy" action:@selector(copy:) key:nil target:self]];
        [menu addItem:[self itemWithTitle:@"Copy Path" action:@selector(copyPath:) key:nil target:self]];
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItem:[self itemWithTitle:@"Delete…" action:@selector(deleteSelection:) key:nil target:self]];
    } else {
        [menu addItem:[self itemWithTitle:@"New Folder" action:@selector(newFolder:) key:nil target:self]];
        [menu addItem:[self itemWithTitle:@"Upload to Device…" action:@selector(uploadFiles:) key:nil target:self]];
        [menu addItem:[self itemWithTitle:@"Paste" action:@selector(paste:) key:nil target:self]];
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItem:[self itemWithTitle:@"Refresh" action:@selector(refresh:) key:nil target:self]];
        [menu addItem:[self itemWithTitle:self.showHidden ? @"Hide Hidden Files" : @"Show Hidden Files"
                                   action:@selector(toggleHidden:) key:nil target:self]];
    }
    return menu;
}

- (BOOL)canBrowse {
    return self.serial.length > 0 && self.currentPath.length > 0;
}

- (BOOL)validateAction:(SEL)action {
    NSUInteger selected = [self selectedItems].count;
    BOOL browse = [self canBrowse];

    if (action == @selector(newFolder:) || action == @selector(uploadFiles:) ||
        action == @selector(refresh:) || action == @selector(goToFolder:) || action == @selector(goToPlace:)) {
        return self.serial.length > 0 && (browse || action == @selector(goToPlace:) || action == @selector(goToFolder:));
    }
    if (action == @selector(openSelection:) || action == @selector(downloadSelection:) ||
        action == @selector(downloadToDownloads:) || action == @selector(deleteSelection:) ||
        action == @selector(copyPath:) || action == @selector(copy:) || action == @selector(getInfo:) ||
        action == @selector(duplicateSelection:)) {
        return browse && selected > 0;
    }
    if (action == @selector(quickLook:)) return browse && selected > 0 && [self previewAvailable];
    if (action == @selector(renameSelection:)) return browse && selected == 1;
    if (action == @selector(paste:)) {
        NSPasteboard *pb = NSPasteboard.generalPasteboard;
        return browse && ([pb canReadObjectForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}] ||
                          [pb availableTypeFromArray:@[kRemotePathType]] != nil);
    }
    if (action == @selector(sortByMenu:)) return YES;
    if (action == @selector(goBack:)) return browse && self.backStack.count > 0;
    if (action == @selector(goForward:)) return browse && self.forwardStack.count > 0;
    if (action == @selector(goUp:)) return browse && ![self.currentPath isEqualToString:@"/"];
    if (action == @selector(showResults:)) return self.lastResults.count > 0;
    if (action == @selector(focusSearch:)) return browse;
    if (action == @selector(setViewModeFromMenu:)) return YES;
    return YES;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(toggleHidden:)) {
        item.state = self.showHidden ? NSControlStateValueOn : NSControlStateValueOff;
    }
    if (item.action == @selector(sortByMenu:)) {
        NSString *key = self.table.sortDescriptors.firstObject.key ?: @"name";
        item.state = [item.representedObject isEqualToString:key] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    if (item.action == @selector(setViewModeFromMenu:)) {
        item.state = item.tag == self.viewMode ? NSControlStateValueOn : NSControlStateValueOff;
    }
    return [self validateAction:item.action];
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)item {
    return [self validateAction:item.action];
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

- (NSBox *)separator {
    NSBox *line = [NSBox new];
    line.boxType = NSBoxSeparator;
    line.translatesAutoresizingMaskIntoConstraints = NO;
    return line;
}

- (void)buildUI {
    self.window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 980, 620)
                                    styleMask:(NSWindowStyleMaskTitled |
                                               NSWindowStyleMaskClosable |
                                               NSWindowStyleMaskMiniaturizable |
                                               NSWindowStyleMaskResizable |
                                               NSWindowStyleMaskFullSizeContentView)
                                      backing:NSBackingStoreBuffered
                                        defer:NO];

    self.window.title = kAppName;
    self.window.minSize = NSMakeSize(680, 400);
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    self.window.toolbarStyle = NSWindowToolbarStyleUnified;

    NSSplitViewController *split = [NSSplitViewController new];
    split.splitView.autosaveName = @"MainSplit";

    NSViewController *sidebarVC = [NSViewController new];
    sidebarVC.view = [self buildSidebar];
    NSSplitViewItem *sidebarItem = [NSSplitViewItem sidebarWithViewController:sidebarVC];
    sidebarItem.minimumThickness = 180;
    sidebarItem.maximumThickness = 320;
    sidebarItem.canCollapse = YES;

    NSViewController *contentVC = [NSViewController new];
    contentVC.view = [self buildContent];
    NSSplitViewItem *contentItem = [NSSplitViewItem splitViewItemWithViewController:contentVC];
    contentItem.minimumThickness = 420;

    [split addSplitViewItem:sidebarItem];
    [split addSplitViewItem:contentItem];
    self.window.contentViewController = split;

    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"MainToolbar"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    toolbar.allowsUserCustomization = YES;
    toolbar.autosavesConfiguration = YES;
    self.window.toolbar = toolbar;

    [self.window setContentSize:NSMakeSize(980, 620)];
    self.window.frameAutosaveName = @"MainWindow";
    if (![self.window setFrameUsingName:@"MainWindow"]) {
        [self.window center];
    }
    [self reloadSidebar];
    [self updatePathBar];
    [self updateTitle];
    [self applyViewMode];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.window.initialFirstResponder];
    [NSApp activateIgnoringOtherApps:YES];
}

- (NSView *)buildSidebar {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 220, 600)];

    NSScrollView *scroll = [NSScrollView new];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;

    self.sidebar = [NSTableView new];
    // Right-click menu, filled in for the row that was clicked (a phone or a place).
    self.sidebar.menu = [[NSMenu alloc] initWithTitle:@""];
    self.sidebar.menu.delegate = self;
    self.sidebar.style = NSTableViewStyleSourceList;
    self.sidebar.headerView = nil;
    self.sidebar.dataSource = self;
    self.sidebar.delegate = self;
    self.sidebar.backgroundColor = NSColor.clearColor;
    self.sidebar.rowSizeStyle = NSTableViewRowSizeStyleDefault;
    self.sidebar.floatsGroupRows = NO;
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"place"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [self.sidebar addTableColumn:column];
    self.sidebar.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    [self.sidebar registerForDraggedTypes:@[NSPasteboardTypeFileURL, kRemotePathType]];
    scroll.documentView = self.sidebar;

    // Storage card at the bottom of the sidebar.
    self.storageCard = [NSView new];
    self.storageCard.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *storageTitle = [self label:@"Internal Storage" size:11 weight:NSFontWeightSemibold color:NSColor.secondaryLabelColor];
    self.storageBar = [NSProgressIndicator new];
    self.storageBar.style = NSProgressIndicatorStyleBar;
    self.storageBar.indeterminate = NO;
    self.storageBar.minValue = 0;
    self.storageBar.maxValue = 1;
    self.storageBar.controlSize = NSControlSizeSmall;
    self.storageBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.storageLabel = [self label:@"" size:11 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];

    for (NSView *v in @[storageTitle, self.storageBar, self.storageLabel]) [self.storageCard addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [storageTitle.topAnchor constraintEqualToAnchor:self.storageCard.topAnchor],
        [storageTitle.leadingAnchor constraintEqualToAnchor:self.storageCard.leadingAnchor],
        [storageTitle.trailingAnchor constraintLessThanOrEqualToAnchor:self.storageCard.trailingAnchor],
        [self.storageBar.topAnchor constraintEqualToAnchor:storageTitle.bottomAnchor constant:4],
        [self.storageBar.leadingAnchor constraintEqualToAnchor:self.storageCard.leadingAnchor],
        [self.storageBar.trailingAnchor constraintEqualToAnchor:self.storageCard.trailingAnchor],
        [self.storageLabel.topAnchor constraintEqualToAnchor:self.storageBar.bottomAnchor constant:2],
        [self.storageLabel.leadingAnchor constraintEqualToAnchor:self.storageCard.leadingAnchor],
        [self.storageLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.storageCard.trailingAnchor],
        [self.storageLabel.bottomAnchor constraintEqualToAnchor:self.storageCard.bottomAnchor],
    ]];
    self.storageCard.hidden = YES;

    [view addSubview:scroll];
    [view addSubview:self.storageCard];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:view.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.storageCard.topAnchor constant:-10],
        [self.storageCard.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:18],
        [self.storageCard.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-18],
        [self.storageCard.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-14],
    ]];
    return view;
}

- (NSView *)buildContent {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 760, 600)];

    self.tableScroll = [NSScrollView new];
    self.tableScroll.hasVerticalScroller = YES;
    self.tableScroll.autohidesScrollers = YES;
    self.tableScroll.translatesAutoresizingMaskIntoConstraints = NO;

    FileTableView *table = [FileTableView new];
    table.controller = self;
    table.dataSource = self;
    table.delegate = self;
    table.style = NSTableViewStyleFullWidth;
    table.rowHeight = 24;
    table.intercellSpacing = NSMakeSize(10, 2);
    table.usesAlternatingRowBackgroundColors = YES;
    table.allowsMultipleSelection = YES;
    table.allowsColumnReordering = YES;
    table.target = self;
    table.doubleAction = @selector(doubleClick:);
    table.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;

    NSArray *columns = @[
        @[@"name", @"Name", @320, @"name"],
        @[@"modified", @"Date Modified", @170, @"modified"],
        @[@"size", @"Size", @80, @"size"],
        @[@"kind", @"Kind", @140, @"kind"],
    ];
    for (NSArray *c in columns) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:c[0]];
        column.title = c[1];
        column.width = [c[2] doubleValue];
        column.minWidth = [c[0] isEqualToString:@"name"] ? 160 : 60;
        column.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:c[3]
                                                                       ascending:![c[0] isEqualToString:@"modified"]];
        column.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
        if ([c[0] isEqualToString:@"size"]) column.headerCell.alignment = NSTextAlignmentRight;
        [table addTableColumn:column];
    }
    table.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]];
    table.autosaveName = @"FileList";
    table.autosaveTableColumns = YES;

    [table registerForDraggedTypes:[self fileDragTypes]];
    [table setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
    [table setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];
    table.draggingDestinationFeedbackStyle = NSTableViewDraggingDestinationFeedbackStyleRegular;

    self.table = table;
    self.tableScroll.documentView = table;

    // Icon view.
    NSCollectionViewFlowLayout *layout = [NSCollectionViewFlowLayout new];
    layout.itemSize = NSMakeSize(112, 138);
    layout.minimumInteritemSpacing = 4;
    layout.minimumLineSpacing = 8;
    layout.sectionInset = NSEdgeInsetsMake(14, 16, 14, 16);

    IconCollectionView *collection = [IconCollectionView new];
    collection.controller = self;
    collection.collectionViewLayout = layout;
    collection.dataSource = self;
    collection.delegate = self;
    collection.selectable = YES;
    collection.allowsMultipleSelection = YES;
    collection.backgroundColors = @[NSColor.controlBackgroundColor];
    [collection registerClass:IconItem.class forItemWithIdentifier:@"icon"];
    [collection registerForDraggedTypes:[self fileDragTypes]];
    [collection setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
    [collection setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];
    self.collection = collection;

    self.collectionScroll = [NSScrollView new];
    self.collectionScroll.hasVerticalScroller = YES;
    self.collectionScroll.autohidesScrollers = YES;
    self.collectionScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionScroll.documentView = collection;

    // Column view: one list per folder from the storage root to the current folder.
    self.columnScroll = [NSScrollView new];
    self.columnScroll.hasHorizontalScroller = YES;
    self.columnScroll.hasVerticalScroller = NO;
    self.columnScroll.autohidesScrollers = YES;
    self.columnScroll.automaticallyAdjustsContentInsets = NO;
    self.columnScroll.backgroundColor = NSColor.controlBackgroundColor;
    self.columnScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.columnDoc = [NSView new];
    self.columnDoc.translatesAutoresizingMaskIntoConstraints = NO;
    self.columnScroll.documentView = self.columnDoc;
    NSClipView *clip = self.columnScroll.contentView;
    NSLayoutConstraint *shrink = [self.columnDoc.widthAnchor constraintEqualToConstant:0];
    shrink.priority = 1;
    self.columnContentWidth = [self.columnDoc.widthAnchor constraintGreaterThanOrEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [self.columnDoc.topAnchor constraintEqualToAnchor:clip.topAnchor],
        [self.columnDoc.bottomAnchor constraintEqualToAnchor:clip.bottomAnchor],
        [self.columnDoc.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
        [self.columnDoc.widthAnchor constraintGreaterThanOrEqualToAnchor:clip.widthAnchor],
        self.columnContentWidth,
        shrink,
    ]];
    [self buildPreviewPane];

    self.emptyView = [[EmptyStateView alloc] initWithFrame:NSZeroRect];
    self.emptyView.translatesAutoresizingMaskIntoConstraints = NO;

    // Transfer bar: progress of the running copy, then its summary.
    self.transferBar = [NSView new];
    self.transferBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.transferBar.hidden = YES;

    self.transferIcon = [NSImageView imageViewWithImage:ADBSymbol(@"arrow.up.arrow.down.circle", 15, NSFontWeightRegular)];
    self.transferIcon.contentTintColor = NSColor.controlAccentColor;
    self.transferIcon.translatesAutoresizingMaskIntoConstraints = NO;

    self.statusLabel = [self label:@"" size:12 weight:NSFontWeightMedium color:NSColor.labelColor];
    self.detailLabel = [[LinkLabel alloc] initWithFrame:NSZeroRect];
    self.detailLabel.editable = NO;
    self.detailLabel.selectable = NO;
    self.detailLabel.bezeled = NO;
    self.detailLabel.drawsBackground = NO;
    self.detailLabel.textColor = NSColor.secondaryLabelColor;
    self.detailLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.detailLabel.alignment = NSTextAlignmentRight;
    [self.detailLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.progress = [NSProgressIndicator new];
    self.progress.indeterminate = NO;
    self.progress.minValue = 0.0;
    self.progress.maxValue = 1.0;
    self.progress.style = NSProgressIndicatorStyleBar;
    self.progress.controlSize = NSControlSizeSmall;
    self.progress.translatesAutoresizingMaskIntoConstraints = NO;

    self.cancelButton = [NSButton buttonWithImage:ADBSymbol(@"xmark.circle.fill", 13, NSFontWeightRegular)
                                           target:self
                                           action:@selector(cancelTransfer:)];
    self.cancelButton.bordered = NO;
    self.cancelButton.contentTintColor = NSColor.secondaryLabelColor;
    self.cancelButton.toolTip = @"Stop";
    self.cancelButton.translatesAutoresizingMaskIntoConstraints = NO;

    self.closeBarButton = [NSButton buttonWithImage:ADBSymbol(@"xmark", 10, NSFontWeightSemibold)
                                             target:self
                                             action:@selector(hideTransferBar:)];
    self.closeBarButton.bordered = NO;
    self.closeBarButton.contentTintColor = NSColor.tertiaryLabelColor;
    self.closeBarButton.toolTip = @"Hide";
    self.closeBarButton.translatesAutoresizingMaskIntoConstraints = NO;

    NSBox *transferLine = [self separator];
    for (NSView *v in @[transferLine, self.transferIcon, self.statusLabel, self.detailLabel,
                        self.progress, self.cancelButton, self.closeBarButton]) {
        [self.transferBar addSubview:v];
    }

    // Path bar, like Finder's.
    self.pathControl = [NSPathControl new];
    self.pathControl.pathStyle = NSPathStyleStandard;
    self.pathControl.controlSize = NSControlSizeSmall;
    self.pathControl.font = [NSFont systemFontOfSize:11];
    self.pathControl.target = self;
    self.pathControl.action = @selector(pathClicked:);
    self.pathControl.focusRingType = NSFocusRingTypeNone;
    self.pathControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.pathControl setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.infoLabel = [self label:@"" size:11 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    self.infoLabel.alignment = NSTextAlignmentRight;
    [self.infoLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh
                                             forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSBox *pathLine = [self separator];

    for (NSView *v in @[self.tableScroll, self.collectionScroll, self.columnScroll, self.emptyView,
                        self.transferBar, pathLine, self.pathControl, self.infoLabel]) {
        [view addSubview:v];
    }

    NSLayoutConstraint *barCollapsed = [self.transferBar.heightAnchor constraintEqualToConstant:0];
    barCollapsed.identifier = @"collapsed";

    [NSLayoutConstraint activateConstraints:@[
        [self.tableScroll.topAnchor constraintEqualToAnchor:view.topAnchor],
        [self.tableScroll.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [self.tableScroll.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [self.tableScroll.bottomAnchor constraintEqualToAnchor:self.transferBar.topAnchor],

        [self.collectionScroll.topAnchor constraintEqualToAnchor:view.topAnchor],
        [self.collectionScroll.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [self.collectionScroll.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [self.collectionScroll.bottomAnchor constraintEqualToAnchor:self.transferBar.topAnchor],

        [self.columnScroll.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor],
        [self.columnScroll.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [self.columnScroll.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [self.columnScroll.bottomAnchor constraintEqualToAnchor:self.transferBar.topAnchor],

        [self.emptyView.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [self.emptyView.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [self.emptyView.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor constant:30],
        [self.emptyView.bottomAnchor constraintEqualToAnchor:self.transferBar.topAnchor],

        [self.transferBar.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [self.transferBar.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [self.transferBar.bottomAnchor constraintEqualToAnchor:pathLine.topAnchor],

        [transferLine.topAnchor constraintEqualToAnchor:self.transferBar.topAnchor],
        [transferLine.leadingAnchor constraintEqualToAnchor:self.transferBar.leadingAnchor],
        [transferLine.trailingAnchor constraintEqualToAnchor:self.transferBar.trailingAnchor],
        [self.transferIcon.leadingAnchor constraintEqualToAnchor:self.transferBar.leadingAnchor constant:12],
        [self.transferIcon.centerYAnchor constraintEqualToAnchor:self.statusLabel.centerYAnchor],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.transferIcon.trailingAnchor constant:6],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.transferBar.topAnchor constant:8],
        [self.detailLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.statusLabel.trailingAnchor constant:12],
        [self.detailLabel.firstBaselineAnchor constraintEqualToAnchor:self.statusLabel.firstBaselineAnchor],
        [self.detailLabel.trailingAnchor constraintEqualToAnchor:self.cancelButton.leadingAnchor constant:-8],
        [self.cancelButton.centerYAnchor constraintEqualToAnchor:self.statusLabel.centerYAnchor],
        [self.cancelButton.trailingAnchor constraintEqualToAnchor:self.closeBarButton.leadingAnchor constant:-4],
        [self.closeBarButton.centerYAnchor constraintEqualToAnchor:self.statusLabel.centerYAnchor],
        [self.closeBarButton.trailingAnchor constraintEqualToAnchor:self.transferBar.trailingAnchor constant:-12],
        [self.progress.leadingAnchor constraintEqualToAnchor:self.transferBar.leadingAnchor constant:12],
        [self.progress.trailingAnchor constraintEqualToAnchor:self.transferBar.trailingAnchor constant:-12],
        [self.progress.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:5],
        [self.progress.bottomAnchor constraintLessThanOrEqualToAnchor:self.transferBar.bottomAnchor constant:-6],

        [pathLine.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [pathLine.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [pathLine.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-26],

        [self.pathControl.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:8],
        [self.pathControl.centerYAnchor constraintEqualToAnchor:view.bottomAnchor constant:-13],
        [self.pathControl.trailingAnchor constraintLessThanOrEqualToAnchor:self.infoLabel.leadingAnchor constant:-12],
        [self.infoLabel.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-12],
        [self.infoLabel.centerYAnchor constraintEqualToAnchor:self.pathControl.centerYAnchor],
        barCollapsed,
    ]];
    return view;
}

#pragma mark Toolbar

static NSToolbarItemIdentifier const kNavItem = @"nav";
static NSToolbarItemIdentifier const kUpItem = @"up";
static NSToolbarItemIdentifier const kNewFolderItem = @"newFolder";
static NSToolbarItemIdentifier const kUploadItem = @"upload";
static NSToolbarItemIdentifier const kDownloadItem = @"download";
static NSToolbarItemIdentifier const kDeleteItem = @"delete";
static NSToolbarItemIdentifier const kRefreshItem = @"refresh";
static NSToolbarItemIdentifier const kHiddenItem = @"hidden";
static NSToolbarItemIdentifier const kSearchItem = @"search";
static NSToolbarItemIdentifier const kViewItem = @"view";
static NSToolbarItemIdentifier const kInfoItem = @"info";

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    (void)toolbar;
    return @[NSToolbarToggleSidebarItemIdentifier, NSToolbarSidebarTrackingSeparatorItemIdentifier,
             kNavItem, NSToolbarFlexibleSpaceItemIdentifier, kViewItem, NSToolbarSpaceItemIdentifier,
             kNewFolderItem, kUploadItem, kDownloadItem, kDeleteItem, kRefreshItem, kSearchItem];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    (void)toolbar;
    return @[NSToolbarToggleSidebarItemIdentifier, NSToolbarSidebarTrackingSeparatorItemIdentifier,
             kNavItem, kViewItem, kUpItem, kNewFolderItem, kUploadItem, kDownloadItem, kDeleteItem, kInfoItem,
             kRefreshItem, kHiddenItem, kSearchItem,
             NSToolbarFlexibleSpaceItemIdentifier, NSToolbarSpaceItemIdentifier];
}

- (NSToolbarItem *)toolbarButton:(NSToolbarItemIdentifier)identifier label:(NSString *)label
                          symbol:(NSString *)symbol action:(SEL)action {
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
    item.label = label;
    item.paletteLabel = label;
    item.toolTip = label;
    item.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label];
    item.target = self;
    item.action = action;
    item.bordered = YES;
    return item;
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSToolbarItemIdentifier)identifier
 willBeInsertedIntoToolbar:(BOOL)flag {
    (void)toolbar;
    (void)flag;

    if ([identifier isEqualToString:kNavItem]) {
        NSSegmentedControl *nav =
            [NSSegmentedControl segmentedControlWithImages:@[ADBSymbol(@"chevron.left", 13, NSFontWeightMedium),
                                                             ADBSymbol(@"chevron.right", 13, NSFontWeightMedium)]
                                              trackingMode:NSSegmentSwitchTrackingMomentary
                                                    target:self
                                                    action:@selector(navClicked:)];
        nav.segmentStyle = NSSegmentStyleSeparated;
        [nav setToolTip:@"Back" forSegment:0];
        [nav setToolTip:@"Forward" forSegment:1];
        self.navControl = nav;
        [self updateNavControl];

        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label = @"Back/Forward";
        item.paletteLabel = @"Back/Forward";
        item.view = nav;
        item.navigational = YES;
        return item;
    }
    if ([identifier isEqualToString:kViewItem]) {
        NSSegmentedControl *control =
            [NSSegmentedControl segmentedControlWithImages:@[ADBSymbol(@"square.grid.2x2", 14, NSFontWeightRegular),
                                                             ADBSymbol(@"list.bullet", 14, NSFontWeightRegular),
                                                             ADBSymbol(@"rectangle.split.3x1", 14, NSFontWeightRegular)]
                                              trackingMode:NSSegmentSwitchTrackingSelectOne
                                                    target:self
                                                    action:@selector(viewControlChanged:)];
        [control setToolTip:@"Icons" forSegment:0];
        [control setToolTip:@"List" forSegment:1];
        [control setToolTip:@"Columns" forSegment:2];
        control.selectedSegment = self.viewMode;
        self.viewControl = control;

        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label = @"View";
        item.paletteLabel = @"View";
        item.view = control;
        return item;
    }
    if ([identifier isEqualToString:kInfoItem]) {
        return [self toolbarButton:identifier label:@"Get Info" symbol:@"info.circle" action:@selector(getInfo:)];
    }
    if ([identifier isEqualToString:kUpItem]) {
        return [self toolbarButton:identifier label:@"Enclosing Folder" symbol:@"arrow.up" action:@selector(goUp:)];
    }
    if ([identifier isEqualToString:kNewFolderItem]) {
        return [self toolbarButton:identifier label:@"New Folder" symbol:@"folder.badge.plus" action:@selector(newFolder:)];
    }
    if ([identifier isEqualToString:kUploadItem]) {
        return [self toolbarButton:identifier label:@"Upload" symbol:@"square.and.arrow.up" action:@selector(uploadFiles:)];
    }
    if ([identifier isEqualToString:kDownloadItem]) {
        return [self toolbarButton:identifier label:@"Download" symbol:@"square.and.arrow.down" action:@selector(downloadSelection:)];
    }
    if ([identifier isEqualToString:kDeleteItem]) {
        return [self toolbarButton:identifier label:@"Delete" symbol:@"trash" action:@selector(deleteSelection:)];
    }
    if ([identifier isEqualToString:kRefreshItem]) {
        return [self toolbarButton:identifier label:@"Refresh" symbol:@"arrow.clockwise" action:@selector(refresh:)];
    }
    if ([identifier isEqualToString:kHiddenItem]) {
        return [self toolbarButton:identifier label:@"Hidden Files" symbol:@"eye" action:@selector(toggleHidden:)];
    }
    if ([identifier isEqualToString:kSearchItem]) {
        NSSearchToolbarItem *item = [[NSSearchToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label = @"Search";
        item.paletteLabel = @"Search";
        self.searchField = item.searchField;
        self.searchField.placeholderString = @"Filter this folder";
        self.searchField.sendsSearchStringImmediately = YES;
        self.searchField.target = self;
        self.searchField.action = @selector(searchChanged:);
        return item;
    }
    return nil;
}

- (void)updateNavControl {
    [self.navControl setEnabled:[self canBrowse] && self.backStack.count > 0 forSegment:0];
    [self.navControl setEnabled:[self canBrowse] && self.forwardStack.count > 0 forSegment:1];
}

- (void)navClicked:(NSSegmentedControl *)sender {
    if (sender.selectedSegment == 0) [self goBack:nil];
    else [self goForward:nil];
}

- (void)searchChanged:(NSSearchField *)sender {
    self.filterText = [sender.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    [self applyFilterKeepingSelection:YES];
}

- (void)focusSearch:(id)sender {
    (void)sender;
    if (self.searchField) [self.window makeFirstResponder:self.searchField];
}

#pragma mark Sidebar

- (NSArray<NSDictionary *> *)placesForSerial:(NSString *)serial {
    NSMutableArray *places = [NSMutableArray arrayWithArray:@[
        @{@"title": @"Internal Storage", @"symbol": @"internaldrive", @"path": kStorageRoot},
        @{@"title": @"Download", @"symbol": @"arrow.down.circle", @"path": @"/sdcard/Download"},
        @{@"title": @"Camera", @"symbol": @"camera", @"path": @"/sdcard/DCIM"},
        @{@"title": @"Pictures", @"symbol": @"photo", @"path": @"/sdcard/Pictures"},
        @{@"title": @"Movies", @"symbol": @"film", @"path": @"/sdcard/Movies"},
        @{@"title": @"Music", @"symbol": @"music.note", @"path": @"/sdcard/Music"},
        @{@"title": @"Documents", @"symbol": @"doc.text", @"path": @"/sdcard/Documents"},
    ]];
    NSArray<NSString *> *volumes = self.deviceInfo[serial ?: @""][@"volumes"];
    for (NSString *volume in volumes) {
        NSString *title = volumes.count > 1 ? [NSString stringWithFormat:@"SD Card (%@)", volume] : @"SD Card";
        [places addObject:@{@"title": title, @"symbol": @"sdcard", @"path": [@"/storage/" stringByAppendingString:volume]}];
    }
    [places addObject:@{@"title": @"Root", @"symbol": @"externaldrive", @"path": @"/"}];
    return places;
}

- (void)reloadSidebar {
    NSMutableArray *rows = [NSMutableArray array];
    [rows addObject:@{@"group": @"Devices"}];

    NSArray<NSDictionary *> *offline = [self offlineWirelessDevices];
    if (!self.devices.count && !offline.count) {
        NSString *title = [self.deviceState isEqualToString:@"noadb"] ? @"adb not found" : @"No device";
        [rows addObject:@{@"title": title, @"symbol": @"cable.connector.slash", @"placeholder": @YES}];
    }
    for (NSDictionary *device in self.devices) {
        NSString *serial = device[@"serial"];
        NSString *state = device[@"state"];
        NSString *name = self.deviceInfo[serial][@"name"] ?: device[@"model"] ?: serial;
        name = [name stringByReplacingOccurrencesOfString:@"_" withString:@" "];
        [rows addObject:@{@"title": name, @"symbol": @"candybarphone", @"serial": serial, @"state": state,
                          @"wifi": @([self isWirelessSerial:serial])}];
    }
    // Phones that were connected over Wi-Fi and are out of reach right now.
    for (NSDictionary *device in offline) {
        [rows addObject:@{@"title": device[@"name"] ?: device[@"address"], @"symbol": @"wifi.slash",
                          @"offline": device[@"address"]}];
    }

    if (self.serial.length) {
        [rows addObject:@{@"group": @"Locations"}];
        [rows addObjectsFromArray:[self placesForSerial:self.serial]];
    }

    self.sidebarRows = rows;
    self.updatingSidebar = YES;
    [self.sidebar reloadData];
    [self syncSidebarSelection];
    self.updatingSidebar = NO;
}

// Highlights the place that matches the folder on screen, if any.
- (void)syncSidebarSelection {
    BOOL wasUpdating = self.updatingSidebar;
    self.updatingSidebar = YES;
    NSInteger match = -1;
    for (NSUInteger i = 0; i < self.sidebarRows.count; i++) {
        NSString *path = self.sidebarRows[i][@"path"];
        if (path && [path isEqualToString:self.currentPath]) match = (NSInteger)i;
    }
    if (match >= 0) {
        [self.sidebar selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)match] byExtendingSelection:NO];
    } else {
        [self.sidebar deselectAll:nil];
    }
    self.updatingSidebar = wasUpdating;
}

- (NSView *)sidebarViewForRow:(NSInteger)row {
    NSDictionary *info = self.sidebarRows[(NSUInteger)row];

    if (info[@"group"]) {
        NSTableCellView *cell = [self.sidebar makeViewWithIdentifier:@"group" owner:self];
        if (!cell) {
            cell = [NSTableCellView new];
            cell.identifier = @"group";
            NSTextField *field = [self label:@"" size:11 weight:NSFontWeightSemibold color:NSColor.tertiaryLabelColor];
            [cell addSubview:field];
            cell.textField = field;
            [NSLayoutConstraint activateConstraints:@[
                [field.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
                [field.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor],
                [field.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor constant:-3],
            ]];
        }
        cell.textField.stringValue = info[@"group"];
        return cell;
    }

    NSTableCellView *cell = [self.sidebar makeViewWithIdentifier:@"place" owner:self];
    if (!cell) {
        cell = [NSTableCellView new];
        cell.identifier = @"place";
        NSImageView *icon = [NSImageView new];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *field = [self label:@"" size:13 weight:NSFontWeightRegular color:NSColor.labelColor];
        field.lineBreakMode = NSLineBreakByTruncatingTail;
        NSImageView *badge = [NSImageView new];
        badge.translatesAutoresizingMaskIntoConstraints = NO;
        badge.identifier = @"badge";
        [cell addSubview:icon];
        [cell addSubview:field];
        [cell addSubview:badge];
        cell.imageView = icon;
        cell.textField = field;
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:18],
            [field.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:6],
            [field.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [badge.leadingAnchor constraintGreaterThanOrEqualToAnchor:field.trailingAnchor constant:4],
            [badge.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [badge.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    NSImageView *badge = nil;
    for (NSView *v in cell.subviews) if ([v.identifier isEqualToString:@"badge"]) badge = (NSImageView *)v;

    cell.imageView.image = ADBSymbol(info[@"symbol"], 14, NSFontWeightRegular);
    cell.imageView.contentTintColor = NSColor.controlAccentColor;
    cell.textField.stringValue = info[@"title"];
    cell.textField.textColor = NSColor.labelColor;
    cell.textField.font = [NSFont systemFontOfSize:13];
    cell.toolTip = info[@"path"];
    badge.image = nil;

    if (info[@"offline"]) {
        cell.imageView.contentTintColor = NSColor.tertiaryLabelColor;
        cell.textField.textColor = NSColor.secondaryLabelColor;
        cell.toolTip = [NSString stringWithFormat:@"%@ — not reachable over Wi-Fi right now; trying to reconnect", info[@"offline"]];
    } else if (info[@"placeholder"]) {
        cell.imageView.contentTintColor = NSColor.tertiaryLabelColor;
        cell.textField.textColor = NSColor.secondaryLabelColor;
    } else if (info[@"serial"]) {
        BOOL current = [info[@"serial"] isEqualToString:self.serial];
        BOOL ready = [info[@"state"] isEqualToString:@"device"];
        cell.textField.font = [NSFont systemFontOfSize:13 weight:current ? NSFontWeightSemibold : NSFontWeightRegular];
        cell.imageView.contentTintColor = ready ? NSColor.controlAccentColor : NSColor.systemOrangeColor;
        if (!ready) {
            badge.image = ADBSymbol(@"exclamationmark.triangle.fill", 11, NSFontWeightRegular);
            badge.contentTintColor = NSColor.systemOrangeColor;
            cell.toolTip = [info[@"state"] isEqualToString:@"unauthorized"]
                ? @"Unlock the phone and allow USB debugging"
                : [NSString stringWithFormat:@"Device is %@", info[@"state"]];
        } else {
            cell.toolTip = [info[@"wifi"] boolValue] ? [NSString stringWithFormat:@"Connected over Wi-Fi (%@)", info[@"serial"]] : info[@"serial"];
            if ([info[@"wifi"] boolValue]) {
                badge.image = ADBSymbol(@"wifi", 10, NSFontWeightSemibold);
                badge.contentTintColor = NSColor.secondaryLabelColor;
            }
        }
    }
    return cell;
}

- (void)sidebarSelectionChanged {
    if (self.updatingSidebar) return;
    NSInteger row = self.sidebar.selectedRow;
    if (row < 0) return;
    NSString *path = self.sidebarRows[(NSUInteger)row][@"path"];
    if (path) [self navigateTo:path];
}

- (BOOL)sidebarShouldSelectRow:(NSInteger)row {
    NSDictionary *info = self.sidebarRows[(NSUInteger)row];
    if (info[@"offline"]) {
        [self reconnectWireless:info[@"offline"] force:YES];
        return NO;
    }
    NSString *serial = info[@"serial"];
    if (serial) {
        // Like a disk in Finder: a click opens the phone's storage, switching phones if needed.
        if (![info[@"state"] isEqualToString:@"device"]) {
            NSBeep();
        } else if (![serial isEqualToString:self.serial]) {
            [NSUserDefaults.standardUserDefaults setObject:kStorageRoot forKey:kLastFolderKey];
            [self switchToDevice:serial];
        } else {
            [self navigateTo:kStorageRoot];
        }
        return NO;
    }
    return info[@"path"] != nil;
}

// Dropping onto a place in the sidebar uploads into it.
- (NSDragOperation)sidebarValidateDrop:(id<NSDraggingInfo>)info row:(NSInteger)row operation:(NSTableViewDropOperation)op {
    if (row < 0 || (NSUInteger)row >= self.sidebarRows.count || op != NSTableViewDropOn) return NSDragOperationNone;
    return [self dropOperationFor:info folder:self.sidebarRows[(NSUInteger)row][@"path"]];
}

- (BOOL)sidebarAcceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row {
    NSString *path = self.sidebarRows[(NSUInteger)row][@"path"];
    return path ? [self performDrop:info folder:path] : NO;
}

#pragma mark Table data source / delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == self.sidebar) return (NSInteger)self.sidebarRows.count;
    return (NSInteger)[self itemsForTable:tableView].count;
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row {
    return tableView == self.sidebar && self.sidebarRows[(NSUInteger)row][@"group"] != nil;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    if (tableView == self.sidebar) {
        return self.sidebarRows[(NSUInteger)row][@"group"] ? (row == 0 ? 26 : 34) : 26;
    }
    return tableView.rowHeight;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    if (tableView == self.sidebar) return [self sidebarShouldSelectRow:row];
    return YES;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object == self.sidebar) {
        [self sidebarSelectionChanged];
        return;
    }
    if ([self.columnTables containsObject:notification.object]) {
        if (!self.updatingColumns) [self columnSelectionChanged:notification.object];
        return;
    }
    [self fileViewSelectionChanged];
}

- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors {
    (void)oldDescriptors;
    if (tableView == self.table) [self applyFilterKeepingSelection:YES];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    if (tableView == self.sidebar) return [self sidebarViewForRow:row];

    NSString *identifier = column.identifier;
    if ([identifier isEqualToString:@"colname"]) return [self columnCellForTable:tableView row:row];
    NSTableCellView *cell = [tableView makeViewWithIdentifier:identifier owner:self];

    if (!cell) {
        cell = [NSTableCellView new];
        cell.identifier = identifier;

        NSTextField *field = [NSTextField labelWithString:@""];
        field.lineBreakMode = NSLineBreakByTruncatingMiddle;
        field.translatesAutoresizingMaskIntoConstraints = NO;
        field.font = [NSFont systemFontOfSize:13];
        [cell addSubview:field];
        cell.textField = field;

        NSLayoutXAxisAnchor *leading = cell.leadingAnchor;
        CGFloat inset = 2;
        if ([identifier isEqualToString:@"name"]) {
            NSImageView *icon = [NSImageView new];
            icon.imageScaling = NSImageScaleProportionallyUpOrDown;
            icon.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:icon];
            cell.imageView = icon;
            [NSLayoutConstraint activateConstraints:@[
                [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
                [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
                [icon.widthAnchor constraintEqualToConstant:18],
                [icon.heightAnchor constraintEqualToConstant:18],
            ]];
            leading = icon.trailingAnchor;
            inset = 6;
            field.lineBreakMode = NSLineBreakByTruncatingMiddle;
            field.target = self;
            field.action = @selector(renameEdited:);
            field.delegate = self;
        } else {
            field.textColor = NSColor.secondaryLabelColor;
            field.lineBreakMode = NSLineBreakByTruncatingTail;
        }
        if ([identifier isEqualToString:@"size"]) {
            field.alignment = NSTextAlignmentRight;
            field.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
        }
        [NSLayoutConstraint activateConstraints:@[
            [field.leadingAnchor constraintEqualToAnchor:leading constant:inset],
            [field.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
            [field.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    RemoteItem *item = self.items[(NSUInteger)row];
    CGFloat alpha = item.hidden ? 0.55 : 1.0;

    if ([identifier isEqualToString:@"name"]) {
        cell.imageView.image = [self thumbnailForItem:item request:YES] ?: ADBIconForItem(item);
        cell.imageView.alphaValue = alpha;
        cell.textField.stringValue = item.name;
        cell.textField.editable = [item.path isEqualToString:self.renamingPath];
        cell.textField.alphaValue = alpha;
    } else if ([identifier isEqualToString:@"modified"]) {
        cell.textField.stringValue = item.modified ? [self.dateFormatter stringFromDate:item.modified] : @"--";
    } else if ([identifier isEqualToString:@"size"]) {
        cell.textField.stringValue = item.directory ? ([self countTextForItem:item] ?: @"--")
                                   : (item.detailsKnown ? ADBFormatBytes(item.size) : @"--");
    } else {
        cell.textField.stringValue = item.kind;
    }
    return cell;
}

// Drag source: every row is a file promise, so it can be dropped straight into Finder.
- (id<NSPasteboardWriting>)tableView:(NSTableView *)tableView pasteboardWriterForRow:(NSInteger)row {
    if (tableView == self.sidebar || !self.serial.length) return nil;
    NSArray<RemoteItem *> *items = [self itemsForTable:tableView];
    if (row < 0 || (NSUInteger)row >= items.count) return nil;
    return [self promiseForItem:items[(NSUInteger)row]];
}

- (RemoteFilePromiseProvider *)promiseForItem:(RemoteItem *)item {
    RemoteFilePromiseProvider *provider =
        [[RemoteFilePromiseProvider alloc] initWithFileType:item.contentType.identifier delegate:self];
    provider.item = item;
    provider.userInfo = @{@"serial": self.serial};
    return provider;
}

- (NSArray<NSPasteboardType> *)fileDragTypes {
    return [@[NSPasteboardTypeFileURL, kRemotePathType] arrayByAddingObjectsFromArray:NSFilePromiseReceiver.readableDraggedTypes];
}

- (BOOL)isFileView:(id)view {
    return view && (view == self.table || view == self.collection || [self.columnTables containsObject:view]);
}

// Everything is copied: Mac → phone, phone → Mac, and folder → folder on the phone.
- (NSDragOperation)dropOperationFor:(id<NSDraggingInfo>)info folder:(NSString *)folder {
    if (![self canBrowse] || !folder.length) return NSDragOperationNone;

    if ([self isFileView:info.draggingSource]) {
        NSArray<NSString *> *paths = [self draggedRemotePaths:info];
        if (!paths.count) return NSDragOperationNone;
        for (NSString *path in paths) {
            // Not into itself, and not back into the folder it came from.
            if (ADBPathIsInside(folder, path) || [ADBParentPath(path) isEqualToString:folder]) return NSDragOperationNone;
        }
        return NSDragOperationCopy;
    }

    NSPasteboard *pb = info.draggingPasteboard;
    BOOL files = [pb canReadObjectForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    BOOL promises = [pb canReadObjectForClasses:@[NSFilePromiseReceiver.class] options:nil];
    return (files || promises) ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)performDrop:(id<NSDraggingInfo>)info folder:(NSString *)dest {
    if ([self isFileView:info.draggingSource]) {
        [self copyRemotePaths:[self draggedRemotePaths:info] toFolder:dest];
        return YES;
    }

    NSPasteboard *pb = info.draggingPasteboard;
    NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[NSURL.class]
                                               options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (urls.count) {
        [self uploadURLs:urls toFolder:dest];
        return YES;
    }

    // Photos, Mail and others hand over file promises: receive them, then upload.
    NSArray<NSFilePromiseReceiver *> *receivers = [pb readObjectsForClasses:@[NSFilePromiseReceiver.class] options:nil];
    if (!receivers.count) return NO;

    NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtPath:temp withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *tempURL = [NSURL fileURLWithPath:temp isDirectory:YES];
    NSOperationQueue *queue = [NSOperationQueue new];

    for (NSFilePromiseReceiver *receiver in receivers) {
        [receiver receivePromisedFilesAtDestination:tempURL
                                            options:@{}
                                     operationQueue:queue
                                             reader:^(NSURL *fileURL, NSError *error) {
            if (error) {
                [self appendLog:[NSString stringWithFormat:@"PROMISE ERROR: %@", error.localizedDescription]];
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self uploadURLs:@[fileURL] toFolder:dest];
            });
        }];
    }
    return YES;
}

- (NSArray<NSString *> *)draggedRemotePaths:(id<NSDraggingInfo>)info {
    NSMutableArray *paths = [NSMutableArray array];
    for (NSPasteboardItem *item in info.draggingPasteboard.pasteboardItems) {
        NSString *path = [item stringForType:kRemotePathType];
        if (path.length) [paths addObject:path];
    }
    return paths;
}

- (NSDragOperation)tableView:(NSTableView *)tableView
                validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)op {
    if (tableView == self.sidebar) return [self sidebarValidateDrop:info row:row operation:op];
    if (self.loadError) return NSDragOperationNone;

    NSArray<RemoteItem *> *items = [self itemsForTable:tableView];
    if (op == NSTableViewDropOn && row >= 0 && (NSUInteger)row < items.count && items[(NSUInteger)row].directory) {
        NSDragOperation operation = [self dropOperationFor:info folder:items[(NSUInteger)row].path];
        if (operation != NSDragOperationNone) return operation;
    }
    // Anywhere else in the list means "into the folder this list shows".
    [tableView setDropRow:-1 dropOperation:NSTableViewDropOn];
    return [self dropOperationFor:info folder:[self folderForTable:tableView]];
}

- (BOOL)tableView:(NSTableView *)tableView
       acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row
    dropOperation:(NSTableViewDropOperation)op {
    if (tableView == self.sidebar) return [self sidebarAcceptDrop:info row:row];

    NSArray<RemoteItem *> *items = [self itemsForTable:tableView];
    NSString *dest = [self folderForTable:tableView];
    if (op == NSTableViewDropOn && row >= 0 && (NSUInteger)row < items.count && items[(NSUInteger)row].directory) {
        dest = items[(NSUInteger)row].path;
    }
    return [self performDrop:info folder:dest];
}

#pragma mark File promises (device → Finder)

- (NSString *)filePromiseProvider:(NSFilePromiseProvider *)provider fileNameForType:(NSString *)fileType {
    (void)fileType;
    NSString *name = ((RemoteFilePromiseProvider *)provider).item.name;
    return [name stringByReplacingOccurrencesOfString:@":" withString:@"-"];
}

- (NSOperationQueue *)operationQueueForFilePromiseProvider:(NSFilePromiseProvider *)provider {
    (void)provider;
    return self.pullQueue;
}

- (void)filePromiseProvider:(NSFilePromiseProvider *)provider
          writePromiseToURL:(NSURL *)url
          completionHandler:(void (^)(NSError *error))completionHandler {
    RemoteItem *item = ((RemoteFilePromiseProvider *)provider).item;
    NSString *serial = ((NSDictionary *)provider.userInfo)[@"serial"];

    NSString *error = [self pullItem:item toPath:url.path serial:serial];
    if (error) {
        completionHandler([NSError errorWithDomain:NSCocoaErrorDomain
                                              code:NSFileWriteUnknownError
                                          userInfo:@{NSLocalizedDescriptionKey: error}]);
    } else {
        completionHandler(nil);
    }
}

#pragma mark Navigation

- (void)navigateTo:(NSString *)path {
    NSString *target = [self normalizedPath:path];
    if (self.currentPath && [target isEqualToString:self.currentPath]) {
        [self reloadSelecting:nil];
        return;
    }
    if (self.currentPath) [self.backStack addObject:self.currentPath];
    [self.forwardStack removeAllObjects];
    [self showFolder:target selecting:nil];
}

- (void)showFolder:(NSString *)path selecting:(NSArray<NSString *> *)names {
    [self cancelRename];
    // A preview of the folder we're leaving (or entering) would be stale.
    [self hideFolderPanelAnimated:NO];
    if ([QLPreviewPanel sharedPreviewPanelExists] && [QLPreviewPanel sharedPreviewPanel].visible) {
        [[QLPreviewPanel sharedPreviewPanel] orderOut:nil];
    }
    self.currentPath = path;
    self.loadError = nil;
    if (self.searchField.stringValue.length) {
        self.searchField.stringValue = @"";
        self.filterText = nil;
    }
    // Show what we saw last time right away; the fresh listing replaces it a moment later.
    self.allItems = self.listingCache[path] ?: @[];
    [self applyFilterKeepingSelection:NO];
    [self selectNames:names];
    if (self.serial.length) {
        [NSUserDefaults.standardUserDefaults setObject:path forKey:kLastFolderKey];
    }
    [self updateTitle];
    [self updatePathBar];
    [self updateNavControl];
    [self syncSidebarSelection];
    [self reloadSelecting:names];
}

- (void)goBack:(id)sender {
    (void)sender;
    if (!self.backStack.count) return;
    NSString *path = self.backStack.lastObject;
    [self.backStack removeLastObject];
    NSString *came = self.currentPath;
    if (came) [self.forwardStack addObject:came];
    [self showFolder:path selecting:came ? @[came.lastPathComponent] : nil];
}

- (void)goForward:(id)sender {
    (void)sender;
    if (!self.forwardStack.count) return;
    NSString *path = self.forwardStack.lastObject;
    [self.forwardStack removeLastObject];
    if (self.currentPath) [self.backStack addObject:self.currentPath];
    [self showFolder:path selecting:nil];
}

- (void)goUp:(id)sender {
    (void)sender;
    if (![self canBrowse] || [self.currentPath isEqualToString:@"/"]) return;
    NSString *came = self.currentPath;
    // /sdcard is a symlink; its "parent" is more useful as the storage root than as "/".
    NSString *parent = ADBParentPath(came);
    [self.backStack addObject:came];
    [self.forwardStack removeAllObjects];
    [self showFolder:parent selecting:@[came.lastPathComponent]];
}

- (void)goToPlace:(NSMenuItem *)sender {
    [self navigateTo:sender.representedObject];
}

- (void)goToFolder:(id)sender {
    (void)sender;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Go to Folder";
    alert.informativeText = @"Enter a path on the device. Relative paths like Music/Rock start at /sdcard.";
    [alert addButtonWithTitle:@"Go"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *field = [NSTextField textFieldWithString:self.currentPath ?: kStorageRoot];
    field.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    field.frame = NSMakeRect(0, 0, 320, 24);
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;

    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        [self navigateTo:field.stringValue];
    }];
}

- (void)refresh:(id)sender {
    (void)sender;
    [self reloadSelecting:nil];
    [self invalidateFreeSpace];
    [self refreshDevice];
}

- (void)pathClicked:(id)sender {
    (void)sender;
    NSPathControlItem *clicked = self.pathControl.clickedPathItem;
    NSUInteger index = [self.pathControl.pathItems indexOfObject:clicked];
    if (index == NSNotFound || index >= self.pathControlPaths.count) return;
    [self navigateTo:self.pathControlPaths[index]];
}

- (void)doubleClick:(NSTableView *)sender {
    NSInteger row = sender.clickedRow;
    NSArray<RemoteItem *> *items = [self itemsForTable:sender];
    if (row < 0 || (NSUInteger)row >= items.count) return;
    [self openItems:@[items[(NSUInteger)row]]];
}

- (void)openSelection:(id)sender {
    (void)sender;
    [self openItems:[self selectedItems]];
}

- (void)openItems:(NSArray<RemoteItem *> *)items {
    if (!items.count) return;
    if (items.count == 1 && items.firstObject.directory) {
        [self navigateTo:items.firstObject.path];
        return;
    }
    for (RemoteItem *item in items) {
        if (item.directory) continue;
        [self fetchToCache:@[item] completion:^(NSArray<NSURL *> *urls) {
            for (NSURL *url in urls) [[NSWorkspace sharedWorkspace] openURL:url];
        }];
    }
}

- (NSString *)displayNameForPath:(NSString *)path {
    if ([path isEqualToString:kStorageRoot] || [path isEqualToString:@"/storage/emulated/0"]) return @"Internal Storage";
    if ([path isEqualToString:@"/"]) return [self deviceName] ?: @"Device";
    for (NSDictionary *place in [self placesForSerial:self.serial]) {
        if ([place[@"path"] isEqualToString:path] && [place[@"symbol"] isEqualToString:@"sdcard"]) return place[@"title"];
    }
    return path.lastPathComponent;
}

- (NSString *)deviceName {
    if (!self.serial.length) return nil;
    return self.deviceInfo[self.serial][@"name"];
}

- (void)updateTitle {
    if (self.currentPath && self.serial.length) {
        self.window.title = [self displayNameForPath:self.currentPath];
        NSDictionary *info = self.deviceInfo[self.serial];
        NSMutableArray *parts = [NSMutableArray array];
        if ([info[@"name"] length]) [parts addObject:info[@"name"]];
        if ([info[@"model"] length] && ![info[@"model"] isEqualToString:info[@"name"]]) [parts addObject:info[@"model"]];
        if ([info[@"android"] length]) [parts addObject:[@"Android " stringByAppendingString:info[@"android"]]];
        self.window.subtitle = [parts componentsJoinedByString:@" · "];
    } else {
        self.window.title = kAppName;
        self.window.subtitle = @"";
    }
}

- (void)updatePathBar {
    NSMutableArray<NSPathControlItem *> *items = [NSMutableArray array];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];

    if (self.currentPath && self.serial.length) {
        NSString *path = self.currentPath;
        NSString *base = @"/";
        if (ADBPathIsInside(path, kStorageRoot)) base = kStorageRoot;
        for (NSDictionary *place in [self placesForSerial:self.serial]) {
            if ([place[@"symbol"] isEqualToString:@"sdcard"] && ADBPathIsInside(path, place[@"path"])) base = place[@"path"];
        }

        NSPathControlItem *root = [NSPathControlItem new];
        root.title = [base isEqualToString:@"/"] ? ([self deviceName] ?: @"Device") : [self displayNameForPath:base];
        root.image = ADBSymbol([base isEqualToString:@"/"] ? @"candybarphone" : @"internaldrive", 11, NSFontWeightRegular);
        [items addObject:root];
        [paths addObject:base];

        NSString *rest = [path substringFromIndex:base.length];
        NSString *walk = base;
        NSImage *folder = [[NSWorkspace sharedWorkspace] iconForContentType:UTTypeFolder];
        folder.size = NSMakeSize(14, 14);
        for (NSString *part in [rest componentsSeparatedByString:@"/"]) {
            if (!part.length) continue;
            walk = ADBJoinPath(walk, part);
            NSPathControlItem *item = [NSPathControlItem new];
            item.title = part;
            item.image = folder;
            [items addObject:item];
            [paths addObject:walk];
        }
    }
    self.pathControl.pathItems = items;
    self.pathControlPaths = paths;
}

#pragma mark Listing

// One adb call per folder: find + stat gives type, size and date for every entry.
// '/' can't appear in a file name, so it separates the fields safely. stat -L
// follows symlinks (folders like /sdcard are links). Old devices without toybox
// fall back to ls -p.
- (NSString *)listCommandForPath:(NSString *)path {
    NSString *q = [self shellQuote:path];
    return [NSString stringWithFormat:
            @"cd %@ || exit 1; ls -a >/dev/null || exit 1; "
            @"if stat -L -c %%s . >/dev/null 2>&1 && find . -maxdepth 0 -mindepth 0 >/dev/null 2>&1; then "
            @"find . -mindepth 1 -maxdepth 1 -exec stat -L -c '%%f/%%s/%%Y/%%n' {} + 2>/dev/null; "
            @"find . -mindepth 1 -maxdepth 1 -type l ! -exec test -e {} \\; -exec echo 'L/{}' \\; 2>/dev/null; "
            @"else echo '//ls'; ls -1pa; fi; exit 0", q];
}

- (NSArray<RemoteItem *> *)parseListing:(NSString *)output inFolder:(NSString *)folder {
    NSMutableArray<RemoteItem *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    BOOL lsMode = NO;

    for (NSString *raw in [output componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
        if (!line.length) continue;
        if ([line isEqualToString:@"//ls"]) {
            lsMode = YES;
            continue;
        }

        RemoteItem *item = [RemoteItem new];

        if (lsMode) {
            if ([line isEqualToString:@"./"] || [line isEqualToString:@"../"]) continue;
            item.directory = [line hasSuffix:@"/"];
            item.name = item.directory ? [line substringToIndex:line.length - 1] : line;
        } else if ([line hasPrefix:@"L/./"]) {
            // A link whose target is missing or unreadable.
            item.name = [line substringFromIndex:4];
        } else {
            NSArray<NSString *> *parts = [line componentsSeparatedByString:@"/"];
            if (parts.count < 5 || ![parts[3] isEqualToString:@"."]) continue;
            unsigned long mode = strtoul(parts[0].UTF8String, NULL, 16);
            item.directory = (mode & 0170000) == 0040000;
            item.size = strtoull(parts[1].UTF8String, NULL, 10);
            item.modified = [NSDate dateWithTimeIntervalSince1970:strtod(parts[2].UTF8String, NULL)];
            item.detailsKnown = YES;
            item.name = [[parts subarrayWithRange:NSMakeRange(4, parts.count - 4)] componentsJoinedByString:@"/"];
        }

        if (!item.name.length || [item.name isEqualToString:@"."] || [item.name isEqualToString:@".."]) continue;
        if ([seen containsObject:item.name]) continue;
        [seen addObject:item.name];
        item.path = ADBJoinPath(folder, item.name);
        [items addObject:item];
    }
    return items;
}

- (void)listFolder:(NSString *)path completion:(void (^)(BOOL ok, NSArray<RemoteItem *> *items, NSString *error))completion {
    NSString *serial = [self.serial copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *out = nil;
        NSString *err = nil;
        BOOL ok = [self runADB:@[@"-s", serial, @"shell", [self listCommandForPath:path]]
                         quiet:YES started:nil output:&out error:&err];
        NSArray<RemoteItem *> *items = ok ? [self parseListing:out inFolder:path] : @[];
        if (!ok) [self appendLog:[NSString stringWithFormat:@"LIST FAILED %@: %@", path, err]];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![serial isEqualToString:self.serial ?: @""]) return;
            if (ok) {
                self.listingCache[path] = items;
                [self.staleListings removeObject:path];
                [self countChildrenOf:items inFolder:path];
            }
            completion(ok, items, err);
        });
    });
}

// How many items each subfolder holds, for every subfolder of `folder` in one adb call.
- (void)countChildrenOf:(NSArray<RemoteItem *> *)items inFolder:(NSString *)folder {
    NSMutableDictionary<NSString *, RemoteItem *> *folders = [NSMutableDictionary dictionary];
    for (RemoteItem *item in items) if (item.directory) folders[item.name] = item;
    if (!folders.count) return;

    NSString *serial = [self.serial copy];
    NSString *command = [NSString stringWithFormat:
        @"cd %@ 2>/dev/null || exit 0; for d in */ .*/; do "
        @"case \"$d\" in ./|../|'*/'|'.*/') continue;; esac; "
        @"l=$(ls -A \"$d\" 2>/dev/null) || continue; "
        @"t=$(printf '%%s\\n' \"$l\" | grep -c .); v=$(printf '%%s\\n' \"$l\" | grep -v '^[.]' | grep -c .); "
        @"echo \"$t/$v/${d%%/}\"; done; exit 0", [self shellQuote:folder]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *out = nil;
        [self runQuietShell:command serial:serial output:&out];
        NSMutableDictionary<NSString *, NSArray *> *counts = [NSMutableDictionary dictionary];
        for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
            NSArray<NSString *> *parts = [line componentsSeparatedByString:@"/"];
            if (parts.count < 3) continue;
            NSString *name = [[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)] componentsJoinedByString:@"/"];
            counts[name] = @[@(parts[0].integerValue), @(parts[1].integerValue)];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![serial isEqualToString:self.serial ?: @""] || !counts.count) return;
            for (NSString *name in counts) {
                RemoteItem *item = folders[name];
                item.childCount = [counts[name][0] integerValue];
                item.visibleChildCount = [counts[name][1] integerValue];
            }
            if ([folder isEqualToString:self.currentPath]) {
                [self applyFilterKeepingSelection:YES];
            } else if (self.viewMode == ADBViewModeColumns && [self.columnPaths containsObject:folder]) {
                [self rebuildColumns];
            }
        });
    });
}

- (NSString *)countTextForItem:(RemoteItem *)item {
    if (!item.directory) return nil;
    NSInteger n = self.showHidden ? item.childCount : item.visibleChildCount;
    if (n < 0) return nil;
    if (n == 0) return @"Empty";
    return [NSString stringWithFormat:@"%@ item%@",
            [NSNumberFormatter localizedStringFromNumber:@(n) numberStyle:NSNumberFormatterDecimalStyle], n == 1 ? @"" : @"s"];
}

- (void)reloadSelecting:(NSArray<NSString *> *)names {
    if (![self canBrowse]) {
        [self updateEmptyState];
        return;
    }

    NSUInteger generation = ++self.listGeneration;
    NSString *path = [self.currentPath copy];
    NSArray<NSString *> *keep = names ?: [self currentFolderSelectionNames];

    self.loading = YES;
    // Only show "Loading…" if it takes a moment, so quick refreshes don't flicker.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.listGeneration == generation && self.loading) [self updateEmptyState];
    });

    [self listFolder:path completion:^(BOOL ok, NSArray<RemoteItem *> *items, NSString *err) {
        if (self.listGeneration != generation) return;
        self.loading = NO;
        self.loadError = ok ? nil : [self friendlyListError:err path:path];
        self.allItems = items;
        [self applyFilterKeepingSelection:NO];
        [self selectNames:keep];

        NSString *rename = self.pendingRenamePath;
        self.pendingRenamePath = nil;
        for (RemoteItem *item in self.items) {
            if (rename && [item.path isEqualToString:rename]) [self beginRenameOfItem:item];
        }
    }];
}

// After a change on the device, outer columns may be out of date; they are re-read
// on the next redraw but keep showing the old listing meanwhile.
- (void)invalidateListings {
    [self.staleListings addObjectsFromArray:self.listingCache.allKeys];
}

- (NSString *)friendlyListError:(NSString *)err path:(NSString *)path {
    NSString *e = err ?: @"";
    if ([e localizedCaseInsensitiveContainsString:@"Permission denied"]) {
        return @"Android doesn't allow reading this folder without root.";
    }
    if ([e localizedCaseInsensitiveContainsString:@"No such file"] || [e localizedCaseInsensitiveContainsString:@"can't cd"]) {
        return [NSString stringWithFormat:@"%@ doesn't exist on the device.", path];
    }
    if ([e localizedCaseInsensitiveContainsString:@"not a directory"]) {
        return [NSString stringWithFormat:@"%@ is a file, not a folder.", path];
    }
    if ([e localizedCaseInsensitiveContainsString:@"device"] && [e localizedCaseInsensitiveContainsString:@"not found"]) {
        return @"The device was disconnected.";
    }
    return e.length ? e : @"Unknown error";
}

- (NSArray<RemoteItem *> *)visibleItemsFrom:(NSArray<RemoteItem *> *)all filter:(NSString *)filter {
    NSMutableArray<RemoteItem *> *visible = [NSMutableArray array];
    for (RemoteItem *item in all) {
        if (item.hidden && !self.showHidden) continue;
        if (filter.length && ![item.name localizedCaseInsensitiveContainsString:filter]) continue;
        [visible addObject:item];
    }

    NSSortDescriptor *sort = self.table.sortDescriptors.firstObject;
    NSString *key = sort.key ?: @"name";
    BOOL ascending = sort ? sort.ascending : YES;

    [visible sortUsingComparator:^NSComparisonResult(RemoteItem *a, RemoteItem *b) {
        // Folders first, like Finder's "Keep folders on top".
        if (a.directory != b.directory) return a.directory ? NSOrderedAscending : NSOrderedDescending;
        NSComparisonResult r = NSOrderedSame;
        if ([key isEqualToString:@"modified"]) {
            r = [(a.modified ?: NSDate.distantPast) compare:(b.modified ?: NSDate.distantPast)];
        } else if ([key isEqualToString:@"size"]) {
            r = a.size < b.size ? NSOrderedAscending : (a.size > b.size ? NSOrderedDescending : NSOrderedSame);
        } else if ([key isEqualToString:@"kind"]) {
            r = [a.kind localizedStandardCompare:b.kind];
        }
        if (!ascending) r = (NSComparisonResult)-r;
        if (r == NSOrderedSame) r = [a.name localizedStandardCompare:b.name];
        if (r == NSOrderedSame) r = [a.name compare:b.name];
        return r;
    }];
    return visible;
}

- (void)applyFilterKeepingSelection:(BOOL)keepSelection {
    NSArray<NSString *> *selected = keepSelection ? [self currentFolderSelectionNames] : nil;
    self.items = [self visibleItemsFrom:self.allItems filter:self.filterText];
    [self reloadViews];
    if (selected) [self selectNames:selected];
    [self updateEmptyState];
    [self updateInfoLabel];
}

- (void)reloadViews {
    switch (self.viewMode) {
        case ADBViewModeIcons: [self.collection reloadData]; break;
        case ADBViewModeList: [self.table reloadData]; break;
        case ADBViewModeColumns: [self rebuildColumns]; break;
    }
}

- (void)selectNames:(NSArray<NSString *> *)names {
    if (!names) return;
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    NSSet *wanted = [NSSet setWithArray:names];
    [self.items enumerateObjectsUsingBlock:^(RemoteItem *item, NSUInteger i, BOOL *stop) {
        (void)stop;
        if ([wanted containsObject:item.name]) [rows addIndex:i];
    }];

    if (self.viewMode == ADBViewModeIcons) {
        NSMutableSet *paths = [NSMutableSet set];
        [rows enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
            (void)stop;
            [paths addObject:[NSIndexPath indexPathForItem:(NSInteger)i inSection:0]];
        }];
        self.collection.selectionIndexPaths = paths;
        if (paths.count) {
            [self.collection scrollToItemsAtIndexPaths:[NSSet setWithObject:[NSIndexPath indexPathForItem:(NSInteger)rows.firstIndex inSection:0]]
                                        scrollPosition:NSCollectionViewScrollPositionNearestHorizontalEdge];
        }
    } else {
        NSTableView *table = [self currentFolderTable];
        self.updatingColumns = YES;
        [table selectRowIndexes:rows byExtendingSelection:NO];
        self.updatingColumns = NO;
        if (rows.count) [table scrollRowToVisible:(NSInteger)rows.firstIndex];
    }
    [self fileViewSelectionChanged];
}

// The list showing the contents of the current folder (in column view, the last column).
- (NSTableView *)currentFolderTable {
    if (self.viewMode == ADBViewModeColumns && self.columnPaths.count && self.columnTables.count >= self.columnPaths.count) {
        return self.columnTables[self.columnPaths.count - 1];
    }
    return self.table;
}

- (NSArray<NSString *> *)currentFolderSelectionNames {
    NSMutableArray *names = [NSMutableArray array];
    if (self.viewMode == ADBViewModeIcons) {
        for (NSIndexPath *path in self.collection.selectionIndexPaths) {
            if ((NSUInteger)path.item < self.items.count) [names addObject:self.items[(NSUInteger)path.item].name];
        }
        return names;
    }
    NSTableView *table = [self currentFolderTable];
    NSArray<RemoteItem *> *items = [self itemsForTable:table];
    [table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        (void)stop;
        if (i < items.count) [names addObject:items[i].name];
    }];
    return names;
}

- (NSArray<RemoteItem *> *)itemsForTable:(NSTableView *)table {
    if (table == self.table) return self.items;
    NSUInteger index = [self.columnTables indexOfObject:(FileTableView *)table];
    if (index != NSNotFound && index < self.columnItems.count) return self.columnItems[index];
    return @[];
}

- (NSString *)folderForTable:(NSTableView *)table {
    NSUInteger index = [self.columnTables indexOfObject:(FileTableView *)table];
    if (index != NSNotFound && index < self.columnPaths.count) return self.columnPaths[index];
    return self.currentPath;
}

- (NSArray<RemoteItem *> *)selectedItemsInTable:(NSTableView *)table {
    NSArray<RemoteItem *> *items = [self itemsForTable:table];
    NSMutableArray *selected = [NSMutableArray array];
    [table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        (void)stop;
        if (i < items.count) [selected addObject:items[i]];
    }];
    return selected;
}

// In column view the column with keyboard focus decides what is selected, like in Finder:
// click a folder and its contents open on the right, but the folder stays the selection.
- (FileTableView *)activeColumnTable {
    NSUInteger count = MIN(self.columnPaths.count, self.columnTables.count);
    if (!count) return nil;
    NSUInteger index = [self.columnTables indexOfObject:(FileTableView *)self.window.firstResponder];
    if (index != NSNotFound && index < count && self.columnTables[index].selectedRowIndexes.count) {
        return self.columnTables[index];
    }
    return self.columnTables[count - 1];
}

- (NSTableView *)activeTable {
    return self.viewMode == ADBViewModeColumns ? [self activeColumnTable] : self.table;
}

- (NSArray<RemoteItem *> *)selectedItems {
    if (self.viewMode == ADBViewModeIcons) {
        NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
        for (NSIndexPath *path in self.collection.selectionIndexPaths) [rows addIndex:(NSUInteger)path.item];
        NSMutableArray *selected = [NSMutableArray array];
        [rows enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
            (void)stop;
            if (i < self.items.count) [selected addObject:self.items[i]];
        }];
        return selected;
    }
    return [self selectedItemsInTable:[self activeTable]];
}

- (void)fileViewSelectionChanged {
    [self updateInfoLabel];
    [self updatePreviewPane];

    // Arrow keys under an open preview: folders get the folder panel, files Quick Look.
    BOOL folderShown = self.folderPanel.visible;
    BOOL quickLookShown = [QLPreviewPanel sharedPreviewPanelExists] && [QLPreviewPanel sharedPreviewPanel].visible;
    if (!folderShown && !quickLookShown) return;
    NSArray<RemoteItem *> *selected = [self selectedItems];
    if (selected.count == 1 && selected.firstObject.directory) {
        // Moving from a file to a folder: the folder panel takes Quick Look's place without a zoom.
        if (quickLookShown) [[QLPreviewPanel sharedPreviewPanel] orderOut:nil];
        [self showFolderPanelFor:selected.firstObject animated:!quickLookShown && !folderShown];
    } else if (selected.count) {
        if (folderShown) [self hideFolderPanelAnimated:NO];
        [self preparePreviewAndShow:!quickLookShown];
    }
}

- (void)updateEmptyState {
    NSString *symbol = nil;
    NSString *title = nil;
    NSString *subtitle = nil;

    if (!self.serial.length) {
        if ([self.deviceState isEqualToString:@"noadb"]) {
            symbol = @"wrench.and.screwdriver";
            title = @"adb isn't installed";
            subtitle = @"Install Android Platform Tools with “brew install android-platform-tools”, then reopen the app.";
        } else if ([self.deviceState isEqualToString:@"unauthorized"]) {
            symbol = @"lock.iphone";
            title = @"Waiting for permission";
            subtitle = @"Unlock the phone and tap “Allow” on the USB debugging prompt.";
        } else if ([self.deviceState isEqualToString:@"offline"]) {
            symbol = @"bolt.horizontal.circle";
            title = @"Device offline";
            subtitle = @"Reconnect the cable or toggle USB debugging off and on.";
        } else if (!self.deviceState) {
            symbol = @"magnifyingglass";
            title = @"Looking for devices…";
        } else {
            symbol = @"cable.connector";
            title = @"Connect an Android device";
            subtitle = @"Plug in a phone with USB debugging enabled. Its files will appear here, "
                       @"and you can drag them to and from the Mac.";
        }
    } else if (self.loadError) {
        symbol = @"exclamationmark.triangle";
        title = @"Can't open this folder";
        subtitle = self.loadError;
    } else if (self.loading && !self.allItems.count) {
        title = @"Loading…";
    } else if (!self.items.count) {
        if (self.filterText.length) {
            symbol = @"magnifyingglass";
            title = @"No matches";
            subtitle = [NSString stringWithFormat:@"Nothing in this folder matches “%@”.", self.filterText];
        } else {
            symbol = @"tray.and.arrow.down";
            title = @"This folder is empty";
            subtitle = @"Drop files here to copy them to the device.";
        }
    }

    // Column view shows empty folders as empty columns, like Finder.
    if (self.viewMode == ADBViewModeColumns && self.serial.length && !self.loadError) title = nil;
    self.emptyView.hidden = title == nil;
    [self.emptyView setSymbol:symbol title:title subtitle:subtitle];
}

- (void)updateInfoLabel {
    if (![self canBrowse]) {
        self.infoLabel.stringValue = @"";
        return;
    }
    NSUInteger count = self.items.count;
    NSUInteger selected = [self selectedItems].count;
    NSMutableString *text = [NSMutableString string];

    if (selected) {
        unsigned long long bytes = 0;
        for (RemoteItem *item in [self selectedItems]) if (!item.directory) bytes += item.size;
        [text appendFormat:@"%lu of %lu selected", (unsigned long)selected, (unsigned long)count];
        if (bytes) [text appendFormat:@", %@", ADBFormatBytes(bytes)];
    } else {
        [text appendFormat:@"%lu item%@", (unsigned long)count, count == 1 ? @"" : @"s"];
    }
    unsigned long long free = [self.deviceInfo[self.serial][@"free"] unsignedLongLongValue];
    if (free) [text appendFormat:@", %@ available", ADBFormatBytes(free)];
    self.infoLabel.stringValue = text;
}

- (void)toggleHidden:(id)sender {
    (void)sender;
    self.showHidden = !self.showHidden;
    [NSUserDefaults.standardUserDefaults setBool:self.showHidden forKey:kShowHiddenKey];
    [self applyFilterKeepingSelection:YES];
}

#pragma mark View modes

- (void)setViewModeFromMenu:(NSMenuItem *)sender {
    [self switchToViewMode:(ADBViewMode)sender.tag];
}

- (void)viewControlChanged:(NSSegmentedControl *)sender {
    [self switchToViewMode:(ADBViewMode)sender.selectedSegment];
}

- (void)switchToViewMode:(ADBViewMode)mode {
    if (mode == self.viewMode) return;
    NSArray<NSString *> *selected = [self currentFolderSelectionNames];
    [self cancelRename];
    self.viewMode = mode;
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:kViewModeKey];
    [self applyViewMode];
    [self selectNames:selected];
}

- (void)applyViewMode {
    self.viewControl.selectedSegment = self.viewMode;
    self.tableScroll.hidden = self.viewMode != ADBViewModeList;
    self.collectionScroll.hidden = self.viewMode != ADBViewModeIcons;
    self.columnScroll.hidden = self.viewMode != ADBViewModeColumns;
    [self reloadViews];
    [self updateEmptyState];
    NSView *focus = self.viewMode == ADBViewModeIcons ? self.collection
                  : (self.viewMode == ADBViewModeList ? self.table : [self currentFolderTable]);
    // Keys go to the files, not to the search field, from the start.
    self.window.initialFirstResponder = focus;
    if (focus) [self.window makeFirstResponder:focus];
}

#pragma mark Icon view

- (NSInteger)collectionView:(NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    (void)collectionView;
    (void)section;
    return (NSInteger)self.items.count;
}

- (NSCollectionViewItem *)collectionView:(NSCollectionView *)collectionView
     itemForRepresentedObjectAtIndexPath:(NSIndexPath *)indexPath {
    IconItem *item = [collectionView makeItemWithIdentifier:@"icon" forIndexPath:indexPath];
    IconItemView *view = (IconItemView *)item.view;
    view.controller = self;
    view.item = self.items[(NSUInteger)indexPath.item];
    view.selected = item.selected;
    return item;
}

- (void)collectionView:(NSCollectionView *)collectionView didSelectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths {
    (void)collectionView;
    (void)indexPaths;
    [self fileViewSelectionChanged];
}

- (void)collectionView:(NSCollectionView *)collectionView didDeselectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths {
    (void)collectionView;
    (void)indexPaths;
    [self fileViewSelectionChanged];
}

- (BOOL)collectionView:(NSCollectionView *)collectionView canDragItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths
             withEvent:(NSEvent *)event {
    (void)collectionView;
    (void)indexPaths;
    (void)event;
    return self.serial.length > 0;
}

- (id<NSPasteboardWriting>)collectionView:(NSCollectionView *)collectionView
       pasteboardWriterForItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)collectionView;
    if (!self.serial.length || (NSUInteger)indexPath.item >= self.items.count) return nil;
    return [self promiseForItem:self.items[(NSUInteger)indexPath.item]];
}

- (NSDragOperation)collectionView:(NSCollectionView *)collectionView
                     validateDrop:(id<NSDraggingInfo>)info
                proposedIndexPath:(NSIndexPath **)proposedDropIndexPath
                    dropOperation:(NSCollectionViewDropOperation *)proposedDropOperation {
    (void)collectionView;
    if (self.loadError) return NSDragOperationNone;
    NSInteger index = (*proposedDropIndexPath).item;
    if (*proposedDropOperation == NSCollectionViewDropOn && index >= 0 && (NSUInteger)index < self.items.count &&
        self.items[(NSUInteger)index].directory) {
        NSDragOperation op = [self dropOperationFor:info folder:self.items[(NSUInteger)index].path];
        if (op != NSDragOperationNone) return op;
    }
    // Between items means "into this folder".
    *proposedDropOperation = NSCollectionViewDropBefore;
    *proposedDropIndexPath = [NSIndexPath indexPathForItem:(NSInteger)self.items.count inSection:0];
    return [self dropOperationFor:info folder:self.currentPath];
}

- (BOOL)collectionView:(NSCollectionView *)collectionView
            acceptDrop:(id<NSDraggingInfo>)info
             indexPath:(NSIndexPath *)indexPath
         dropOperation:(NSCollectionViewDropOperation)dropOperation {
    (void)collectionView;
    NSString *dest = self.currentPath;
    NSInteger index = indexPath.item;
    if (dropOperation == NSCollectionViewDropOn && index >= 0 && (NSUInteger)index < self.items.count &&
        self.items[(NSUInteger)index].directory) {
        dest = self.items[(NSUInteger)index].path;
    }
    return [self performDrop:info folder:dest];
}

#pragma mark Column view

static const CGFloat kColumnWidth = 220;
static const CGFloat kPreviewWidth = 280;

// From the storage root (or "/") down to the current folder.
- (NSArray<NSString *> *)columnPathsFor:(NSString *)path {
    if (!path.length || !self.serial.length) return @[];
    NSString *base = @"/";
    if (ADBPathIsInside(path, kStorageRoot)) base = kStorageRoot;
    for (NSDictionary *place in [self placesForSerial:self.serial]) {
        if ([place[@"symbol"] isEqualToString:@"sdcard"] && ADBPathIsInside(path, place[@"path"])) base = place[@"path"];
    }
    NSMutableArray *paths = [NSMutableArray arrayWithObject:base];
    NSString *walk = base;
    for (NSString *part in [[path substringFromIndex:base.length] componentsSeparatedByString:@"/"]) {
        if (!part.length) continue;
        walk = ADBJoinPath(walk, part);
        [paths addObject:walk];
    }
    return paths;
}

- (FileTableView *)columnTableAt:(NSUInteger)index {
    while (self.columnTables.count <= index) {
        NSUInteger i = self.columnTables.count;
        FileTableView *t = [FileTableView new];
        t.controller = self;
        t.columnTable = YES;
        t.dataSource = self;
        t.delegate = self;
        t.headerView = nil;
        t.style = NSTableViewStyleFullWidth;
        t.rowHeight = 22;
        t.intercellSpacing = NSMakeSize(0, 1);
        t.allowsMultipleSelection = YES;
        t.backgroundColor = NSColor.controlBackgroundColor;
        t.target = self;
        t.doubleAction = @selector(doubleClick:);
        NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:@"colname"];
        c.resizingMask = NSTableColumnAutoresizingMask;
        [t addTableColumn:c];
        t.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
        [t registerForDraggedTypes:[self fileDragTypes]];
        [t setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
        [t setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];
        t.draggingDestinationFeedbackStyle = NSTableViewDraggingDestinationFeedbackStyleRegular;

        NSScrollView *scroll = [NSScrollView new];
        scroll.hasVerticalScroller = YES;
        scroll.autohidesScrollers = YES;
        scroll.automaticallyAdjustsContentInsets = NO;
        scroll.drawsBackground = NO;
        scroll.documentView = t;
        scroll.translatesAutoresizingMaskIntoConstraints = NO;

        NSView *unit = [NSView new];
        unit.translatesAutoresizingMaskIntoConstraints = NO;
        NSBox *line = [self separator];
        [unit addSubview:scroll];
        [unit addSubview:line];
        [self.columnDoc addSubview:unit];
        [NSLayoutConstraint activateConstraints:@[
            [scroll.topAnchor constraintEqualToAnchor:unit.topAnchor],
            [scroll.bottomAnchor constraintEqualToAnchor:unit.bottomAnchor],
            [scroll.leadingAnchor constraintEqualToAnchor:unit.leadingAnchor],
            [scroll.trailingAnchor constraintEqualToAnchor:line.leadingAnchor],
            [line.topAnchor constraintEqualToAnchor:unit.topAnchor],
            [line.bottomAnchor constraintEqualToAnchor:unit.bottomAnchor],
            [line.trailingAnchor constraintEqualToAnchor:unit.trailingAnchor],
            [line.widthAnchor constraintEqualToConstant:1],
            [unit.topAnchor constraintEqualToAnchor:self.columnDoc.topAnchor],
            [unit.bottomAnchor constraintEqualToAnchor:self.columnDoc.bottomAnchor],
            [unit.leadingAnchor constraintEqualToAnchor:self.columnDoc.leadingAnchor constant:kColumnWidth * i],
            [unit.widthAnchor constraintEqualToConstant:kColumnWidth],
        ]];
        [self.columnTables addObject:t];
        [self.columnUnits addObject:unit];
    }
    return self.columnTables[index];
}

- (void)rebuildColumns {
    NSArray<NSString *> *paths = [self columnPathsFor:self.currentPath];
    NSMutableArray *itemLists = [NSMutableArray array];
    for (NSUInteger i = 0; i < paths.count; i++) {
        if (i == paths.count - 1) {
            [itemLists addObject:self.items];
            continue;
        }
        NSArray *cached = self.listingCache[paths[i]];
        if (!cached || [self.staleListings containsObject:paths[i]]) [self loadColumnListing:paths[i]];
        [itemLists addObject:cached ? [self visibleItemsFrom:cached filter:nil] : @[]];
    }

    NSString *previousLast = self.columnPaths.lastObject;
    self.columnPaths = paths;
    self.columnItems = itemLists;

    self.updatingColumns = YES;
    for (NSUInteger i = 0; i < MAX(paths.count, self.columnTables.count); i++) {
        FileTableView *t = [self columnTableAt:i];
        self.columnUnits[i].hidden = i >= paths.count;
        if (i >= paths.count) {
            [t reloadData];
            continue;
        }
        BOOL last = i == paths.count - 1;
        NSArray<NSString *> *keep = (last && [previousLast isEqualToString:paths[i]])
            ? [[self selectedItemsInTable:t] valueForKey:@"name"] : nil;
        [t reloadData];

        NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
        NSArray<RemoteItem *> *list = itemLists[i];
        for (NSUInteger r = 0; r < list.count; r++) {
            NSString *name = list[r].name;
            if (last ? [keep containsObject:name] : [name isEqualToString:paths[i + 1].lastPathComponent]) [rows addIndex:r];
        }
        [t selectRowIndexes:rows byExtendingSelection:NO];
        if (rows.count) [t scrollRowToVisible:(NSInteger)rows.firstIndex];
    }
    self.updatingColumns = NO;

    self.columnContentWidth.constant = kColumnWidth * paths.count + (self.previewPane.hidden ? 0 : kPreviewWidth);
    self.previewLeading.constant = kColumnWidth * paths.count;
    [self updatePreviewPane];

    // Keep the deepest column in sight.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.columnDoc layoutSubtreeIfNeeded];
        CGFloat right = kColumnWidth * self.columnPaths.count + (self.previewPane.hidden ? 0 : kPreviewWidth);
        [self.columnDoc scrollRectToVisible:NSMakeRect(MAX(0, right - kColumnWidth), 0, kColumnWidth, 1)];
    });
}

- (void)loadColumnListing:(NSString *)path {
    if ([self.listingPending containsObject:path]) return;
    [self.listingPending addObject:path];
    [self listFolder:path completion:^(BOOL ok, NSArray<RemoteItem *> *items, NSString *error) {
        (void)items;
        (void)error;
        [self.listingPending removeObject:path];
        if (!ok) [self.staleListings removeObject:path];
        if (self.viewMode == ADBViewModeColumns && [self.columnPaths containsObject:path]) [self rebuildColumns];
    }];
}

- (NSView *)columnCellForTable:(NSTableView *)tableView row:(NSInteger)row {
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"colname" owner:self];
    if (!cell) {
        cell = [NSTableCellView new];
        cell.identifier = @"colname";
        NSImageView *icon = [NSImageView new];
        icon.imageScaling = NSImageScaleProportionallyUpOrDown;
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *field = [NSTextField labelWithString:@""];
        field.font = [NSFont systemFontOfSize:13];
        field.lineBreakMode = NSLineBreakByTruncatingMiddle;
        field.translatesAutoresizingMaskIntoConstraints = NO;
        field.target = self;
        field.action = @selector(renameEdited:);
        field.delegate = self;
        [field setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSImageView *chevron = [NSImageView imageViewWithImage:ADBSymbol(@"chevron.right", 10, NSFontWeightSemibold)];
        chevron.contentTintColor = NSColor.tertiaryLabelColor;
        chevron.identifier = @"chevron";
        chevron.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *count = [NSTextField labelWithString:@""];
        count.identifier = @"count";
        count.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
        count.textColor = NSColor.tertiaryLabelColor;
        count.translatesAutoresizingMaskIntoConstraints = NO;
        [count setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
        [cell addSubview:count];
        [cell addSubview:icon];
        [cell addSubview:field];
        [cell addSubview:chevron];
        cell.imageView = icon;
        cell.textField = field;
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:8],
            [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:18],
            [icon.heightAnchor constraintEqualToConstant:18],
            [field.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:6],
            [field.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [field.trailingAnchor constraintLessThanOrEqualToAnchor:count.leadingAnchor constant:-4],
            [count.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-4],
            [count.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [chevron.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
            [chevron.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    RemoteItem *item = [self itemsForTable:tableView][(NSUInteger)row];
    NSView *chevron = nil;
    for (NSView *v in cell.subviews) if ([v.identifier isEqualToString:@"chevron"]) chevron = v;
    chevron.hidden = !item.directory;
    for (NSView *v in cell.subviews) {
        if ([v.identifier isEqualToString:@"count"]) {
            NSInteger n = self.showHidden ? item.childCount : item.visibleChildCount;
            ((NSTextField *)v).stringValue = item.directory && n >= 0 ? [NSString stringWithFormat:@"%ld", (long)n] : @"";
        }
    }
    cell.imageView.image = [self thumbnailForItem:item request:YES] ?: ADBIconForItem(item);
    cell.imageView.alphaValue = item.hidden ? 0.55 : 1.0;
    cell.textField.stringValue = item.name;
    cell.textField.alphaValue = item.hidden ? 0.55 : 1.0;
    cell.textField.editable = [item.path isEqualToString:self.renamingPath];
    return cell;
}

// A click in column N: a folder opens to the right; a file makes column N's folder
// the current one and shows the file in the preview.
- (void)columnSelectionChanged:(FileTableView *)table {
    NSUInteger index = [self.columnTables indexOfObject:table];
    if (index == NSNotFound || index >= self.columnPaths.count) return;
    NSArray<RemoteItem *> *selected = [self selectedItemsInTable:table];
    BOOL last = index == self.columnPaths.count - 1;

    if (selected.count == 1 && selected.firstObject.directory) {
        if (![selected.firstObject.path isEqualToString:self.currentPath]) [self navigateTo:selected.firstObject.path];
        return;
    }
    if (!last) {
        if (self.currentPath) [self.backStack addObject:self.currentPath];
        [self.forwardStack removeAllObjects];
        [self showFolder:self.columnPaths[index] selecting:[selected valueForKey:@"name"]];
        return;
    }
    [self fileViewSelectionChanged];
}

- (BOOL)handleColumnKey:(NSEvent *)event table:(FileTableView *)table {
    NSString *chars = event.charactersIgnoringModifiers;
    if (chars.length != 1) return NO;
    unichar c = [chars characterAtIndex:0];
    NSUInteger index = [self.columnTables indexOfObject:table];
    if (index == NSNotFound) return NO;

    if (c == NSRightArrowFunctionKey) {
        if (index + 1 < self.columnPaths.count) {
            FileTableView *next = self.columnTables[index + 1];
            if ([self itemsForTable:next].count) {
                [self.window makeFirstResponder:next];
                if (next.selectedRow < 0) [next selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
            }
        }
        return YES;
    }
    if (c == NSLeftArrowFunctionKey) {
        if (index > 0) {
            self.updatingColumns = YES;
            [table deselectAll:nil];
            self.updatingColumns = NO;
            [self.window makeFirstResponder:self.columnTables[index - 1]];
            if (![self.currentPath isEqualToString:self.columnPaths[index]]) [self navigateTo:self.columnPaths[index]];
            else [self rebuildColumns];
            [self fileViewSelectionChanged];
        }
        return YES;
    }
    return NO;
}

#pragma mark Preview pane

- (void)buildPreviewPane {
    self.previewPane = [NSView new];
    self.previewPane.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewPane.hidden = YES;

    self.previewImage = [NSImageView new];
    self.previewImage.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.previewImage.translatesAutoresizingMaskIntoConstraints = NO;

    self.previewName = [NSTextField wrappingLabelWithString:@""];
    self.previewName.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    self.previewName.alignment = NSTextAlignmentCenter;
    self.previewName.selectable = YES;
    self.previewName.translatesAutoresizingMaskIntoConstraints = NO;

    self.previewInfo = [NSTextField wrappingLabelWithString:@""];
    self.previewInfo.font = [NSFont systemFontOfSize:12];
    self.previewInfo.textColor = NSColor.secondaryLabelColor;
    self.previewInfo.selectable = YES;
    self.previewInfo.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *v in @[self.previewImage, self.previewName, self.previewInfo]) [self.previewPane addSubview:v];
    [self.columnDoc addSubview:self.previewPane];
    self.previewLeading = [self.previewPane.leadingAnchor constraintEqualToAnchor:self.columnDoc.leadingAnchor];
    [NSLayoutConstraint activateConstraints:@[
        self.previewLeading,
        [self.previewPane.topAnchor constraintEqualToAnchor:self.columnDoc.topAnchor],
        [self.previewPane.bottomAnchor constraintEqualToAnchor:self.columnDoc.bottomAnchor],
        [self.previewPane.widthAnchor constraintEqualToConstant:kPreviewWidth],
        [self.previewImage.topAnchor constraintEqualToAnchor:self.previewPane.topAnchor constant:20],
        [self.previewImage.leadingAnchor constraintEqualToAnchor:self.previewPane.leadingAnchor constant:20],
        [self.previewImage.trailingAnchor constraintEqualToAnchor:self.previewPane.trailingAnchor constant:-20],
        [self.previewImage.heightAnchor constraintEqualToConstant:240],
        [self.previewName.topAnchor constraintEqualToAnchor:self.previewImage.bottomAnchor constant:14],
        [self.previewName.leadingAnchor constraintEqualToAnchor:self.previewPane.leadingAnchor constant:16],
        [self.previewName.trailingAnchor constraintEqualToAnchor:self.previewPane.trailingAnchor constant:-16],
        [self.previewInfo.topAnchor constraintEqualToAnchor:self.previewName.bottomAnchor constant:10],
        [self.previewInfo.leadingAnchor constraintEqualToAnchor:self.previewPane.leadingAnchor constant:16],
        [self.previewInfo.trailingAnchor constraintEqualToAnchor:self.previewPane.trailingAnchor constant:-16],
    ]];
}

- (void)updatePreviewPane {
    RemoteItem *item = nil;
    if (self.viewMode == ADBViewModeColumns) {
        NSArray<RemoteItem *> *selected = [self selectedItems];
        if (selected.count == 1 && !selected.firstObject.directory) item = selected.firstObject;
    }
    BOOL show = item != nil;
    BOOL changed = self.previewPane.hidden == show;
    self.previewPane.hidden = !show;
    self.previewItem = item;
    if (changed) {
        self.columnContentWidth.constant = kColumnWidth * self.columnPaths.count + (show ? kPreviewWidth : 0);
        if (show) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.columnDoc layoutSubtreeIfNeeded];
                [self.columnDoc scrollRectToVisible:self.previewPane.frame];
            });
        }
    }
    if (!item) return;

    self.previewImage.image = [self thumbnailForItem:item large:YES request:YES] ?: ADBIconForItem(item);
    self.previewName.stringValue = item.name;
    NSMutableArray *lines = [NSMutableArray arrayWithObject:item.kind];
    if (item.detailsKnown) [lines addObject:ADBFormatBytes(item.size)];
    if (item.modified) [lines addObject:[NSString stringWithFormat:@"Modified %@", [self.dateFormatter stringFromDate:item.modified]]];
    [lines addObject:item.path];
    self.previewInfo.stringValue = [lines componentsJoinedByString:@"\n"];
}

#pragma mark Thumbnails
//
// Previews are made on the Mac from as few bytes as possible and kept on the Mac only:
// ~/Library/Caches/ADBFinder/Thumbnails/<device>/. A device's folder is deleted when
// the phone hasn't been connected for 30 days, and the whole cache stays under 1 GB.
// Requests are served newest first, and ones that scrolled out of sight are dropped.

- (NSData *)adbData:(NSArray<NSString *> *)arguments {
    NSData *data = nil;
    int status = 0;
    if (ADBSpawnCapture([self adbPath], arguments, nil, &data, &status) != 0 || status != 0) return nil;
    return data.length ? data : nil;
}

// Bytes [offset, offset + length) of a file on the device.
- (NSData *)readRemote:(NSString *)path offset:(uint64_t)offset length:(uint64_t)length serial:(NSString *)serial {
    if (!length) return nil;
    const uint64_t block = 4096;
    uint64_t first = offset / block, last = (offset + length + block - 1) / block;
    NSString *command = [NSString stringWithFormat:@"dd if=%@ bs=%llu skip=%llu count=%llu 2>/dev/null",
                         [self shellQuote:path], block, first, last - first];
    NSData *data = [self adbData:@[@"-s", serial, @"exec-out", command]];
    uint64_t skip = offset - first * block;
    if (data.length < skip + length) return nil;
    return [data subdataWithRange:NSMakeRange((NSUInteger)skip, (NSUInteger)length)];
}

- (NSString *)thumbnailRoot {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [[caches stringByAppendingPathComponent:@"ADBFinder"] stringByAppendingPathComponent:@"Thumbnails"];
}

- (NSString *)thumbnailFolderFor:(NSString *)serial {
    NSString *safe = [[serial componentsSeparatedByCharactersInSet:
                       [NSCharacterSet characterSetWithCharactersInString:@"/:"]] componentsJoinedByString:@"_"];
    return [[self thumbnailRoot] stringByAppendingPathComponent:safe];
}

- (NSString *)thumbnailKeyFor:(RemoteItem *)item large:(BOOL)large {
    return [NSString stringWithFormat:@"%@|%@|%llu|%.0f|%d", self.serial, item.path, item.size,
            item.modified.timeIntervalSince1970, large];
}

- (NSString *)thumbnailFileFor:(NSString *)key serial:(NSString *)serial {
    return [[self thumbnailFolderFor:serial] stringByAppendingPathComponent:ADBSHA1(key)];
}

// Remembers when the phone was last connected; its thumbnails expire 30 days later.
- (void)markThumbnailsUsed:(NSString *)serial {
    NSString *folder = [self thumbnailFolderFor:serial];
    [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSDate date].description writeToFile:[folder stringByAppendingPathComponent:@".last-connected"]
                                atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)pruneThumbnailCache {
    NSString *root = [self thumbnailRoot];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-kThumbnailKeepSeconds];
        NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
        unsigned long long total = 0;

        for (NSString *device in [fm contentsOfDirectoryAtPath:root error:nil]) {
            NSString *folder = [root stringByAppendingPathComponent:device];
            NSDate *seen = [[fm attributesOfItemAtPath:[folder stringByAppendingPathComponent:@".last-connected"] error:nil] fileModificationDate];
            if (!seen) seen = [[fm attributesOfItemAtPath:folder error:nil] fileModificationDate];
            if ([seen compare:cutoff] == NSOrderedAscending) {
                [fm removeItemAtPath:folder error:nil];
                [self appendLog:[NSString stringWithFormat:@"THUMBNAILS EXPIRED for %@", device]];
                continue;
            }
            for (NSString *name in [fm contentsOfDirectoryAtPath:folder error:nil]) {
                if ([name hasPrefix:@"."]) continue;
                NSString *path = [folder stringByAppendingPathComponent:name];
                NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
                total += attrs.fileSize;
                [files addObject:@{@"path": path, @"size": @(attrs.fileSize), @"date": attrs.fileModificationDate ?: NSDate.distantPast}];
            }
        }
        if (total <= kThumbnailCacheLimit) return;
        // Over the limit: drop the oldest down to 80 %.
        [files sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"date"] compare:b[@"date"]];
        }];
        for (NSDictionary *f in files) {
            if (total <= kThumbnailCacheLimit * 8 / 10) break;
            [fm removeItemAtPath:f[@"path"] error:nil];
            total -= [f[@"size"] unsignedLongLongValue];
        }
    });
}

- (BOOL)hasThumbnailKind:(RemoteItem *)item {
    return !item.directory && item.detailsKnown &&
           (ADBIsImageName(item.name) || ADBIsVideoName(item.name) || ADBIsPDFName(item.name));
}

- (NSImage *)thumbnailForItem:(RemoteItem *)item request:(BOOL)request {
    return [self thumbnailForItem:item large:NO request:request];
}

// Cached preview of a photo, video or PDF, or nil; with `request`, a missing one is
// fetched in the background and the views are updated when it arrives.
- (NSImage *)thumbnailForItem:(RemoteItem *)item large:(BOOL)large request:(BOOL)request {
    if (!self.serial.length || ![self hasThumbnailKind:item]) return nil;
    if (!ADBIsImageName(item.name)) large = NO;

    NSString *key = [self thumbnailKeyFor:item large:large];
    id cached = [self.thumbCache objectForKey:key];
    if ([cached isKindOfClass:NSImage.class]) return cached;
    NSImage *fallback = large ? [self thumbnailForItem:item large:NO request:request] : nil;
    if (cached) return fallback;

    // Made in an earlier session?
    NSString *file = [self thumbnailFileFor:key serial:self.serial];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:file]) {
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:file];
        if (image) {
            [self.thumbCache setObject:image forKey:key cost:(NSUInteger)(image.size.width * image.size.height * 4)];
            return image;
        }
    }
    if ([fm fileExistsAtPath:[file stringByAppendingPathExtension:@"none"]]) {
        [self.thumbCache setObject:NSNull.null forKey:key];
        return fallback;
    }

    if (request && ![self.thumbPending containsObject:key]) {
        [self.thumbPending addObject:key];
        [self.thumbStack addObject:@{@"item": item, @"large": @(large), @"key": key, @"serial": self.serial}];
        [self pumpThumbnails];
    }
    return fallback;
}

- (void)pumpThumbnails {
    while (self.thumbWorkers < 3 && self.thumbStack.count) {
        self.thumbWorkers++;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self thumbnailWorker];
        });
    }
}

// Paths whose thumbnails are on screen right now.
- (NSSet<NSString *> *)pathsOnScreen {
    NSMutableSet *paths = [NSMutableSet set];
    if (self.previewItem) [paths addObject:self.previewItem.path];
    if (self.viewMode == ADBViewModeIcons) {
        for (NSCollectionViewItem *visible in self.collection.visibleItems) {
            RemoteItem *item = ((IconItemView *)visible.view).item;
            if (item) [paths addObject:item.path];
        }
        return paths;
    }
    NSArray<NSTableView *> *tables = self.viewMode == ADBViewModeList
        ? @[self.table] : [self.columnTables subarrayWithRange:NSMakeRange(0, MIN(self.columnPaths.count, self.columnTables.count))];
    for (NSTableView *table in tables) {
        NSArray<RemoteItem *> *items = [self itemsForTable:table];
        NSRange rows = [table rowsInRect:table.visibleRect];
        for (NSUInteger i = rows.location; i < NSMaxRange(rows) && i < items.count; i++) [paths addObject:items[i].path];
    }
    return paths;
}

// Next job: the newest request still on screen, or several camera JPEGs at once.
- (NSArray<NSDictionary *> *)takeThumbnailJob {
    NSSet<NSString *> *onScreen = [self pathsOnScreen];
    NSMutableArray<NSDictionary *> *job = [NSMutableArray array];
    while (self.thumbStack.count) {
        NSDictionary *request = self.thumbStack.lastObject;
        [self.thumbStack removeLastObject];
        RemoteItem *item = request[@"item"];
        if (![request[@"serial"] isEqualToString:self.serial ?: @""] || ![onScreen containsObject:item.path]) {
            // Asked for again if it scrolls back into view.
            [self.thumbPending removeObject:request[@"key"]];
            continue;
        }
        [job addObject:request];
        break;
    }
    NSDictionary *first = job.firstObject;
    if (!first || [first[@"large"] boolValue] || !ADBIsJPEGName(((RemoteItem *)first[@"item"]).name)) return job;

    for (NSInteger i = (NSInteger)self.thumbStack.count - 1; i >= 0 && job.count < kThumbnailBatch; i--) {
        NSDictionary *request = self.thumbStack[(NSUInteger)i];
        RemoteItem *item = request[@"item"];
        if (![request[@"large"] boolValue] && ADBIsJPEGName(item.name) && [onScreen containsObject:item.path] &&
            [request[@"serial"] isEqualToString:first[@"serial"]]) {
            [job addObject:request];
            [self.thumbStack removeObjectAtIndex:(NSUInteger)i];
        }
    }
    return job;
}

- (void)thumbnailWorker {
    for (;;) {
        __block NSArray<NSDictionary *> *job = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            job = [self takeThumbnailJob];
            if (!job.count) self.thumbWorkers--;
        });
        if (!job.count) return;

        NSString *serial = job.firstObject[@"serial"];
        NSMutableDictionary<NSString *, id> *results = [NSMutableDictionary dictionary];

        if (job.count > 1) {
            // One adb call for the heads of many photos; the lengths are known from the listing.
            NSMutableString *command = [NSMutableString stringWithString:@"for f in"];
            unsigned long long expected = 0;
            for (NSDictionary *request in job) {
                RemoteItem *item = request[@"item"];
                [command appendFormat:@" %@", [self shellQuote:item.path]];
                expected += MIN(item.size, kJPEGHeadBytes);
            }
            [command appendFormat:@"; do head -c %llu \"$f\"; done", kJPEGHeadBytes];
            NSData *data = [self adbData:@[@"-s", serial, @"exec-out", command]];
            if (data.length == expected) {
                NSUInteger offset = 0;
                for (NSDictionary *request in job) {
                    RemoteItem *item = request[@"item"];
                    NSUInteger length = (NSUInteger)MIN(item.size, kJPEGHeadBytes);
                    CGImageRef thumb = ADBCreateExifThumbnail([data subdataWithRange:NSMakeRange(offset, length)]);
                    offset += length;
                    if (thumb) {
                        results[request[@"key"]] = (__bridge_transfer id)thumb;
                    }
                }
            }
        }
        for (NSDictionary *request in job) {
            if (results[request[@"key"]]) continue;
            CGImageRef thumb = [self newThumbnailFor:request[@"item"] serial:serial large:[request[@"large"] boolValue]];
            results[request[@"key"]] = thumb ? (__bridge_transfer id)thumb : NSNull.null;
        }

        // Keep them on the Mac for next time.
        NSString *folder = [self thumbnailFolderFor:serial];
        [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableDictionary<NSString *, id> *images = [NSMutableDictionary dictionary];
        for (NSDictionary *request in job) {
            NSString *key = request[@"key"];
            NSString *file = [self thumbnailFileFor:key serial:serial];
            id result = results[key];
            if (result == NSNull.null) {
                [NSData.data writeToFile:[file stringByAppendingPathExtension:@"none"] atomically:NO];
                images[key] = NSNull.null;
                continue;
            }
            CGImageRef cg = (__bridge CGImageRef)result;
            CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:file],
                                                                         (__bridge CFStringRef)UTTypeJPEG.identifier, 1, NULL);
            if (dest) {
                CGImageDestinationAddImage(dest, cg, (__bridge CFDictionaryRef)@{
                    (__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @0.82});
                CGImageDestinationFinalize(dest);
                CFRelease(dest);
            }
            images[key] = [[NSImage alloc] initWithCGImage:cg size:NSZeroSize];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSDictionary *request in job) {
                NSString *key = request[@"key"];
                id image = images[key];
                [self.thumbPending removeObject:key];
                if ([image isKindOfClass:NSImage.class]) {
                    NSImage *img = image;
                    [self.thumbCache setObject:img forKey:key cost:(NSUInteger)(img.size.width * img.size.height * 4)];
                    [self thumbnailReady:request[@"item"]];
                } else {
                    [self.thumbCache setObject:NSNull.null forKey:key];
                }
            }
        });
    }
}

- (CGImageRef)newThumbnailFor:(RemoteItem *)item serial:(NSString *)serial large:(BOOL)large CF_RETURNS_RETAINED {
    NSString *q = [self shellQuote:item.path];
    CGFloat maxPixels = large ? 900 : 360;

    if (ADBIsImageName(item.name)) {
        NSData *head = nil;
        if (!large && ADBIsJPEGName(item.name)) {
            head = [self adbData:@[@"-s", serial, @"exec-out", [NSString stringWithFormat:@"head -c %llu %@", kJPEGHeadBytes, q]]];
            CGImageRef exif = head ? ADBCreateExifThumbnail(head) : NULL;
            if (exif) return exif;
        }
        if (item.size > kMaxThumbnailImageBytes) return NULL;
        NSData *data = (head && head.length >= item.size)
            ? head : [self adbData:@[@"-s", serial, @"exec-out", [NSString stringWithFormat:@"cat %@", q]]];
        if (!data) return NULL;
        CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (!src) return NULL;
        NSDictionary *options = @{
            (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
            (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maxPixels),
        };
        CGImageRef thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)options);
        CFRelease(src);
        return thumb;
    }

    if (ADBIsPDFName(item.name)) {
        if (item.size > kMaxThumbnailPDFBytes) return NULL;
        NSData *data = [self adbData:@[@"-s", serial, @"exec-out", [NSString stringWithFormat:@"cat %@", q]]];
        return data ? ADBCreatePDFThumbnail(data, maxPixels) : NULL;
    }

    CGImageRef frame = [self newVideoFrameFor:item serial:serial maxPixels:maxPixels exact:YES];
    if (!frame) frame = [self newVideoFrameFor:item serial:serial maxPixels:maxPixels exact:NO];
    return frame;
}

// A video's index box (moov), wherever it is in the file, plus the file's first 64 KB.
- (NSData *)fetchMoovFor:(RemoteItem *)item serial:(NSString *)serial head:(NSData **)headOut offset:(uint64_t *)offsetOut {
    unsigned long long size = item.size;
    NSData *head = [self adbData:@[@"-s", serial, @"exec-out",
                                   [NSString stringWithFormat:@"head -c 65536 %@", [self shellQuote:item.path]]]];
    if (head.length < 16) return nil;
    if (headOut) *headOut = head;

    // Walk the top-level boxes to the index.
    uint64_t offset = 0;
    for (int i = 0; i < 32 && offset + 8 <= size; i++) {
        NSData *header = offset + 16 <= head.length
            ? [head subdataWithRange:NSMakeRange((NSUInteger)offset, 16)]
            : [self readRemote:item.path offset:offset length:MIN(16, size - offset) serial:serial];
        if (header.length < 8) return nil;
        const uint8_t *h = header.bytes;
        uint64_t boxSize = ADBReadBE(h, 4);
        if (boxSize == 1 && header.length >= 16) boxSize = ADBReadBE(h + 8, 8);
        else if (boxSize == 0) boxSize = size - offset;
        if (boxSize < 8 || offset + boxSize > size) return nil;
        if (memcmp(h + 4, "moov", 4) == 0) {
            if (boxSize > 16 * 1024 * 1024) return nil;
            if (offsetOut) *offsetOut = offset;
            return offset + boxSize <= head.length
                ? [head subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)boxSize)]
                : [self readRemote:item.path offset:offset length:boxSize serial:serial];
        }
        offset += boxSize;
    }
    return nil;
}

// The first frame of a video from a sparse local copy. With `exact`, only the index
// (moov) and the first frame are read — usually a few hundred KB; otherwise the
// first and last 3 MB.
- (CGImageRef)newVideoFrameFor:(RemoteItem *)item serial:(NSString *)serial maxPixels:(CGFloat)maxPixels exact:(BOOL)exact CF_RETURNS_RETAINED {
    NSString *q = [self shellQuote:item.path];
    unsigned long long size = item.size;
    NSMutableArray<NSArray *> *pieces = [NSMutableArray array];  // @[offset, data]

    if (!exact || size <= 2 * kVideoProbeBytes) {
        if (size <= 2 * kVideoProbeBytes) {
            NSData *all = [self adbData:@[@"-s", serial, @"exec-out", [NSString stringWithFormat:@"cat %@", q]]];
            if (!all) return NULL;
            [pieces addObject:@[@0, all]];
        } else {
            NSString *probe = [NSString stringWithFormat:@"%llu", kVideoProbeBytes];
            NSData *head = [self adbData:@[@"-s", serial, @"exec-out", [NSString stringWithFormat:@"head -c %@ %@", probe, q]]];
            NSData *tail = [self adbData:@[@"-s", serial, @"exec-out", [NSString stringWithFormat:@"tail -c %@ %@", probe, q]]];
            if (!head || !tail || tail.length > size) return NULL;
            [pieces addObject:@[@0, head]];
            [pieces addObject:@[@(size - tail.length), tail]];
        }
    } else {
        NSData *head = nil;
        uint64_t moovOffset = 0;
        NSData *moov = [self fetchMoovFor:item serial:serial head:&head offset:&moovOffset];
        if (!moov) return NULL;
        [pieces addObject:@[@0, head]];
        [pieces addObject:@[@(moovOffset), moov]];

        size_t payload, end;
        if (!ADBFindBox(moov.bytes, 0, moov.length, "moov", &payload, &end)) return NULL;
        uint64_t sampleOffset = 0, sampleLength = 0;
        if (!ADBFirstVideoSample([moov subdataWithRange:NSMakeRange(payload, end - payload)], &sampleOffset, &sampleLength)) return NULL;
        if (sampleLength > 16 * 1024 * 1024 || sampleOffset + sampleLength > size) return NULL;
        NSData *sample = [self readRemote:item.path offset:sampleOffset length:sampleLength serial:serial];
        if (!sample) return NULL;
        [pieces addObject:@[@(sampleOffset), sample]];
    }

    NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSUUID.UUID.UUIDString stringByAppendingPathExtension:item.name.pathExtension.lowercaseString]];
    int fd = open(temp.fileSystemRepresentation, O_CREAT | O_WRONLY | O_TRUNC, 0600);
    if (fd < 0) return NULL;
    BOOL ok = ftruncate(fd, (off_t)size) == 0;
    for (NSArray *piece in pieces) {
        NSData *data = piece[1];
        ok = ok && pwrite(fd, data.bytes, data.length, (off_t)[piece[0] unsignedLongLongValue]) == (ssize_t)data.length;
    }
    close(fd);

    CGImageRef frame = NULL;
    if (ok) {
        AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:
                                            [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:temp] options:nil]];
        generator.appliesPreferredTrackTransform = YES;
        generator.maximumSize = CGSizeMake(maxPixels, maxPixels);
        frame = [generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:NULL];
    }
    [[NSFileManager defaultManager] removeItemAtPath:temp error:nil];
    return frame;
}

- (void)thumbnailReady:(RemoteItem *)item {
    if (self.viewMode == ADBViewModeIcons) {
        for (NSCollectionViewItem *visible in self.collection.visibleItems) {
            IconItemView *view = (IconItemView *)visible.view;
            if ([view.item.path isEqualToString:item.path]) [view updateImage];
        }
    } else {
        NSArray<NSTableView *> *tables = self.viewMode == ADBViewModeList
            ? @[self.table] : [self.columnTables subarrayWithRange:NSMakeRange(0, MIN(self.columnPaths.count, self.columnTables.count))];
        for (NSTableView *table in tables) {
            NSArray<RemoteItem *> *items = [self itemsForTable:table];
            for (NSUInteger i = 0; i < items.count; i++) {
                if (![items[i].path isEqualToString:item.path]) continue;
                NSInteger column = [table columnWithIdentifier:table == self.table ? @"name" : @"colname"];
                NSTableCellView *cell = [table viewAtColumn:column row:(NSInteger)i makeIfNecessary:NO];
                if (cell) cell.imageView.image = [self thumbnailForItem:items[i] request:NO] ?: ADBIconForItem(items[i]);
            }
        }
    }
    if ([self.previewItem.path isEqualToString:item.path]) [self updatePreviewPane];
}

#pragma mark File operations

- (void)runInBackground:(NSString *)command
                  title:(NSString *)failureTitle
                   then:(void (^)(BOOL ok, NSString *output))completion {
    NSString *serial = [self.serial copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *out = nil;
        NSString *err = nil;
        BOOL ok = [self runADBShell:command serial:serial output:&out error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok && failureTitle) [self showError:failureTitle message:err];
            if (completion) completion(ok, out);
        });
    });
}

- (void)showError:(NSString *)title message:(NSString *)message {
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = title;
    alert.informativeText = message.length ? message : @"Unknown error";
    if (self.window.attachedSheet) {
        [alert runModal];
    } else {
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
    }
}

- (void)newFolder:(id)sender {
    (void)sender;
    if (![self canBrowse]) return;

    NSSet *names = [NSSet setWithArray:[self.allItems valueForKey:@"name"]];
    NSString *name = ADBUniqueName(@"untitled folder", ^BOOL(NSString *candidate) {
        return [names containsObject:candidate];
    });
    NSString *path = ADBJoinPath(self.currentPath, name);
    NSString *folder = [self.currentPath copy];

    [self runInBackground:[NSString stringWithFormat:@"mkdir %@", [self shellQuote:path]]
                    title:@"Can't create the folder"
                     then:^(BOOL ok, NSString *output) {
        (void)output;
        if (!ok || ![folder isEqualToString:self.currentPath]) return;
        // Like Finder: the new folder is selected with its name ready to type over.
        self.pendingRenamePath = path;
        [self reloadSelecting:@[name]];
    }];
}

- (void)renameSelection:(id)sender {
    (void)sender;
    NSArray<RemoteItem *> *selected = [self selectedItems];
    if (selected.count != 1) return;
    [self beginRenameOfItem:selected.firstObject];
}

- (void)beginRenameOfItem:(RemoteItem *)item {
    if (self.viewMode == ADBViewModeIcons) {
        [self renameWithSheet:item];
        return;
    }
    NSTableView *table = [self activeTable];
    NSArray<RemoteItem *> *items = [self itemsForTable:table];
    NSInteger row = -1;
    for (NSUInteger i = 0; i < items.count; i++) if ([items[i].path isEqualToString:item.path]) row = (NSInteger)i;
    if (row < 0) return;

    self.renamingPath = item.path;
    NSInteger column = [table columnWithIdentifier:table == self.table ? @"name" : @"colname"];
    NSTableCellView *cell = [table viewAtColumn:column row:row makeIfNecessary:YES];
    if (!cell) return;
    [table scrollRowToVisible:row];
    cell.textField.editable = YES;
    [self.window makeFirstResponder:cell.textField];
    [cell.textField.currentEditor setSelectedRange:[self editableRangeOf:item]];
}

// The name without the extension, which is what Finder selects for renaming.
- (NSRange)editableRangeOf:(RemoteItem *)item {
    NSString *name = item.name;
    NSUInteger length = name.length;
    if (!item.directory && name.pathExtension.length && ![name hasPrefix:@"."]) {
        length = name.stringByDeletingPathExtension.length;
    }
    return NSMakeRange(0, length);
}

- (void)renameWithSheet:(RemoteItem *)item {
    NSAlert *alert = [NSAlert new];
    alert.messageText = item.directory ? @"Rename Folder" : @"Rename";
    [alert addButtonWithTitle:@"Rename"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *field = [NSTextField textFieldWithString:item.name];
    field.frame = NSMakeRect(0, 0, 300, 24);
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) [self commitRenameOf:item to:field.stringValue revert:nil];
    }];
    [field.currentEditor setSelectedRange:[self editableRangeOf:item]];
}

- (void)cancelRename {
    if (!self.renamingPath) return;
    self.renamingPath = nil;
    [self reloadViews];
}

- (NSTableView *)tableContainingView:(NSView *)view {
    for (NSView *v = view; v; v = v.superview) {
        if ([v isKindOfClass:NSTableView.class]) return (NSTableView *)v;
    }
    return nil;
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    (void)textView;
    if (command == @selector(cancelOperation:) && self.renamingPath) {
        NSTableView *table = [self tableContainingView:control];
        NSArray<RemoteItem *> *items = [self itemsForTable:table];
        NSInteger row = [table rowForView:control];
        if (row >= 0 && (NSUInteger)row < items.count) {
            ((NSTextField *)control).stringValue = items[(NSUInteger)row].name;
        }
        self.renamingPath = nil;
        ((NSTextField *)control).editable = NO;
        [self.window makeFirstResponder:table];
        return YES;
    }
    return NO;
}

- (void)renameEdited:(NSTextField *)sender {
    NSTableView *table = [self tableContainingView:sender];
    NSArray<RemoteItem *> *items = [self itemsForTable:table];
    NSInteger row = [table rowForView:sender];
    NSString *renaming = self.renamingPath;
    self.renamingPath = nil;
    sender.editable = NO;
    if (row < 0 || (NSUInteger)row >= items.count || !renaming) return;

    RemoteItem *item = items[(NSUInteger)row];
    if (![item.path isEqualToString:renaming]) return;
    [self.window makeFirstResponder:table];
    [self commitRenameOf:item to:sender.stringValue revert:^{
        sender.stringValue = item.name;
    }];
}

- (void)commitRenameOf:(RemoteItem *)item to:(NSString *)newName revert:(void (^)(void))revert {
    NSString *name = [newName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length || [name isEqualToString:item.name]) {
        if (revert) revert();
        return;
    }
    if ([name containsString:@"/"] || [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
        if (revert) revert();
        [self showError:@"That name can't be used" message:@"Names on Android can't contain “/”."];
        return;
    }

    NSString *target = ADBJoinPath(ADBParentPath(item.path), name);
    NSString *command = [NSString stringWithFormat:@"if [ -e %1$@ ]; then echo 'exists'; exit 1; fi; mv -- %2$@ %1$@",
                         [self shellQuote:target], [self shellQuote:item.path]];

    [self runInBackground:command title:nil then:^(BOOL ok, NSString *output) {
        if (!ok) {
            if (revert) revert();
            if ([output hasPrefix:@"exists"]) {
                [self showError:[NSString stringWithFormat:@"The name “%@” is already taken", name]
                        message:@"Please choose a different name."];
            } else {
                [self showError:@"Can't rename" message:output];
            }
            return;
        }
        [self rescanMedia:@[item.path, target] serial:self.serial];
        [self invalidateListings];
        if (self.currentPath && ADBPathIsInside(self.currentPath, item.path)) {
            // The folder on screen (or one above it, in column view) was renamed.
            NSString *moved = [target stringByAppendingString:[self.currentPath substringFromIndex:item.path.length]];
            [self.listingCache removeObjectForKey:self.currentPath];
            [self showFolder:moved selecting:nil];
        } else {
            [self reloadSelecting:@[name]];
        }
    }];
}

- (void)deleteSelection:(id)sender {
    (void)sender;
    NSArray<RemoteItem *> *selected = [self selectedItems];
    if (!selected.count) return;

    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = selected.count == 1
        ? [NSString stringWithFormat:@"Delete “%@”?", selected.firstObject.name]
        : [NSString stringWithFormat:@"Delete %lu items?", (unsigned long)selected.count];
    BOOL folders = NO;
    for (RemoteItem *item in selected) folders |= item.directory;
    alert.informativeText = folders
        ? @"Folders are deleted with everything in them. Android has no Trash for this — it can't be undone."
        : @"Android has no Trash for this — it can't be undone.";
    NSButton *delete = [alert addButtonWithTitle:@"Delete"];
    delete.hasDestructiveAction = YES;
    [alert addButtonWithTitle:@"Cancel"];

    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSMutableString *command = [NSMutableString stringWithString:@"rm -rf --"];
        NSString *leaveTo = nil;
        for (RemoteItem *item in selected) {
            // Never a storage root.
            if ([item.path isEqualToString:@"/"] || [item.path isEqualToString:kStorageRoot]) continue;
            [command appendFormat:@" %@", [self shellQuote:item.path]];
            if (ADBPathIsInside(self.currentPath, item.path)) leaveTo = ADBParentPath(item.path);
        }
        [self appendLog:[NSString stringWithFormat:@"DELETE %@", [[selected valueForKey:@"path"] componentsJoinedByString:@", "]]];
        NSString *serial = [self.serial copy];
        [self runInBackground:command title:@"Some items couldn't be deleted" then:^(BOOL ok, NSString *output) {
            (void)ok; (void)output;
            [self rescanMedia:[selected valueForKey:@"path"] serial:serial];
            [self invalidateFreeSpace];
            [self invalidateListings];
            if (leaveTo) {
                // The folder on screen is gone; show the one that held it.
                [self showFolder:leaveTo selecting:nil];
            } else {
                [self reloadSelecting:@[]];
            }
        }];
    }];
}

// Names (of `names`) that already exist in `folder` on the device.
- (void)existingNames:(NSArray<NSString *> *)names inFolder:(NSString *)folder
           completion:(void (^)(NSArray<NSString *> *existing))completion {
    NSMutableString *command = [NSMutableString stringWithFormat:@"cd %@ 2>/dev/null || exit 0; for f in", [self shellQuote:folder]];
    for (NSString *name in names) [command appendFormat:@" %@", [self shellQuote:name]];
    [command appendString:@"; do [ -e \"$f\" ] && echo \"$f\"; done; exit 0"];
    NSString *serial = [self.serial copy];
    NSSet *wanted = [NSSet setWithArray:names];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *out = nil;
        if (names.count <= 200) [self runQuietShell:command serial:serial output:&out];
        NSMutableArray<NSString *> *existing = [NSMutableArray array];
        for (NSString *line in [out ?: @"" componentsSeparatedByString:@"\n"]) {
            if ([wanted containsObject:line]) [existing addObject:line];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(existing); });
    });
}

// Replace / Skip / Cancel. `decision` gets YES for Replace, NO for Skip; Cancel calls nothing.
- (void)confirmReplacing:(NSArray<NSString *> *)existing inFolder:(NSString *)folder then:(void (^)(BOOL replace))decision {
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    NSString *where = folder.lastPathComponent.length ? folder.lastPathComponent : folder;
    alert.messageText = existing.count == 1
        ? [NSString stringWithFormat:@"“%@” already exists in %@", existing.firstObject, where]
        : [NSString stringWithFormat:@"%lu items already exist in %@", (unsigned long)existing.count, where];
    alert.informativeText = @"Replacing overwrites files with the same name. Folders are merged.";
    [alert addButtonWithTitle:@"Replace"];
    [alert addButtonWithTitle:@"Skip"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) decision(YES);
        if (response == NSAlertSecondButtonReturn) decision(NO);
    }];
}

// Copies items to another folder on the device. Nothing is ever moved.
- (void)copyRemotePaths:(NSArray<NSString *> *)paths toFolder:(NSString *)folder {
    NSMutableArray<NSString *> *sources = [NSMutableArray array];
    for (NSString *p in paths) {
        if (ADBPathIsInside(folder, p) || [ADBParentPath(p) isEqualToString:folder]) continue;
        [sources addObject:p];
    }
    if (!sources.count) return;

    [self existingNames:[sources valueForKey:@"lastPathComponent"] inFolder:folder completion:^(NSArray<NSString *> *existing) {
        void (^copy)(NSArray<NSString *> *) = ^(NSArray<NSString *> *list) {
            if (list.count) [self runCopyOf:list toFolder:folder];
        };
        if (!existing.count) {
            copy(sources);
            return;
        }
        [self confirmReplacing:existing inFolder:folder then:^(BOOL replace) {
            if (replace) {
                copy(sources);
                return;
            }
            NSMutableArray *rest = [NSMutableArray array];
            for (NSString *p in sources) if (![existing containsObject:p.lastPathComponent]) [rest addObject:p];
            copy(rest);
        }];
    }];
}

- (void)runCopyOf:(NSArray<NSString *> *)sources toFolder:(NSString *)folder {
    NSMutableString *command = [NSMutableString stringWithString:@"cp -R --"];
    for (NSString *p in sources) [command appendFormat:@" %@", [self shellQuote:p]];
    [command appendFormat:@" %@/", [self shellQuote:folder]];

    [self appendLog:[NSString stringWithFormat:@"COPY %@ → %@", [sources componentsJoinedByString:@", "], folder]];
    self.transferIcon.image = ADBSymbol(@"doc.on.doc", 14, NSFontWeightRegular);
    [self setStatus:[NSString stringWithFormat:@"Copying %lu item%@ to %@…", (unsigned long)sources.count,
                     sources.count == 1 ? @"" : @"s", folder.lastPathComponent]
             detail:@""];

    NSString *serial = [self.serial copy];
    [self runInBackground:command title:@"Can't copy" then:^(BOOL ok, NSString *output) {
        (void)output;
        NSMutableArray *copied = [NSMutableArray array];
        for (NSString *p in sources) [copied addObject:ADBJoinPath(folder, p.lastPathComponent)];
        [self rescanMedia:copied serial:serial];
        [self setStatus:ok ? [NSString stringWithFormat:@"Copied to %@", folder.lastPathComponent] : @"Copy failed" detail:@""];
        [self scheduleHideTransferBar];
        [self invalidateFreeSpace];
        [self invalidateListings];
        [self reloadSelecting:nil];
    }];
}

- (void)copyPath:(id)sender {
    (void)sender;
    NSArray *paths = [[self selectedItems] valueForKey:@"path"];
    if (!paths.count) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:[paths componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
}

// ⌘C: the items can be pasted into another folder on the phone; their paths also go
// to the clipboard as text.
- (void)copy:(id)sender {
    (void)sender;
    NSArray<RemoteItem *> *selected = [self selectedItems];
    if (!selected.count) return;
    NSMutableArray<NSPasteboardItem *> *items = [NSMutableArray array];
    for (RemoteItem *item in selected) {
        NSPasteboardItem *entry = [NSPasteboardItem new];
        [entry setString:item.path forType:kRemotePathType];
        [entry setString:self.serial forType:kRemoteSerialType];
        [entry setString:item.path forType:NSPasteboardTypeString];
        [items addObject:entry];
    }
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard writeObjects:items];
}

// ⌘V: items copied here (⌘C) are copied into this folder; files copied in Finder are uploaded.
- (void)paste:(id)sender {
    (void)sender;
    if (![self canBrowse]) return;
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    BOOL otherDevice = NO;
    for (NSPasteboardItem *entry in pb.pasteboardItems) {
        NSString *path = [entry stringForType:kRemotePathType];
        if (!path.length) continue;
        otherDevice |= ![[entry stringForType:kRemoteSerialType] isEqualToString:self.serial];
        [paths addObject:path];
    }
    if (paths.count) {
        if (otherDevice) {
            [self showError:@"Can't paste here" message:@"The items were copied on another phone."];
            return;
        }
        NSMutableArray *here = [NSMutableArray array], *elsewhere = [NSMutableArray array];
        for (NSString *p in paths) [[ADBParentPath(p) isEqualToString:self.currentPath] ? here : elsewhere addObject:p];
        // Pasting into the same folder makes copies, like Finder ("name copy").
        if (here.count) [self duplicatePaths:here];
        if (elsewhere.count) [self copyRemotePaths:elsewhere toFolder:self.currentPath];
        return;
    }
    NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (urls.count) [self uploadURLs:urls toFolder:self.currentPath];
}

- (void)duplicateSelection:(id)sender {
    (void)sender;
    NSArray<RemoteItem *> *selected = [self selectedItems];
    if (selected.count) [self duplicatePaths:[selected valueForKey:@"path"]];
}

// "photo.jpg" → "photo copy.jpg", then "photo copy 2.jpg"…, next to the original.
- (void)duplicatePaths:(NSArray<NSString *> *)paths {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *path in paths) {
        NSString *name = path.lastPathComponent;
        BOOL folder = NO;
        for (RemoteItem *item in self.allItems) if ([item.path isEqualToString:path]) folder = item.directory;
        NSString *ext = (!folder && name.pathExtension.length && ![name hasPrefix:@"."]) ? [@"." stringByAppendingString:name.pathExtension] : @"";
        NSString *base = ext.length ? name.stringByDeletingPathExtension : name;
        [parts addObject:[NSString stringWithFormat:
            @"d=%@; b=%@; e=%@; n=\"$b copy\"; i=2; while [ -e \"$d/$n$e\" ]; do n=\"$b copy $i\"; i=$((i+1)); done; "
            @"cp -R -- %@ \"$d/$n$e\" && echo \"$n$e\"",
            [self shellQuote:ADBParentPath(path)], [self shellQuote:base], [self shellQuote:ext], [self shellQuote:path]]];
    }
    [self appendLog:[NSString stringWithFormat:@"DUPLICATE %@", [paths componentsJoinedByString:@", "]]];
    NSString *serial = [self.serial copy];
    [self runInBackground:[parts componentsJoinedByString:@"; "] title:@"Can't duplicate" then:^(BOOL ok, NSString *output) {
        (void)ok;
        NSArray<NSString *> *names = [output componentsSeparatedByString:@"\n"];
        NSMutableArray *made = [NSMutableArray array];
        for (NSUInteger i = 0; i < names.count && i < paths.count; i++) [made addObject:ADBJoinPath(ADBParentPath(paths[i]), names[i])];
        [self rescanMedia:made serial:serial];
        [self invalidateFreeSpace];
        [self invalidateListings];
        [self reloadSelecting:names];
    }];
}

- (void)sortByMenu:(NSMenuItem *)sender {
    NSString *key = sender.representedObject;
    self.table.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:key ascending:![key isEqualToString:@"modified"]]];
    [self applyFilterKeepingSelection:YES];
}

- (void)uploadFiles:(id)sender {
    (void)sender;
    if (![self canBrowse]) return;

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = YES;
    panel.prompt = @"Upload";
    panel.message = [NSString stringWithFormat:@"Choose files or folders to copy to %@", self.currentPath];
    NSString *dest = [self.currentPath copy];

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) [self uploadURLs:panel.URLs toFolder:dest];
    }];
}

- (void)downloadSelection:(id)sender {
    (void)sender;
    NSArray<RemoteItem *> *selected = [self selectedItems];
    if (!selected.count) return;

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"Download";
    panel.message = selected.count == 1
        ? [NSString stringWithFormat:@"Choose where to save “%@”", selected.firstObject.name]
        : [NSString stringWithFormat:@"Choose where to save %lu items", (unsigned long)selected.count];
    panel.directoryURL = [NSFileManager.defaultManager URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject;

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) [self downloadItems:selected toFolder:panel.URL.path reveal:YES];
    }];
}

- (void)downloadToDownloads:(id)sender {
    (void)sender;
    NSArray<RemoteItem *> *selected = [self selectedItems];
    NSURL *downloads = [NSFileManager.defaultManager URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject;
    if (selected.count && downloads) [self downloadItems:selected toFolder:downloads.path reveal:YES];
}

- (void)downloadItems:(NSArray<RemoteItem *> *)items toFolder:(NSString *)folder reveal:(BOOL)reveal {
    NSString *serial = [self.serial copy];
    NSMutableArray<NSURL *> *saved = [NSMutableArray array];
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    NSOperation *last = nil;

    for (RemoteItem *item in items) {
        last = [NSBlockOperation blockOperationWithBlock:^{
            if (self.pullCancelRequested) return;
            NSFileManager *fm = NSFileManager.defaultManager;
            NSString *name = ADBUniqueName([item.name stringByReplacingOccurrencesOfString:@":" withString:@"-"],
                                           ^BOOL(NSString *candidate) {
                return [fm fileExistsAtPath:[folder stringByAppendingPathComponent:candidate]];
            });
            NSString *local = [folder stringByAppendingPathComponent:name];
            NSString *error = [self pullItem:item toPath:local serial:serial];
            @synchronized (saved) {
                if (error) [errors addObject:[NSString stringWithFormat:@"%@: %@", item.name, error]];
                else [saved addObject:[NSURL fileURLWithPath:local]];
            }
        }];
        [self.pullQueue addOperation:last];
    }

    NSOperation *done = [NSBlockOperation blockOperationWithBlock:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (errors.count && !self.pullCancelRequested) {
                [self showError:@"Some items couldn't be downloaded" message:[errors componentsJoinedByString:@"\n\n"]];
            }
            if (reveal && saved.count) [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:saved];
        });
    }];
    if (last) [done addDependency:last];
    [self.pullQueue addOperation:done];
}

#pragma mark Open and Quick Look

// Files opened or previewed from the phone; cleared on every launch.
- (NSString *)cacheDirectory {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [[caches stringByAppendingPathComponent:@"ADBFinder"] stringByAppendingPathComponent:@"Files"];
}

// Pulls files into the cache (reusing copies that are still current) and hands back their local URLs.
- (void)fetchToCache:(NSArray<RemoteItem *> *)items completion:(void (^)(NSArray<NSURL *> *urls))completion {
    NSString *serial = [self.serial copy];
    NSString *root = [[self cacheDirectory] stringByAppendingPathComponent:serial];

    [self.pullQueue addOperationWithBlock:^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSMutableArray<NSURL *> *urls = [NSMutableArray array];
        for (RemoteItem *item in items) {
            if (self.pullCancelRequested) break;
            NSString *local = [root stringByAppendingString:item.path];
            NSDictionary *attrs = [fm attributesOfItemAtPath:local error:nil];
            BOOL fresh = attrs && attrs.fileSize == item.size && item.modified &&
                         fabs([attrs.fileModificationDate timeIntervalSinceDate:item.modified]) < 1;
            if (!fresh) {
                [fm removeItemAtPath:local error:nil];
                [fm createDirectoryAtPath:local.stringByDeletingLastPathComponent
              withIntermediateDirectories:YES attributes:nil error:nil];
                if ([self pullItem:item toPath:local serial:serial]) continue;
            }
            [urls addObject:[NSURL fileURLWithPath:local]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (urls.count) completion(urls);
        });
    }];
}

- (BOOL)previewAvailable {
    return [self selectedItems].count > 0;
}

- (void)quickLook:(id)sender {
    (void)sender;
    if ([self closePreviews]) return;
    NSArray<RemoteItem *> *selected = [self selectedItems];
    if (selected.count == 1 && selected.firstObject.directory) {
        [self showFolderPanelFor:selected.firstObject];
        return;
    }
    [self preparePreviewAndShow:YES];
}

- (BOOL)closePreviews {
    BOOL closed = NO;
    if (self.folderPanel.visible) {
        [self hideFolderPanelAnimated:YES];
        closed = YES;
    }
    if ([QLPreviewPanel sharedPreviewPanelExists] && [QLPreviewPanel sharedPreviewPanel].visible) {
        [[QLPreviewPanel sharedPreviewPanel] orderOut:nil];
        closed = YES;
    }
    return closed;
}

// Quick Look for the selected files (pulled to a local cache first). Folders get
// their own panel, see showFolderPanelFor:.
- (void)preparePreviewAndShow:(BOOL)show {
    NSMutableArray<RemoteItem *> *files = [NSMutableArray array];
    for (RemoteItem *item in [self selectedItems]) if (!item.directory) [files addObject:item];
    if (!files.count) return;

    // Reloading the panel resets its zoom; only do it when the selection really changed.
    NSArray<NSString *> *paths = [files valueForKey:@"path"];
    if (!show && [paths isEqualToArray:self.previewPaths]) return;
    self.previewPaths = paths;

    NSUInteger generation = ++self.previewGeneration;
    NSString *root = [[self cacheDirectory] stringByAppendingPathComponent:self.serial];
    [self fetchToCache:files completion:^(NSArray<NSURL *> *urls) {
        (void)urls;
        if (generation != self.previewGeneration) return;
        NSMutableArray<PreviewEntry *> *entries = [NSMutableArray array];
        for (RemoteItem *item in files) {
            PreviewEntry *entry = [PreviewEntry new];
            entry.title = item.name;
            entry.path = item.path;
            entry.url = [NSURL fileURLWithPath:[root stringByAppendingString:item.path]];
            if ([NSFileManager.defaultManager fileExistsAtPath:entry.url.path]) [entries addObject:entry];
        }
        if (!entries.count) return;
        QLPreviewPanel *panel = [QLPreviewPanel sharedPreviewPanel];
        BOOL changed = ![entries isEqualToArray:self.previewURLs];
        self.previewURLs = entries;
        if (show) [panel makeKeyAndOrderFront:nil];
        if (changed) [panel reloadData];
    }];
}

#pragma mark Folder preview

// Space on a folder: a panel drawn like Quick Look's own folder preview, with the
// folder's real size and item count from the phone.
- (void)buildFolderPanel {
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 575, 328)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                          NSWindowStyleMaskFullSizeContentView | NSWindowStyleMaskNonactivatingPanel
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    panel.titleVisibility = NSWindowTitleHidden;
    panel.titlebarAppearsTransparent = YES;
    panel.movableByWindowBackground = YES;
    panel.floatingPanel = YES;
    panel.hidesOnDeactivate = YES;
    panel.becomesKeyOnlyIfNeeded = YES;
    panel.releasedWhenClosed = NO;
    for (NSNumber *kind in @[@(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton)]) {
        [panel standardWindowButton:(NSWindowButton)kind.integerValue].hidden = YES;
    }

    // The window itself is clear; the panel is the rounded material view, so it can be
    // scaled for the zoom without the window's own background showing around it.
    panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor;
    NSVisualEffectView *background = [NSVisualEffectView new];
    background.material = NSVisualEffectMaterialFullScreenUI;
    background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    background.state = NSVisualEffectStateActive;
    background.wantsLayer = YES;
    CGFloat radius = 12;
    background.maskImage = [NSImage imageWithSize:NSMakeSize(2 * radius + 1, 2 * radius + 1) flipped:NO
                                   drawingHandler:^BOOL(NSRect rect) {
        [NSColor.blackColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
        return YES;
    }];
    background.maskImage.capInsets = NSEdgeInsetsMake(radius, radius, radius, radius);
    background.maskImage.resizingMode = NSImageResizingModeStretch;
    panel.contentView = background;

    NSButton *close = [NSButton buttonWithImage:ADBSymbol(@"xmark.circle.fill", 16, NSFontWeightRegular)
                                         target:self action:@selector(closeFolderPanel:)];
    close.bordered = NO;
    close.contentTintColor = NSColor.secondaryLabelColor;
    close.toolTip = @"Close";
    NSButton *info = [NSButton buttonWithImage:ADBSymbol(@"info.circle", 16, NSFontWeightRegular)
                                        target:self action:@selector(folderPanelInfo:)];
    info.bordered = NO;
    info.contentTintColor = NSColor.secondaryLabelColor;
    info.toolTip = @"Get Info";

    NSImageView *icon = [NSImageView imageViewWithImage:[[NSWorkspace sharedWorkspace] iconForContentType:UTTypeFolder]];
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;

    self.folderPanelName = [NSTextField labelWithString:@""];
    self.folderPanelName.font = [NSFont systemFontOfSize:21 weight:NSFontWeightBold];
    self.folderPanelName.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSTextField *kind = [NSTextField labelWithString:@"Folder"];
    self.folderPanelSize = [NSTextField labelWithString:@""];
    self.folderPanelDate = [NSTextField labelWithString:@""];
    for (NSTextField *line in @[kind, self.folderPanelSize, self.folderPanelDate]) {
        line.font = [NSFont systemFontOfSize:14];
        line.textColor = NSColor.secondaryLabelColor;
        line.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    NSStackView *text = [NSStackView stackViewWithViews:@[self.folderPanelName, kind, self.folderPanelSize, self.folderPanelDate]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 5;
    [text setCustomSpacing:12 afterView:self.folderPanelName];

    for (NSView *v in @[close, info, icon, text]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [background addSubview:v];
    }
    [NSLayoutConstraint activateConstraints:@[
        [close.leadingAnchor constraintEqualToAnchor:background.leadingAnchor constant:12],
        [close.topAnchor constraintEqualToAnchor:background.topAnchor constant:11],
        [info.trailingAnchor constraintEqualToAnchor:background.trailingAnchor constant:-14],
        [info.centerYAnchor constraintEqualToAnchor:close.centerYAnchor],
        [icon.leadingAnchor constraintEqualToAnchor:background.leadingAnchor constant:22],
        [icon.centerYAnchor constraintEqualToAnchor:background.centerYAnchor constant:12],
        [icon.widthAnchor constraintEqualToConstant:252],
        [icon.heightAnchor constraintEqualToConstant:252],
        [text.leadingAnchor constraintEqualToAnchor:background.leadingAnchor constant:298],
        [text.trailingAnchor constraintLessThanOrEqualToAnchor:background.trailingAnchor constant:-24],
        [text.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor constant:-13],
    ]];
    self.folderPanel = panel;
}

- (void)showFolderPanelFor:(RemoteItem *)item {
    [self showFolderPanelFor:item animated:YES];
}

- (void)showFolderPanelFor:(RemoteItem *)item animated:(BOOL)animated {
    if (!self.folderPanel) [self buildFolderPanel];
    self.folderPanelItem = item;
    self.folderPanelName.stringValue = item.name;
    self.folderPanelName.toolTip = item.path;

    NSDateFormatter *f = [NSDateFormatter new];
    f.dateStyle = NSDateFormatterMediumStyle;
    f.timeStyle = NSDateFormatterMediumStyle;
    self.folderPanelDate.stringValue = item.modified ? [@"Last modified " stringByAppendingString:[f stringFromDate:item.modified]] : @"";

    [self updateFolderPanelSize:item stats:self.folderStats[[self statsKeyFor:item]]];
    if (!self.folderStats[[self statsKeyFor:item]]) {
        [self loadStatsFor:item completion:^(NSDictionary *stats) {
            if ([self.folderPanelItem.path isEqualToString:item.path]) [self updateFolderPanelSize:item stats:stats];
        }];
    }
    if (!self.folderPanel.visible) {
        [self placeFolderPanel];
        if (animated) [self zoomFolderPanelOpen:YES];
        else [self.folderPanel orderFront:nil];
    }
}

// Where Quick Look shows photos and videos: centred on its last window, or in the
// middle of the screen ([NSWindow center] puts windows a third of the way down).
- (void)placeFolderPanel {
    NSRect panel = self.folderPanel.frame;
    NSPoint middle;
    if ([QLPreviewPanel sharedPreviewPanelExists] && !NSIsEmptyRect([QLPreviewPanel sharedPreviewPanel].frame)) {
        NSRect ql = [QLPreviewPanel sharedPreviewPanel].frame;
        middle = NSMakePoint(NSMidX(ql), NSMidY(ql));
    } else {
        NSRect screen = (self.window.screen ?: NSScreen.mainScreen).visibleFrame;
        middle = NSMakePoint(NSMidX(screen), NSMidY(screen));
    }
    [self.folderPanel setFrameOrigin:NSMakePoint(round(middle.x - panel.size.width / 2),
                                                 round(middle.y - panel.size.height / 2))];
}

- (void)updateFolderPanelSize:(RemoteItem *)item stats:(NSDictionary *)stats {
    NSInteger n = self.showHidden ? item.childCount : item.visibleChildCount;
    NSNumber *counted = stats[self.showHidden ? @"children" : @"visibleChildren"];
    if (counted && counted.integerValue >= 0) n = counted.integerValue;
    NSString *items = n >= 0 ? [NSString stringWithFormat:@"%@ item%@",
                                [NSNumberFormatter localizedStringFromNumber:@(n) numberStyle:NSNumberFormatterDecimalStyle],
                                n == 1 ? @"" : @"s"] : nil;
    NSString *size = stats.count ? ADBFormatBytes([stats[@"bytes"] unsignedLongLongValue]) : (stats ? nil : @"Calculating…");
    self.folderPanelSize.stringValue = size && items ? [NSString stringWithFormat:@"%@, %@", size, items] : (items ?: size ?: @"");
}

- (void)closeFolderPanel:(id)sender {
    (void)sender;
    [self hideFolderPanelAnimated:YES];
}

- (void)hideFolderPanelAnimated:(BOOL)animated {
    if (animated && self.folderPanel.visible) {
        [self zoomFolderPanelOpen:NO];
    } else {
        [self.folderPanel orderOut:nil];
    }
    self.folderPanelItem = nil;
}

#pragma mark Preview zoom

// Where an item's icon (or thumbnail) is on screen, so previews can grow out of it
// and shrink back into it like in Finder. NSZeroRect when it isn't visible.
- (NSRect)screenRectForItemPath:(NSString *)path {
    NSImageView *iconView = nil;
    if (self.viewMode == ADBViewModeIcons) {
        for (NSCollectionViewItem *visible in self.collection.visibleItems) {
            IconItemView *view = (IconItemView *)visible.view;
            if ([view.item.path isEqualToString:path]) iconView = view.iconView;
        }
    } else {
        NSArray<NSTableView *> *tables = self.viewMode == ADBViewModeList
            ? @[self.table] : [self.columnTables subarrayWithRange:NSMakeRange(0, MIN(self.columnPaths.count, self.columnTables.count))];
        for (NSTableView *table in tables) {
            NSArray<RemoteItem *> *items = [self itemsForTable:table];
            NSRange rows = [table rowsInRect:table.visibleRect];
            for (NSUInteger i = rows.location; i < NSMaxRange(rows) && i < items.count; i++) {
                if (![items[i].path isEqualToString:path]) continue;
                NSInteger column = [table columnWithIdentifier:table == self.table ? @"name" : @"colname"];
                NSTableCellView *cell = [table viewAtColumn:column row:(NSInteger)i makeIfNecessary:NO];
                iconView = cell.imageView;
            }
        }
    }
    if (!iconView.window || iconView.hiddenOrHasHiddenAncestor || NSIsEmptyRect(iconView.visibleRect)) return NSZeroRect;

    // The picture is drawn aspect-fit inside the view.
    NSRect box = iconView.bounds;
    NSSize image = iconView.image.size;
    if (image.width > 0 && image.height > 0) {
        CGFloat scale = MIN(box.size.width / image.width, box.size.height / image.height);
        NSSize fit = NSMakeSize(image.width * scale, image.height * scale);
        box = NSMakeRect(NSMidX(box) - fit.width / 2, NSMidY(box) - fit.height / 2, fit.width, fit.height);
    }
    return [iconView.window convertRectToScreen:[iconView convertRect:box toView:nil]];
}

- (NSRect)previewPanel:(QLPreviewPanel *)panel sourceFrameOnScreenForPreviewItem:(id<QLPreviewItem>)item {
    (void)panel;
    return [item isKindOfClass:PreviewEntry.class] ? [self screenRectForItemPath:((PreviewEntry *)item).path] : NSZeroRect;
}

- (id)previewPanel:(QLPreviewPanel *)panel transitionImageForPreviewItem:(id<QLPreviewItem>)item contentRect:(NSRect *)contentRect {
    (void)panel;
    (void)contentRect;
    if (![item isKindOfClass:PreviewEntry.class]) return nil;
    for (RemoteItem *candidate in self.items) {
        if ([candidate.path isEqualToString:((PreviewEntry *)item).path]) {
            return [self thumbnailForItem:candidate request:NO] ?: ADBIconForItem(candidate);
        }
    }
    return nil;
}

// The folder panel grows out of the folder's icon and shrinks back into it, like
// Quick Look: a picture of the panel is animated in a borderless window.
// The folder panel grows out of the folder's icon and shrinks back into it, like Quick
// Look: the panel's own content is scaled (so it looks the same in every frame) while
// the window fades in or out.
- (void)zoomFolderPanelOpen:(BOOL)open {
    NSPanel *panel = self.folderPanel;
    NSRect full = panel.frame;
    NSRect icon = self.folderPanelItem ? [self screenRectForItemPath:self.folderPanelItem.path] : NSZeroRect;
    if (NSIsEmptyRect(icon)) icon = NSInsetRect(full, full.size.width * 0.08, full.size.height * 0.08);

    NSView *content = panel.contentView;
    content.wantsLayer = YES;
    [content layoutSubtreeIfNeeded];
    CALayer *layer = content.layer;

    // Maps the panel onto the icon's rectangle, taking the layer's anchor point into account.
    CGSize size = layer.bounds.size;
    CGPoint anchor = CGPointMake(layer.anchorPoint.x * size.width, layer.anchorPoint.y * size.height);
    CGFloat sx = icon.size.width / full.size.width, sy = icon.size.height / full.size.height;
    CGPoint target = CGPointMake(icon.origin.x - full.origin.x, icon.origin.y - full.origin.y);
    CATransform3D small = CATransform3DMakeTranslation(target.x - layer.position.x + sx * anchor.x,
                                                       target.y - layer.position.y + sy * anchor.y, 0);
    small = CATransform3DScale(small, sx, sy, 1);

    CABasicAnimation *zoom = [CABasicAnimation animationWithKeyPath:@"transform"];
    zoom.fromValue = [NSValue valueWithCATransform3D:open ? small : CATransform3DIdentity];
    zoom.toValue = [NSValue valueWithCATransform3D:open ? CATransform3DIdentity : small];
    zoom.duration = open ? 0.26 : 0.2;
    zoom.timingFunction = [CAMediaTimingFunction functionWithName:open ? kCAMediaTimingFunctionEaseOut
                                                                       : kCAMediaTimingFunctionEaseIn];
    zoom.fillMode = kCAFillModeForwards;
    zoom.removedOnCompletion = NO;

    // Like Quick Look: solid almost at once while growing, and fading only at the very end
    // of shrinking.
    CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    fade.values = open ? @[@0, @1, @1] : @[@1, @1, @0];
    fade.keyTimes = open ? @[@0, @0.3, @1] : @[@0, @0.65, @1];
    fade.duration = zoom.duration;
    fade.fillMode = kCAFillModeForwards;
    fade.removedOnCompletion = NO;

    NSUInteger generation = ++self.folderZoomGeneration;
    panel.hasShadow = NO;
    if (open) [panel orderFront:nil];
    [layer removeAllAnimations];
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        if (generation != self.folderZoomGeneration) return;  // reopened or closed again meanwhile
        if (!open) [panel orderOut:nil];
        [layer removeAllAnimations];
        panel.hasShadow = YES;
        [panel invalidateShadow];
    }];
    [layer addAnimation:zoom forKey:@"zoom"];
    [layer addAnimation:fade forKey:@"fade"];
    [CATransaction commit];
}

- (void)folderPanelInfo:(id)sender {
    (void)sender;
    if (self.folderPanelItem) [self showInfoFor:self.folderPanelItem];
}

- (NSInteger)numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel *)panel {
    (void)panel;
    return (NSInteger)self.previewURLs.count;
}

- (id<QLPreviewItem>)previewPanel:(QLPreviewPanel *)panel previewItemAtIndex:(NSInteger)index {
    (void)panel;
    return self.previewURLs[(NSUInteger)index];
}

- (BOOL)previewPanel:(QLPreviewPanel *)panel handleEvent:(NSEvent *)event {
    (void)panel;
    // Plain arrow keys move the selection in the list, which updates the preview.
    // Everything else (zoom, full screen, Space) stays with Quick Look.
    if (event.type != NSEventTypeKeyDown) return NO;
    NSEventModifierFlags flags = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                                        NSEventModifierFlagControl | NSEventModifierFlagShift);
    unichar c = event.charactersIgnoringModifiers.length ? [event.charactersIgnoringModifiers characterAtIndex:0] : 0;
    BOOL arrow = c == NSUpArrowFunctionKey || c == NSDownArrowFunctionKey ||
                 c == NSLeftArrowFunctionKey || c == NSRightArrowFunctionKey;
    if (!arrow || flags) return NO;
    NSView *view = self.viewMode == ADBViewModeIcons ? self.collection : [self activeTable];
    [view keyDown:event];
    return YES;
}

#pragma mark Device menu

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != self.sidebar.menu) return;
    [menu removeAllItems];
    NSInteger row = self.sidebar.clickedRow;
    if (row < 0 || (NSUInteger)row >= self.sidebarRows.count) return;
    NSDictionary *info = self.sidebarRows[(NSUInteger)row];

    if (info[@"path"]) {
        NSMenuItem *open = [self itemWithTitle:@"Open" action:@selector(openPlaceFromMenu:) key:nil target:self];
        open.representedObject = info[@"path"];
        [menu addItem:open];
        NSMenuItem *copy = [self itemWithTitle:@"Copy Path" action:@selector(copyStringFromMenu:) key:nil target:self];
        copy.representedObject = info[@"path"];
        [menu addItem:copy];
        return;
    }

    if (info[@"offline"]) {
        NSMenuItem *again = [self itemWithTitle:@"Reconnect" action:@selector(reconnectFromMenu:) key:nil target:self];
        again.representedObject = info[@"offline"];
        [menu addItem:again];
        NSMenuItem *forget = [self itemWithTitle:@"Forget This Device" action:@selector(forgetFromMenu:) key:nil target:self];
        forget.representedObject = info[@"offline"];
        [menu addItem:forget];
        NSMenuItem *note = [[NSMenuItem alloc] initWithTitle:@"After the phone restarts, connect it by USB once more"
                                                      action:nil keyEquivalent:@""];
        note.enabled = NO;
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItem:note];
        return;
    }

    NSString *serial = info[@"serial"];
    if (!serial) return;
    BOOL ready = [info[@"state"] isEqualToString:@"device"];
    NSMenuItem *(^add)(NSString *, SEL) = ^NSMenuItem *(NSString *title, SEL action) {
        NSMenuItem *item = [self itemWithTitle:title action:action key:nil target:self];
        item.representedObject = serial;
        item.enabled = ready;
        [menu addItem:item];
        return item;
    };
    menu.autoenablesItems = NO;

    if (!ready) {
        NSMenuItem *hint = [[NSMenuItem alloc] initWithTitle:[info[@"state"] isEqualToString:@"unauthorized"]
                            ? @"Unlock the phone and allow USB debugging" : [NSString stringWithFormat:@"Device is %@", info[@"state"]]
                                                      action:nil keyEquivalent:@""];
        hint.enabled = NO;
        [menu addItem:hint];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    add(@"Device Info…", @selector(showDeviceInfo:));
    [menu addItem:[NSMenuItem separatorItem]];
    add(@"Take Screenshot", @selector(takeScreenshot:));
    add(@"Install APK…", @selector(installAPKFromMenu:));
    add(@"Open Shell in Terminal", @selector(openShell:));
    [menu addItem:[NSMenuItem separatorItem]];
    if ([self isWirelessSerial:serial]) {
        NSMenuItem *item = add(@"Disconnect", @selector(disconnectDevice:));
        item.enabled = YES;
        NSMenuItem *forget = add(@"Disconnect and Forget", @selector(forgetFromMenu:));
        forget.enabled = YES;
    } else {
        add(@"Connect over Wi-Fi", @selector(connectOverWiFi:));
    }
    NSMenuItem *reboot = [[NSMenuItem alloc] initWithTitle:@"Restart" action:nil keyEquivalent:@""];
    NSMenu *rebootMenu = [[NSMenu alloc] initWithTitle:@"Restart"];
    rebootMenu.autoenablesItems = NO;
    for (NSArray *mode in @[@[@"Restart", @""], @[@"Restart to Recovery", @"recovery"], @[@"Restart to Bootloader", @"bootloader"]]) {
        NSMenuItem *item = [self itemWithTitle:mode[0] action:@selector(rebootDevice:) key:nil target:self];
        item.representedObject = @{@"serial": serial, @"mode": mode[1]};
        item.enabled = ready;
        [rebootMenu addItem:item];
    }
    reboot.submenu = rebootMenu;
    reboot.enabled = ready;
    [menu addItem:reboot];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *copySerial = [self itemWithTitle:@"Copy Serial Number" action:@selector(copyStringFromMenu:) key:nil target:self];
    copySerial.representedObject = serial;
    [menu addItem:copySerial];
    NSString *model = self.deviceInfo[serial][@"model"];
    if (model.length) {
        NSMenuItem *copyModel = [self itemWithTitle:@"Copy Model Name" action:@selector(copyStringFromMenu:) key:nil target:self];
        copyModel.representedObject = model;
        [menu addItem:copyModel];
    }
}

- (BOOL)isWirelessSerial:(NSString *)serial {
    return [serial containsString:@":"] || [serial containsString:@"._adb-tls-connect"];
}

- (void)openPlaceFromMenu:(NSMenuItem *)sender {
    [self navigateTo:sender.representedObject];
}

- (void)copyStringFromMenu:(NSMenuItem *)sender {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:sender.representedObject forType:NSPasteboardTypeString];
}

- (void)takeScreenshot:(NSMenuItem *)sender {
    NSString *serial = sender.representedObject;
    NSString *name = self.deviceInfo[serial][@"name"] ?: @"Android";
    [self setStatus:[NSString stringWithFormat:@"Taking a screenshot of %@…", name] detail:@""];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Foldables have several screens and screencap takes the first one, which may be
        // switched off (a black picture). Capture the screen Android marks as active.
        NSString *command =
            @"id=$(dumpsys display | grep -o \"isActive=true, displayId=[0-9]*, uniqueId='local:[0-9]*'\" "
            @"| head -1 | sed \"s/.*local://; s/'//\"); "
            @"if [ -n \"$id\" ]; then screencap -p -d \"$id\"; else screencap -p; fi";
        NSData *raw = [self adbData:@[@"-s", serial, @"exec-out", command]];
        // Some phones (Honor) print a warning line before the image.
        NSRange start = raw ? [raw rangeOfData:[NSData dataWithBytes:"\x89PNG" length:4] options:0
                                         range:NSMakeRange(0, MIN(raw.length, (NSUInteger)4096))]
                            : NSMakeRange(NSNotFound, 0);
        NSData *png = start.location == NSNotFound ? nil : [raw subdataWithRange:NSMakeRange(start.location, raw.length - start.location)];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (png.length < 8 || memcmp(png.bytes, "\x89PNG", 4) != 0) {
                [self setStatus:@"Couldn't take a screenshot" detail:@""];
                [self showError:@"Couldn't take a screenshot" message:@"The phone may be locked with a secure screen, or the app on screen blocks screenshots."];
                return;
            }
            // Named like the Mac's own screenshots, on the Desktop.
            NSDateFormatter *f = [NSDateFormatter new];
            f.dateFormat = @"yyyy-MM-dd 'at' HH.mm.ss";
            NSString *desktop = NSSearchPathForDirectoriesInDomains(NSDesktopDirectory, NSUserDomainMask, YES).firstObject;
            NSString *file = [desktop stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"Screenshot %@ %@.png", name, [f stringFromDate:[NSDate date]]]];
            [png writeToFile:file atomically:YES];
            NSURL *url = [NSURL fileURLWithPath:file];
            [self setStatus:@"Screenshot saved to the Desktop" detail:@""];
            NSDictionary *attrs = @{NSFontAttributeName: self.detailLabel.font, NSForegroundColorAttributeName: NSColor.linkColor};
            self.detailLabel.attributedStringValue = [[NSAttributedString alloc] initWithString:@"Show in Finder ›" attributes:attrs];
            self.detailLabel.clickHandler = ^{
                [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
            };
            [self.window invalidateCursorRectsForView:self.detailLabel];
            [self scheduleHideTransferBar];
        });
    });
}

- (void)installAPKFromMenu:(NSMenuItem *)sender {
    NSString *serial = sender.representedObject;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    UTType *apk = [UTType typeWithFilenameExtension:@"apk"];
    if (apk) panel.allowedContentTypes = @[apk];
    panel.prompt = @"Install";
    panel.message = [NSString stringWithFormat:@"Choose apps to install on %@", self.deviceInfo[serial][@"name"] ?: serial];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        if (![serial isEqualToString:self.serial]) [self switchToDevice:serial];
        [self installAPKs:panel.URLs];
    }];
}

// A .command file opens in Terminal without asking for automation permission.
- (void)openShell:(NSMenuItem *)sender {
    NSString *serial = sender.representedObject;
    NSString *file = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"adb shell %@.command", [serial stringByReplacingOccurrencesOfString:@"/" withString:@"_"]]];
    NSString *script = [NSString stringWithFormat:@"#!/bin/sh\nclear\nexec %@ -s %@ shell\n",
                        [self shellQuote:[self adbPath]], [self shellQuote:serial]];
    [script writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod(file.fileSystemRepresentation, 0700);
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:file]];
}

- (void)connectOverWiFi:(NSMenuItem *)sender {
    NSString *serial = sender.representedObject;
    [self setStatus:@"Switching the phone to Wi-Fi debugging…" detail:@""];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *out = nil;
        [self runQuietShell:@"ip -f inet addr show wlan0 2>/dev/null | grep -m1 inet" serial:serial output:&out];
        NSArray *parts = [[out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                          componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *ip = parts.count > 1 ? [parts[1] componentsSeparatedByString:@"/"].firstObject : nil;
        NSString *error = nil;
        if (!ip.length) {
            error = @"The phone isn't on a Wi-Fi network.";
        } else if (![self runADB:@[@"-s", serial, @"tcpip", @"5555"] output:NULL error:&error]) {
            // error is set
        } else {
            NSString *connected = nil;
            for (int i = 0; i < 5; i++) {
                sleep(1);
                [self runADB:@[@"connect", [ip stringByAppendingString:@":5555"]] output:&connected error:NULL];
                if ([connected containsString:@"connected"] && ![connected containsString:@"cannot"]) break;
            }
            if (![connected containsString:@"connected"] || [connected containsString:@"cannot"]) error = connected ?: @"No answer";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                [self setStatus:@"Couldn't connect over Wi-Fi" detail:@""];
                [self showError:@"Couldn't connect over Wi-Fi" message:error];
            } else {
                [self rememberWireless:[ip stringByAppendingString:@":5555"] name:self.deviceInfo[serial][@"name"]];
                [self setStatus:[NSString stringWithFormat:@"Connected over Wi-Fi (%@)", ip] detail:@"You can unplug the cable"];
                [self scheduleHideTransferBar];
            }
            [self refreshDevice];
        });
    });
}

- (void)disconnectDevice:(NSMenuItem *)sender {
    NSString *serial = sender.representedObject;
    // Don't reconnect it behind the user's back right away.
    self.reconnectAttempts[serial] = [NSDate dateWithTimeIntervalSinceNow:600];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self runADB:@[@"disconnect", serial] output:NULL error:NULL];
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshDevice]; });
    });
}

- (void)rebootDevice:(NSMenuItem *)sender {
    NSString *serial = sender.representedObject[@"serial"];
    NSString *mode = sender.representedObject[@"mode"];
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"%@ %@?", sender.title, self.deviceInfo[serial][@"name"] ?: @"the phone"];
    alert.informativeText = mode.length ? @"The phone leaves Android and won't be available here until you start it normally again."
                                        : @"Transfers to and from the phone stop.";
    NSButton *go = [alert addButtonWithTitle:@"Restart"];
    go.hasDestructiveAction = mode.length > 0;
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSMutableArray *args = [NSMutableArray arrayWithObjects:@"-s", serial, @"reboot", nil];
        if (mode.length) [args addObject:mode];
        [self appendLog:[NSString stringWithFormat:@"REBOOT %@ %@", serial, mode]];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self runADB:args output:NULL error:NULL];
        });
    }];
}

#pragma mark Wi-Fi devices

- (NSArray<NSDictionary *> *)rememberedWireless {
    return [NSUserDefaults.standardUserDefaults arrayForKey:kWirelessDevicesKey] ?: @[];
}

- (void)rememberWireless:(NSString *)address name:(NSString *)name {
    if (!address.length) return;
    NSMutableArray *list = [NSMutableArray array];
    for (NSDictionary *d in [self rememberedWireless]) if (![d[@"address"] isEqualToString:address]) [list addObject:d];
    [list addObject:@{@"address": address, @"name": name ?: address}];
    [NSUserDefaults.standardUserDefaults setObject:list forKey:kWirelessDevicesKey];
}

- (void)forgetFromMenu:(NSMenuItem *)sender {
    NSString *address = sender.representedObject;
    NSMutableArray *list = [NSMutableArray array];
    for (NSDictionary *d in [self rememberedWireless]) if (![d[@"address"] isEqualToString:address]) [list addObject:d];
    [NSUserDefaults.standardUserDefaults setObject:list forKey:kWirelessDevicesKey];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self runADB:@[@"disconnect", address] output:NULL error:NULL];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reloadSidebar];
            [self refreshDevice];
        });
    });
}

- (void)reconnectFromMenu:(NSMenuItem *)sender {
    [self reconnectWireless:sender.representedObject force:YES];
}

- (NSArray<NSDictionary *> *)offlineWirelessDevices {
    NSMutableSet *present = [NSMutableSet set];
    for (NSDictionary *d in self.devices) [present addObject:d[@"serial"]];
    NSMutableArray *offline = [NSMutableArray array];
    for (NSDictionary *d in [self rememberedWireless]) if (![present containsObject:d[@"address"]]) [offline addObject:d];
    return offline;
}

// adb forgets a Wi-Fi phone after the Mac sleeps or adb restarts; keep asking for it
// (every 20 s at most) while it's remembered. The phone itself stays in Wi-Fi mode
// until it restarts.
- (void)reconnectWireless:(NSString *)address force:(BOOL)force {
    NSDate *next = self.reconnectAttempts[address];
    if (!force && next && next.timeIntervalSinceNow > 0) return;
    self.reconnectAttempts[address] = [NSDate dateWithTimeIntervalSinceNow:20];
    if (force) [self setStatus:[NSString stringWithFormat:@"Connecting to %@…", address] detail:@""];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *out = nil;
        [self runADB:@[@"connect", address] quiet:YES started:nil output:&out error:NULL];
        BOOL ok = [out containsString:@"connected"] && ![out containsString:@"cannot"] && ![out containsString:@"failed"];

        // On macOS 15 a long-running adb server can start getting "No route to host" for
        // Wi-Fi phones (after sleep or a network change) while the network itself is fine.
        // A fresh server connects at once, so restart it — not during a transfer, and at
        // most every two minutes.
        BOOL noRoute = !ok && [out localizedCaseInsensitiveContainsString:@"No route to host"];
        if (noRoute) {
            __block BOOL restart = NO;
            dispatch_sync(dispatch_get_main_queue(), ^{
                NSDate *last = self.adbServerRestartedAt;
                restart = !self.transferring && !self.pullsActive && (!last || -last.timeIntervalSinceNow > 120);
                if (restart) self.adbServerRestartedAt = [NSDate date];
            });
            if (restart) {
                [self appendLog:[NSString stringWithFormat:@"ADB SERVER RESTART (%@: %@)", address, out]];
                [self runADB:@[@"kill-server"] quiet:YES started:nil output:NULL error:NULL];
                [self runADB:@[@"start-server"] quiet:YES started:nil output:NULL error:NULL];
                [self runADB:@[@"connect", address] quiet:YES started:nil output:&out error:NULL];
                ok = [out containsString:@"connected"] && ![out containsString:@"cannot"] && ![out containsString:@"failed"];
                noRoute = !ok && [out localizedCaseInsensitiveContainsString:@"No route to host"];
                [self appendLog:[NSString stringWithFormat:@"ADB RECONNECT %@: %@", address, out]];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (force) {
                NSString *hint = noRoute
                    ? @"If it persists, allow ADB Finder in System Settings → Privacy & Security → Local Network."
                    : @"Is it on the same network? After a restart, connect it by USB once.";
                [self setStatus:ok ? @"Connected over Wi-Fi" : @"The phone isn't reachable over Wi-Fi" detail:ok ? @"" : hint];
                [self scheduleHideTransferBar];
            }
            if (ok) [self refreshDevice];
        });
    });
}

- (void)reconnectMissingWireless {
    for (NSDictionary *d in [self offlineWirelessDevices]) [self reconnectWireless:d[@"address"] force:NO];
}

#pragma mark Device info

- (void)showDeviceInfo:(NSMenuItem *)sender {
    NSString *serial = sender.representedObject;
    NSDictionary *known = self.deviceInfo[serial];

    NSPanel *window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 420, 500)
                                                 styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                           NSWindowStyleMaskUtilityWindow
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
    window.title = [NSString stringWithFormat:@"%@ Info", known[@"name"] ?: serial];
    window.releasedWhenClosed = NO;
    window.delegate = self;
    window.hidesOnDeactivate = NO;
    [self.infoWindows addObject:window];

    NSImageView *icon = [NSImageView imageViewWithImage:ADBSymbol(@"candybarphone", 40, NSFontWeightLight)];
    icon.contentTintColor = NSColor.controlAccentColor;
    NSTextField *title = [NSTextField labelWithString:known[@"name"] ?: serial];
    title.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
    NSTextField *subtitle = [NSTextField labelWithString:@"Loading…"];
    subtitle.textColor = NSColor.secondaryLabelColor;
    NSStackView *titles = [NSStackView stackViewWithViews:@[title, subtitle]];
    titles.orientation = NSUserInterfaceLayoutOrientationVertical;
    titles.alignment = NSLayoutAttributeLeading;
    titles.spacing = 2;
    NSStackView *header = [NSStackView stackViewWithViews:@[icon, titles]];
    header.spacing = 12;

    NSGridView *grid = [NSGridView gridViewWithNumberOfColumns:2 rows:0];
    grid.rowSpacing = 5;
    grid.columnSpacing = 10;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;

    NSButton *copy = [NSButton buttonWithTitle:@"Copy All" target:self action:@selector(copyDeviceInfo:)];
    NSButton *refresh = [NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refreshDeviceInfo:)];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[refresh, copy]];

    NSStackView *stack = [NSStackView stackViewWithViews:@[header, grid, buttons]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 14;
    stack.edgeInsets = NSEdgeInsetsMake(16, 18, 16, 18);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    window.contentView = [NSView new];
    [window.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:window.contentView.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor],
        [stack.widthAnchor constraintGreaterThanOrEqualToConstant:420],
        [buttons.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor constant:-18],
    ]];

    // The buttons find their window's data through these.
    copy.identifier = serial;
    refresh.identifier = serial;
    objc_setAssociatedObject(window, "grid", grid, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(window, "subtitle", subtitle, OBJC_ASSOCIATION_RETAIN);

    [window setContentSize:stack.fittingSize];
    [window center];
    [window makeKeyAndOrderFront:nil];
    [self loadDeviceInfo:serial into:window];
}

- (void)refreshDeviceInfo:(NSButton *)sender {
    [self loadDeviceInfo:sender.identifier into:(NSPanel *)sender.window];
}

- (void)copyDeviceInfo:(NSButton *)sender {
    NSString *text = objc_getAssociatedObject(sender.window, "text");
    if (!text) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
}

- (void)loadDeviceInfo:(NSString *)serial into:(NSPanel *)window {
    NSString *script =
        @"p() { echo \"$1=$(getprop $2)\"; }; "
        @"p manufacturer ro.product.manufacturer; p brand ro.product.brand; p model ro.product.model; "
        @"p device ro.product.device; p market ro.product.marketname; p vmarket ro.product.vendor.marketname; "
        @"p cmarket ro.config.marketing_name; p release ro.build.version.release; p sdk ro.build.version.sdk; "
        @"p patch ro.build.version.security_patch; p build ro.build.display.id; p abi ro.product.cpu.abi; "
        @"p soc ro.soc.model; p socmaker ro.soc.manufacturer; p platform ro.board.platform; "
        @"echo \"name=$(settings get global device_name 2>/dev/null)\"; "
        @"dumpsys battery 2>/dev/null | grep -E '^ *(level|status|health|temperature|AC powered|USB powered|Wireless powered):' "
        @"| sed 's/^ *//; s/: /=/; s/^/battery./'; "
        @"echo \"screen=$(wm size 2>/dev/null | tail -1 | sed 's/.*: //')\"; "
        @"echo \"density=$(wm density 2>/dev/null | tail -1 | sed 's/.*: //')\"; "
        @"echo \"ram=$(grep MemTotal /proc/meminfo | tr -s ' ' | cut -d' ' -f2)\"; "
        @"echo \"uptime=$(cut -d' ' -f1 /proc/uptime)\"; "
        @"echo \"ip=$(ip -f inet addr show wlan0 2>/dev/null | grep -m1 inet | tr -s ' ' | cut -d' ' -f3)\"; "
        @"echo \"kernel=$(uname -r)\"; echo \"root=$(command -v su)\"";

    NSDictionary *known = self.deviceInfo[serial];
    NSDictionary *deviceRow = nil;
    for (NSDictionary *d in self.devices) if ([d[@"serial"] isEqualToString:serial]) deviceRow = d;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *out = nil;
        [self runQuietShell:script serial:serial output:&out];
        NSMutableDictionary<NSString *, NSString *> *v = [NSMutableDictionary dictionary];
        for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
            NSRange eq = [line rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            NSString *value = [[line substringFromIndex:eq.location + 1]
                               stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (value.length && ![value isEqualToString:@"null"]) v[[line substringToIndex:eq.location]] = value;
        }
        unsigned long long freeBytes = 0, totalBytes = 0;
        [self spaceAt:kStorageRoot serial:serial free:&freeBytes total:&totalBytes];

        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray<NSArray *> *sections = [self deviceInfoSections:v serial:serial known:known
                                                          deviceRow:deviceRow free:freeBytes total:totalBytes];
            [self fillDeviceInfo:window sections:sections values:v];
        });
    });
}

- (NSArray<NSArray *> *)deviceInfoSections:(NSDictionary<NSString *, NSString *> *)v
                                    serial:(NSString *)serial
                                     known:(NSDictionary *)known
                                 deviceRow:(NSDictionary *)deviceRow
                                      free:(unsigned long long)freeBytes
                                     total:(unsigned long long)totalBytes {
    NSString *marketing = v[@"market"] ?: v[@"vmarket"] ?: v[@"cmarket"];
    NSString *model = marketing.length ? [NSString stringWithFormat:@"%@ (%@)", marketing, v[@"model"] ?: @""] : v[@"model"];

    NSString *android = v[@"release"] ? [NSString stringWithFormat:@"Android %@ (API %@)", v[@"release"], v[@"sdk"] ?: @"?"] : nil;

    NSString *soc = v[@"soc"].length ? [NSString stringWithFormat:@"%@%@", v[@"socmaker"].length ? [v[@"socmaker"] stringByAppendingString:@" "] : @"", v[@"soc"]]
                                     : v[@"platform"];
    NSString *processor = soc.length ? [NSString stringWithFormat:@"%@ · %@", soc, v[@"abi"] ?: @""] : v[@"abi"];

    // The kernel reports a bit less than what's installed; show the size on the box (16 GB).
    NSString *memory = nil;
    if (v[@"ram"]) {
        double gb = strtoull(v[@"ram"].UTF8String, NULL, 10) / 1024.0 / 1024.0;
        int nominal = 0;
        for (NSNumber *n in @[@1, @2, @3, @4, @6, @8, @10, @12, @16, @18, @20, @24, @32]) {
            if (n.doubleValue >= gb) { nominal = n.intValue; break; }
        }
        memory = nominal ? [NSString stringWithFormat:@"%d GB", nominal] : [NSString stringWithFormat:@"%.0f GB", gb];
    }

    NSString *screen = nil;
    if (v[@"screen"]) {
        screen = [v[@"screen"] stringByReplacingOccurrencesOfString:@"x" withString:@" × "];
        if (v[@"density"]) screen = [screen stringByAppendingFormat:@", %@ dpi", v[@"density"]];
    }

    NSString *battery = nil;
    if (v[@"battery.level"]) {
        NSDictionary *statuses = @{@"2": @"charging", @"3": @"on battery", @"4": @"not charging", @"5": @"full"};
        NSDictionary *healths = @{@"2": @"good", @"3": @"overheating", @"4": @"worn out", @"5": @"over voltage", @"7": @"cold"};
        NSMutableArray *parts = [NSMutableArray arrayWithObject:[v[@"battery.level"] stringByAppendingString:@" %"]];
        NSString *status = statuses[v[@"battery.status"] ?: @""];
        if (status) {
            NSString *source = [v[@"battery.AC powered"] isEqualToString:@"true"] ? @" (charger)"
                             : [v[@"battery.USB powered"] isEqualToString:@"true"] ? @" (USB)"
                             : [v[@"battery.Wireless powered"] isEqualToString:@"true"] ? @" (wireless)" : @"";
            [parts addObject:[status stringByAppendingString:[status isEqualToString:@"on battery"] ? @"" : source]];
        }
        if (v[@"battery.temperature"]) [parts addObject:[NSString stringWithFormat:@"%.1f °C", v[@"battery.temperature"].doubleValue / 10]];
        NSString *health = healths[v[@"battery.health"] ?: @""];
        if (health) [parts addObject:[@"health " stringByAppendingString:health]];
        battery = [parts componentsJoinedByString:@", "];
    }

    NSString *uptime = nil;
    if (v[@"uptime"]) {
        long seconds = (long)v[@"uptime"].doubleValue;
        long days = seconds / 86400, hours = (seconds % 86400) / 3600, minutes = (seconds % 3600) / 60;
        uptime = days ? [NSString stringWithFormat:@"%ld d %ld h %ld min", days, hours, minutes]
                      : [NSString stringWithFormat:@"%ld h %ld min", hours, minutes];
    }

    NSString *storage = totalBytes ? [NSString stringWithFormat:@"%@ free of %@", ADBFormatBytes(freeBytes), ADBFormatBytes(totalBytes)] : nil;
    NSArray *volumes = known[@"volumes"];
    if (volumes.count) storage = [storage stringByAppendingFormat:@" · SD card: %@", [volumes componentsJoinedByString:@", "]];

    NSString *connection = [self isWirelessSerial:serial] ? @"Wi-Fi" : @"USB";
    (void)deviceRow;

    NSString *ip = v[@"ip"] ? [v[@"ip"] componentsSeparatedByString:@"/"].firstObject : nil;

    return @[
        @[@"Device", @[
            @[@"Name", v[@"name"] ?: known[@"name"] ?: @""],
            @[@"Model", model ?: @""],
            @[@"Manufacturer", v[@"manufacturer"] ?: @""],
            @[@"Codename", v[@"device"] ?: @""],
            @[@"Serial", serial],
            @[@"Connection", connection],
        ]],
        @[@"Software", @[
            @[@"Android", android ?: @""],
            @[@"Security patch", v[@"patch"] ?: @""],
            @[@"Build", v[@"build"] ?: @""],
            @[@"Kernel", v[@"kernel"] ?: @""],
            @[@"Root", v[@"root"].length ? @"Yes (su found)" : @"No"],
        ]],
        @[@"Hardware", @[
            @[@"Processor", processor ?: @""],
            @[@"Memory", memory ?: @""],
            @[@"Screen", screen ?: @""],
            @[@"Battery", battery ?: @""],
            @[@"Storage", storage ?: @""],
        ]],
        @[@"Network", @[
            @[@"Wi-Fi IP", ip ?: @"Not connected"],
            @[@"Up for", uptime ?: @""],
        ]],
    ];
}

- (void)fillDeviceInfo:(NSPanel *)window sections:(NSArray<NSArray *> *)sections values:(NSDictionary *)v {
    NSGridView *grid = objc_getAssociatedObject(window, "grid");
    NSTextField *subtitle = objc_getAssociatedObject(window, "subtitle");
    if (!grid) return;
    while (grid.numberOfRows) [grid removeRowAtIndex:0];

    NSMutableArray *lines = [NSMutableArray array];
    for (NSArray *section in sections) {
        NSTextField *heading = [NSTextField labelWithString:section[0]];
        heading.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
        NSGridRow *row = [grid addRowWithViews:@[heading, [NSGridCell emptyContentView]]];
        row.topPadding = grid.numberOfRows > 1 ? 8 : 0;
        [row mergeCellsInRange:NSMakeRange(0, 2)];
        [row cellAtIndex:0].xPlacement = NSGridCellPlacementLeading;
        [lines addObject:section[0]];

        for (NSArray *pair in section[1]) {
            if (![pair[1] length]) continue;
            NSTextField *key = [self infoKey:pair[0]];
            NSTextField *value = [self infoValue:pair[1]];
            value.preferredMaxLayoutWidth = 280;
            NSGridRow *r = [grid addRowWithViews:@[key, value]];
            r.rowAlignment = NSGridRowAlignmentFirstBaseline;
            [lines addObject:[NSString stringWithFormat:@"  %@: %@", pair[0], pair[1]]];
        }
    }
    objc_setAssociatedObject(window, "text", [lines componentsJoinedByString:@"\n"], OBJC_ASSOCIATION_RETAIN);

    NSString *marketing = v[@"market"] ?: v[@"vmarket"] ?: v[@"cmarket"] ?: v[@"model"];
    subtitle.stringValue = v[@"release"] ? [NSString stringWithFormat:@"%@ · Android %@", marketing ?: @"", v[@"release"]]
                                         : @"Couldn't read the phone";
    NSPoint top = NSMakePoint(NSMinX(window.frame), NSMaxY(window.frame));
    [window setContentSize:window.contentView.subviews.firstObject.fittingSize];
    [window setFrameTopLeftPoint:top];
}

#pragma mark Folder summaries

- (NSString *)statsKeyFor:(RemoteItem *)item {
    return [NSString stringWithFormat:@"%@|%@|%.0f", self.serial, item.path, item.modified.timeIntervalSince1970];
}

// Total size and number of files and folders inside, counted on the phone.
- (void)loadStatsFor:(RemoteItem *)item completion:(void (^)(NSDictionary *stats))completion {
    NSString *key = [self statsKeyFor:item];
    if (self.folderStats[key]) {
        completion(self.folderStats[key]);
        return;
    }
    NSString *serial = [self.serial copy];
    NSString *command = [NSString stringWithFormat:
        @"cd %@ 2>/dev/null || exit 1; du -sk . 2>/dev/null | cut -f1; "
        @"find . -type f 2>/dev/null | wc -l; find . -mindepth 1 -type d 2>/dev/null | wc -l; "
        @"ls -A | wc -l; ls | wc -l", [self shellQuote:item.path]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *out = nil;
        BOOL ok = [self runQuietShell:command serial:serial output:&out];
        NSArray<NSString *> *lines = [out componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
        NSMutableArray *numbers = [NSMutableArray array];
        for (NSString *line in lines) {
            NSString *t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (t.length) [numbers addObject:@(strtoull(t.UTF8String, NULL, 10))];
        }
        NSDictionary *stats = ok && numbers.count >= 3
            ? @{@"bytes": @([numbers[0] unsignedLongLongValue] * 1024), @"files": numbers[1], @"folders": numbers[2],
                @"children": numbers.count > 3 ? numbers[3] : @(-1), @"visibleChildren": numbers.count > 4 ? numbers[4] : @(-1)}
            : @{};
        dispatch_async(dispatch_get_main_queue(), ^{
            if (stats.count) self.folderStats[key] = stats;
            completion(stats);
        });
    });
}

- (NSString *)describeStats:(NSDictionary *)stats {
    if (!stats.count) return nil;
    NSUInteger files = [stats[@"files"] unsignedIntegerValue], folders = [stats[@"folders"] unsignedIntegerValue];
    NSString *(^count)(NSUInteger, NSString *) = ^NSString *(NSUInteger n, NSString *noun) {
        return [NSString stringWithFormat:@"%@ %@%@", [NSNumberFormatter localizedStringFromNumber:@(n)
                numberStyle:NSNumberFormatterDecimalStyle], noun, n == 1 ? @"" : @"s"];
    };
    NSString *contents = folders ? [NSString stringWithFormat:@"%@, %@", count(files, @"file"), count(folders, @"folder")]
                                 : count(files, @"file");
    return [NSString stringWithFormat:@"%@ · %@", ADBFormatBytes([stats[@"bytes"] unsignedLongLongValue]), contents];
}

#pragma mark Get Info

- (void)getInfo:(id)sender {
    (void)sender;
    NSArray<RemoteItem *> *selected = [self selectedItems];
    // Finder opens one window per item; more than a handful is never what you meant.
    for (RemoteItem *item in [selected subarrayWithRange:NSMakeRange(0, MIN(selected.count, 8))]) [self showInfoFor:item];
}

- (NSTextField *)infoValue:(NSString *)text {
    NSTextField *field = [NSTextField wrappingLabelWithString:text ?: @""];
    field.font = [NSFont systemFontOfSize:12];
    field.selectable = YES;
    field.preferredMaxLayoutWidth = 230;
    return field;
}

- (NSTextField *)infoKey:(NSString *)text {
    NSTextField *field = [NSTextField labelWithString:text];
    field.font = [NSFont systemFontOfSize:12];
    field.textColor = NSColor.secondaryLabelColor;
    field.alignment = NSTextAlignmentRight;
    return field;
}

- (void)showInfoFor:(RemoteItem *)item {
    NSPanel *window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 340, 520)
                                                 styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                           NSWindowStyleMaskUtilityWindow
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
    window.title = [NSString stringWithFormat:@"%@ Info", item.name];
    window.releasedWhenClosed = NO;
    window.delegate = self;
    window.hidesOnDeactivate = NO;
    window.becomesKeyOnlyIfNeeded = NO;

    NSImageView *icon = [NSImageView imageViewWithImage:[self thumbnailForItem:item request:YES] ?: ADBIconForItem(item)];
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *name = [NSTextField wrappingLabelWithString:item.name];
    name.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    name.selectable = YES;
    name.preferredMaxLayoutWidth = 230;
    NSTextField *summary = [self infoValue:item.directory ? ([self countTextForItem:item] ?: @"Folder")
                                                          : ADBFormatBytes(item.size)];
    summary.textColor = NSColor.secondaryLabelColor;
    NSStackView *titles = [NSStackView stackViewWithViews:@[name, summary]];
    titles.orientation = NSUserInterfaceLayoutOrientationVertical;
    titles.alignment = NSLayoutAttributeLeading;
    titles.spacing = 2;
    NSStackView *header = [NSStackView stackViewWithViews:@[icon, titles]];
    header.alignment = NSLayoutAttributeCenterY;
    header.spacing = 12;

    NSMutableArray<NSArray<NSView *> *> *rows = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSTextField *> *values = [NSMutableDictionary dictionary];
    void (^addRow)(NSString *, NSString *) = ^(NSString *key, NSString *value) {
        NSTextField *v = [self infoValue:value];
        values[key] = v;
        [rows addObject:@[[self infoKey:[key stringByAppendingString:@":"]], v]];
    };
    addRow(@"Kind", item.kind);
    addRow(@"Size", item.directory ? @"Calculating…"
                  : [NSString stringWithFormat:@"%@ bytes (%@)", [NSNumberFormatter localizedStringFromNumber:@(item.size)
                       numberStyle:NSNumberFormatterDecimalStyle], ADBFormatBytes(item.size)]);
    if (item.directory) addRow(@"Contains", @"Calculating…");
    addRow(@"Where", ADBParentPath(item.path));
    addRow(@"Modified", item.modified ? [self.dateFormatter stringFromDate:item.modified] : @"--");
    addRow(@"Permissions", @"…");
    BOOL media = ADBIsImageName(item.name) || ADBIsVideoName(item.name);
    if (media) addRow(@"Dimensions", @"…");
    if (ADBIsVideoName(item.name)) addRow(@"Duration", @"…");
    if (ADBIsImageName(item.name)) {
        addRow(@"Camera", @"…");
        addRow(@"Taken", @"…");
    }

    NSGridView *grid = [NSGridView gridViewWithViews:rows];
    grid.rowSpacing = 5;
    grid.columnSpacing = 8;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    for (NSInteger r = 0; r < grid.numberOfRows; r++) [grid rowAtIndex:r].rowAlignment = NSGridRowAlignmentFirstBaseline;

    NSImageView *preview = [NSImageView new];
    preview.imageScaling = NSImageScaleProportionallyUpOrDown;
    preview.image = [self thumbnailForItem:item large:YES request:YES] ?: (item.directory ? nil : ADBIconForItem(item));
    preview.translatesAutoresizingMaskIntoConstraints = NO;
    preview.hidden = item.directory;

    NSBox *line1 = [self separator], *line2 = [self separator];
    NSArray *parts = item.directory ? @[header, line1, grid] : @[header, line1, grid, line2, preview];
    NSStackView *stack = [NSStackView stackViewWithViews:parts];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.edgeInsets = NSEdgeInsetsMake(16, 16, 16, 16);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    window.contentView = [NSView new];
    [window.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:window.contentView.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor],
        [stack.widthAnchor constraintEqualToConstant:340],
        [icon.widthAnchor constraintEqualToConstant:56],
        [icon.heightAnchor constraintEqualToConstant:56],
        [line1.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-32],
    ]];
    if (!item.directory) {
        [NSLayoutConstraint activateConstraints:@[
            [line2.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-32],
            [preview.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-32],
            [preview.heightAnchor constraintEqualToConstant:220],
        ]];
    }
    // As tall as its contents.
    [window setContentSize:stack.fittingSize];

    // Cascade from the main window, like Finder's Info windows.
    NSPoint origin = NSMakePoint(NSMaxX(self.window.frame) - 360 - 24.0 * self.infoWindows.count,
                                 NSMaxY(self.window.frame) - 40 - 24.0 * self.infoWindows.count);
    [window layoutIfNeeded];
    [window setFrameTopLeftPoint:origin];
    [self.infoWindows addObject:window];
    [window makeKeyAndOrderFront:nil];

    // Details that need the phone.
    NSString *serial = [self.serial copy];
    __weak NSPanel *weakWindow = window;
    void (^set)(NSString *, NSString *) = ^(NSString *key, NSString *value) {
        NSTextField *field = values[key];
        if (!field || !weakWindow) return;
        field.stringValue = value.length ? value : @"--";
    };

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *out = nil;
        [self runQuietShell:[NSString stringWithFormat:@"stat -L -c '%%A|%%U|%%G|%%X' %@", [self shellQuote:item.path]]
                     serial:serial output:&out];
        NSArray<NSString *> *f = [out componentsSeparatedByString:@"|"];
        NSDictionary *media = ADBIsImageName(item.name) ? [self imageInfoFor:item serial:serial]
                            : (ADBIsVideoName(item.name) ? [self videoInfoFor:item serial:serial] : @{});
        dispatch_async(dispatch_get_main_queue(), ^{
            set(@"Permissions", f.count >= 3 ? [NSString stringWithFormat:@"%@  %@ : %@", f[0], f[1], f[2]] : @"--");
            for (NSString *key in @[@"Dimensions", @"Duration", @"Camera", @"Taken"]) set(key, media[key]);
        });
    });

    if (item.directory) {
        [self loadStatsFor:item completion:^(NSDictionary *stats) {
            if (!stats.count) {
                set(@"Size", @"--");
                set(@"Contains", @"--");
                return;
            }
            unsigned long long bytes = [stats[@"bytes"] unsignedLongLongValue];
            set(@"Size", [NSString stringWithFormat:@"%@ on disk", ADBFormatBytes(bytes)]);
            set(@"Contains", [[self describeStats:stats] componentsSeparatedByString:@" · "].lastObject);
            summary.stringValue = [self describeStats:stats];
        }];
    }
}

- (void)windowWillClose:(NSNotification *)notification {
    if ([self.infoWindows containsObject:notification.object]) {
        NSWindow *window = notification.object;
        window.delegate = nil;
        [self.infoWindows removeObject:window];
    }
}

// ImageIO needs the frame header (SOF), but phones put large vendor blocks before it
// (Honor: ~330 KB). Walk the segment headers on the device and keep just the EXIF
// block and the few KB around the frame header.
- (NSData *)compactJPEGHeader:(NSData *)head item:(RemoteItem *)item serial:(NSString *)serial {
    const uint8_t *b = head.bytes;
    if (head.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return nil;
    NSData *exif = nil;
    uint64_t offset = 2;
    for (int i = 0; i < 64 && offset + 4 <= item.size; i++) {
        NSData *marker = offset + 4 <= head.length ? [head subdataWithRange:NSMakeRange((NSUInteger)offset, 4)]
                                                   : [self readRemote:item.path offset:offset length:4 serial:serial];
        if (marker.length < 4) return nil;
        const uint8_t *m = marker.bytes;
        if (m[0] != 0xFF) return nil;
        if (m[1] < 0xE0 || m[1] > 0xEF) {
            // First non-APP segment: the tables and the frame header follow.
            if (!exif || offset + 4 <= head.length) return nil;
            NSData *tables = [self readRemote:item.path offset:offset length:MIN(4096, item.size - offset) serial:serial];
            if (!tables) return nil;
            NSMutableData *compact = [NSMutableData dataWithBytes:"\xFF\xD8" length:2];
            [compact appendData:exif];
            [compact appendData:tables];
            [compact appendBytes:"\xFF\xD9" length:2];
            return compact;
        }
        uint64_t length = ADBReadBE(m + 2, 2);
        if (m[1] == 0xE1 && !exif && offset + 2 + length <= head.length && length > 6 &&
            memcmp(b + offset + 4, "Exif", 4) == 0) {
            exif = [head subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)(2 + length))];
        }
        offset += 2 + length;
    }
    return nil;
}

// Pixel size, camera and date from the start of an image (its EXIF header).
- (NSDictionary *)imageInfoFor:(RemoteItem *)item serial:(NSString *)serial {
    NSData *head = [self adbData:@[@"-s", serial, @"exec-out",
                                   [NSString stringWithFormat:@"head -c %llu %@", kJPEGHeadBytes, [self shellQuote:item.path]]]];
    if (head && ADBIsJPEGName(item.name)) head = [self compactJPEGHeader:head item:item serial:serial] ?: head;
    CGImageSourceRef src = head ? CGImageSourceCreateWithData((__bridge CFDataRef)head, NULL) : NULL;
    if (!src) return @{};
    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
    CFRelease(src);
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    NSDictionary *exifProps = props[(__bridge NSString *)kCGImagePropertyExifDictionary];
    NSInteger w = [exifProps[(__bridge NSString *)kCGImagePropertyExifPixelXDimension] integerValue]
                ?: [props[(__bridge NSString *)kCGImagePropertyPixelWidth] integerValue];
    NSInteger h = [exifProps[(__bridge NSString *)kCGImagePropertyExifPixelYDimension] integerValue]
                ?: [props[(__bridge NSString *)kCGImagePropertyPixelHeight] integerValue];
    NSInteger orientation = [props[(__bridge NSString *)kCGImagePropertyOrientation] integerValue]
                         ?: [props[(__bridge NSString *)kCGImagePropertyTIFFDictionary][(__bridge NSString *)kCGImagePropertyTIFFOrientation] integerValue];
    if (orientation >= 5) { NSInteger t = w; w = h; h = t; }
    if (w && h) info[@"Dimensions"] = [NSString stringWithFormat:@"%ld × %ld", (long)w, (long)h];
    NSDictionary *tiff = props[(__bridge NSString *)kCGImagePropertyTIFFDictionary];
    NSString *make = tiff[(__bridge NSString *)kCGImagePropertyTIFFMake], *model = tiff[(__bridge NSString *)kCGImagePropertyTIFFModel];
    if (model.length) info[@"Camera"] = [model hasPrefix:make ?: @"~"] || !make.length ? model : [NSString stringWithFormat:@"%@ %@", make, model];
    NSString *taken = props[(__bridge NSString *)kCGImagePropertyExifDictionary][(__bridge NSString *)kCGImagePropertyExifDateTimeOriginal];
    if (taken.length) {
        NSDateFormatter *exif = [NSDateFormatter new];
        exif.dateFormat = @"yyyy:MM:dd HH:mm:ss";
        exif.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        NSDate *date = [exif dateFromString:taken];
        info[@"Taken"] = date ? [self.dateFormatter stringFromDate:date] : taken;
    }
    return info;
}

// Duration and frame size from a video's index (moov), without reading the video itself.
- (NSDictionary *)videoInfoFor:(RemoteItem *)item serial:(NSString *)serial {
    uint64_t offset = 0;
    NSData *moov = [self fetchMoovFor:item serial:serial head:NULL offset:&offset];
    size_t p, e;
    if (!moov || !ADBFindBox(moov.bytes, 0, moov.length, "moov", &p, &e)) return @{};
    const uint8_t *b = moov.bytes;
    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    size_t mp, me;
    if (ADBFindBox(b, p, e, "mvhd", &mp, &me) && me - mp >= 32) {
        BOOL v1 = b[mp] == 1;
        uint64_t scale = ADBReadBE(b + mp + (v1 ? 20 : 12), 4);
        uint64_t duration = v1 ? ADBReadBE(b + mp + 24, 8) : ADBReadBE(b + mp + 16, 4);
        if (scale) info[@"Duration"] = ADBFormatDuration((double)duration / (double)scale);
    }
    size_t from = p, tp, te;
    while (ADBFindBox(b, from, e, "trak", &tp, &te)) {
        from = te;
        size_t ap, ae, hp, he, kp, ke;
        if (!ADBFindBox(b, tp, te, "mdia", &ap, &ae) || !ADBFindBox(b, ap, ae, "hdlr", &hp, &he) ||
            he - hp < 12 || memcmp(b + hp + 8, "vide", 4) != 0) continue;
        if (!ADBFindBox(b, tp, te, "tkhd", &kp, &ke) || ke - kp < 44) continue;
        uint64_t w = ADBReadBE(b + ke - 8, 4) >> 16, h = ADBReadBE(b + ke - 4, 4) >> 16;
        // A rotated track (portrait video) has a zero first matrix entry.
        if (ADBReadBE(b + ke - 44, 4) == 0) { uint64_t t = w; w = h; h = t; }
        if (w && h) info[@"Dimensions"] = [NSString stringWithFormat:@"%llu × %llu", w, h];
        break;
    }
    return info;
}

#pragma mark Destination paths

- (NSString *)normalizedPath:(NSString *)path {
    NSString *p =
        [path stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (!p.length) return kStorageRoot;

    if ([p hasPrefix:@"~"]) {
        p = [kStorageRoot stringByAppendingString:[p substringFromIndex:1]];
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

    // Resolve "." and ".." the way the device would.
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *part in [p componentsSeparatedByString:@"/"]) {
        if (!part.length || [part isEqualToString:@"."]) continue;
        if ([part isEqualToString:@".."]) {
            [parts removeLastObject];
            continue;
        }
        [parts addObject:part];
    }
    return [@"/" stringByAppendingString:[parts componentsJoinedByString:@"/"]];
}

#pragma mark ADB

- (NSString *)adbPath {
    if (self.cachedADBPath) return self.cachedADBPath;

    NSDictionary *env = NSProcessInfo.processInfo.environment;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    // Explicit override for unusual installs.
    if ([env[@"ADB_FINDER_ADB"] length]) [paths addObject:env[@"ADB_FINDER_ADB"]];
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
        NSString *path = [dir stringByAppendingPathComponent:[kLogName stringByAppendingPathExtension:@"log"]];
        NSFileManager *fm = [NSFileManager defaultManager];

        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

        unsigned long long size = [[fm attributesOfItemAtPath:path error:nil] fileSize];
        if (size > kMaxLogBytes) {
            NSString *old = [dir stringByAppendingPathComponent:[kLogName stringByAppendingString:@".old.log"]];
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

// Free and total bytes on the filesystem holding `path` (0 if unknown).
- (void)spaceAt:(NSString *)path serial:(NSString *)serial free:(unsigned long long *)freeBytes total:(unsigned long long *)totalBytes {
    *freeBytes = 0;
    if (totalBytes) *totalBytes = 0;
    NSString *out = nil;
    if (![self runQuietShell:[NSString stringWithFormat:@"df -k %@", [self shellQuote:path]]
                      serial:serial
                      output:&out]) {
        return;
    }
    NSString *last = [[out componentsSeparatedByString:@"\n"] lastObject];
    NSMutableArray *columns = [NSMutableArray array];
    for (NSString *c in [last componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (c.length) [columns addObject:c];
    }
    if (columns.count < 4) return;
    *freeBytes = strtoull([columns[3] UTF8String], NULL, 10) * 1024ull;
    if (totalBytes) *totalBytes = strtoull([columns[1] UTF8String], NULL, 10) * 1024ull;
}

- (unsigned long long)freeBytesAt:(NSString *)path serial:(NSString *)serial {
    unsigned long long freeBytes = 0;
    [self spaceAt:path serial:serial free:&freeBytes total:NULL];
    return freeBytes;
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
                        @"$(getprop ro.config.marketing_name)|$(getprop ro.product.model)|$(getprop ro.build.version.release)|"
                        @"$(settings get global device_name 2>/dev/null)\"; "
                        // Removable volumes are real folders in /storage; sdcard0 and friends are links.
                        @"for v in /storage/*; do [ -L \"$v\" ] || [ \"$v\" = /storage/emulated ] || [ \"$v\" = /storage/self ] || echo \"${v##*/}\"; done"
                 serial:serial
                 output:&out];

    NSArray<NSString *> *outputLines = [out ?: @"" componentsSeparatedByString:@"\n"];
    NSArray<NSString *> *lines = [outputLines.firstObject ?: @"" componentsSeparatedByString:@"|"];
    NSString *(^line)(NSUInteger) = ^NSString *(NSUInteger i) {
        if (i >= lines.count) return @"";
        return [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    };

    NSString *model = line(0).length ? line(0) : (line(1).length ? line(1) : (line(2).length ? line(2) : line(3)));
    if (!model.length) model = modelHint.length ? modelHint : serial;
    model = [model stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    // The name the owner gave the phone ("Anna's Pixel"), like Finder shows for iPhones.
    NSString *given = line(5);
    NSString *name = given.length && ![given isEqualToString:@"null"] ? given : model;

    // Removable storage shows up in /storage as XXXX-XXXX next to "emulated" and "self".
    NSMutableArray *volumes = [NSMutableArray array];
    for (NSUInteger i = 1; i < outputLines.count; i++) {
        NSString *v = [outputLines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!v.length || [v isEqualToString:@"*"] || [v isEqualToString:@"emulated"] || [v isEqualToString:@"self"] ||
            [v containsString:@" "] || [v containsString:@":"]) continue;
        [volumes addObject:v];
    }

    return @{@"name": name, @"model": model, @"android": line(4), @"volumes": volumes};
}

- (void)refreshDevice {
    if (self.deviceRefreshRunning) {
        self.deviceRefreshQueued = YES;
        return;
    }
    self.deviceRefreshRunning = YES;

    NSString *preferred = [self.serial copy];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *out = nil;
        NSString *err = nil;
        BOOL ok = [self runADB:@[@"devices", @"-l"] quiet:YES started:nil output:&out error:&err];

        NSMutableArray<NSDictionary *> *devices = [NSMutableArray array];
        NSString *found = nil;
        NSString *otherState = nil;

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
                NSString *model = @"";
                for (NSString *part in parts) {
                    if ([part hasPrefix:@"model:"]) model = [part substringFromIndex:6];
                }
                [devices addObject:@{@"serial": serial, @"state": state, @"model": model}];

                if ([state isEqualToString:@"device"]) {
                    // Stick with the current phone while it stays connected.
                    if (!found || [serial isEqualToString:preferred]) found = serial;
                } else if (!otherState) {
                    otherState = state;
                }
            }
        }

        NSMutableDictionary *infos = [NSMutableDictionary dictionary];
        for (NSDictionary *device in devices) {
            if (![device[@"state"] isEqualToString:@"device"]) continue;
            NSString *serial = device[@"serial"];
            NSDictionary *info = self.deviceInfo[serial];
            if (!info) info = [self loadInfoForSerial:serial modelHint:device[@"model"]];

            // df is cheap but not free; refresh it occasionally, not on every poll.
            NSDate *checked = info[@"freeCheckedAt"];
            if ([serial isEqualToString:found] && (!checked || -checked.timeIntervalSinceNow > 20)) {
                unsigned long long freeBytes = 0, totalBytes = 0;
                [self spaceAt:kStorageRoot serial:serial free:&freeBytes total:&totalBytes];
                NSMutableDictionary *updated = [info mutableCopy];
                updated[@"free"] = @(freeBytes);
                updated[@"total"] = @(totalBytes);
                updated[@"freeCheckedAt"] = [NSDate date];
                info = updated;
            }
            infos[serial] = info;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.deviceRefreshRunning = NO;
            [self.deviceInfo addEntriesFromDictionary:infos];

            BOOL noADB = !ok && [err containsString:@"adb was not found"];
            NSString *state = found ? @"device" : (noADB ? @"noadb" : (otherState ?: @"none"));
            BOOL listChanged = ![devices isEqualToArray:self.devices];
            BOOL stateChanged = ![state isEqualToString:self.deviceState ?: @""];
            self.devices = devices;
            self.deviceState = state;

            // Don't switch phones under a running transfer.
            if (!self.transferring && ![found ?: @"" isEqualToString:self.serial ?: @""]) {
                [self switchToDevice:found];
            } else if (listChanged || infos.count) {
                [self reloadSidebar];
                [self updateTitle];
            }
            if (stateChanged && !self.serial.length) [self updateEmptyState];
            [self updateStorageCard];
            [self updateInfoLabel];

            for (NSDictionary *device in devices) {
                if ([device[@"state"] isEqualToString:@"device"] && [self isWirelessSerial:device[@"serial"]] &&
                    [device[@"serial"] rangeOfString:@"._adb-tls"].location == NSNotFound) {
                    BOOL known = NO;
                    for (NSDictionary *d in [self rememberedWireless]) known |= [d[@"address"] isEqualToString:device[@"serial"]];
                    if (!known) [self rememberWireless:device[@"serial"] name:self.deviceInfo[device[@"serial"]][@"name"]];
                }
            }
            if (ok) [self reconnectMissingWireless];
            if (listChanged) [self reloadSidebar];

            if (self.deviceRefreshQueued) {
                self.deviceRefreshQueued = NO;
                [self refreshDevice];
            }
        });
    });
}

- (void)switchToDevice:(NSString *)serial {
    NSString *old = self.serial;
    self.serial = serial;
    [self.backStack removeAllObjects];
    [self.forwardStack removeAllObjects];
    self.previewURLs = nil;
    [self.listingCache removeAllObjects];
    [self.staleListings removeAllObjects];
    [self.thumbStack removeAllObjects];
    [self.thumbPending removeAllObjects];
    if (serial.length) [self markThumbnailsUsed:serial];

    if (serial.length) {
        if (old.length) [self appendLog:[NSString stringWithFormat:@"SWITCH DEVICE %@ → %@", old, serial]];
        NSString *last = [NSUserDefaults.standardUserDefaults stringForKey:kLastFolderKey];
        self.currentPath = nil;
        [self reloadSidebar];
        [self showFolder:last.length ? last : kStorageRoot selecting:nil];
        [self invalidateFreeSpace];

        if (self.launchURLs.count) {
            NSArray *urls = self.launchURLs;
            self.launchURLs = nil;
            [self uploadURLs:urls toFolder:self.currentPath];
        }
        [self startNextPendingDrop];
    } else {
        self.currentPath = nil;
        self.allItems = @[];
        self.items = @[];
        self.loadError = nil;
        [self reloadViews];
        [self reloadSidebar];
        [self updateTitle];
        [self updatePathBar];
        [self updateNavControl];
        [self updateEmptyState];
        if ([QLPreviewPanel sharedPreviewPanelExists]) [[QLPreviewPanel sharedPreviewPanel] orderOut:nil];
    }
    [self updateStorageCard];
    [self updateInfoLabel];
}

- (void)updateStorageCard {
    NSDictionary *info = self.serial.length ? self.deviceInfo[self.serial] : nil;
    unsigned long long freeBytes = [info[@"free"] unsignedLongLongValue];
    unsigned long long totalBytes = [info[@"total"] unsignedLongLongValue];
    if (!info || !totalBytes) {
        self.storageCard.hidden = YES;
        return;
    }
    self.storageCard.hidden = NO;
    self.storageBar.doubleValue = totalBytes ? 1.0 - (double)freeBytes / (double)totalBytes : 0;
    self.storageLabel.stringValue = [NSString stringWithFormat:@"%@ free of %@",
                                     ADBFormatBytes(freeBytes), ADBFormatBytes(totalBytes)];
    self.storageLabel.toolTip = self.storageLabel.stringValue;
}

- (void)invalidateFreeSpace {
    NSMutableDictionary *info = [self.deviceInfo[self.serial ?: @""] mutableCopy];
    if (!info) return;
    [info removeObjectForKey:@"freeCheckedAt"];
    self.deviceInfo[self.serial] = info;
}

- (void)showLog:(id)sender {
    (void)sender;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"Library/Logs/%@.log", kLogName]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:@""];
    } else {
        NSBeep();
    }
}

#pragma mark Transfer bar

- (void)showTransferBar:(BOOL)show {
    [self.hideBarTimer invalidate];
    self.hideBarTimer = nil;
    if (self.transferBar.hidden == !show) return;
    self.transferBar.hidden = !show;
    for (NSLayoutConstraint *c in self.transferBar.constraints) {
        if ([c.identifier isEqualToString:@"collapsed"]) c.active = !show;
    }
    for (NSLayoutConstraint *c in self.transferBar.superview.constraints) {
        if ([c.identifier isEqualToString:@"collapsed"]) c.active = !show;
    }
}

- (void)hideTransferBar:(id)sender {
    (void)sender;
    if (self.transferring || self.pullsActive) return;
    [self showTransferBar:NO];
}

- (void)scheduleHideTransferBar {
    [self.hideBarTimer invalidate];
    __weak AppController *weakSelf = self;
    self.hideBarTimer = [NSTimer scheduledTimerWithTimeInterval:10 repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf hideTransferBar:nil];
    }];
}

- (void)updateTransferControls {
    BOOL busy = self.transferring || self.pullsActive > 0;
    self.progress.hidden = !busy;
    self.cancelButton.hidden = !busy;
    self.closeBarButton.hidden = busy;
    if (busy) [self showTransferBar:YES];
}

- (void)setStatus:(NSString *)status detail:(NSString *)detail {
    [self showTransferBar:YES];
    [self updateTransferControls];
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

- (void)cancelTransfer:(id)sender {
    (void)sender;
    [self.pendingDrops removeAllObjects];
    if (self.transferring) {
        self.cancelRequested = YES;
        pid_t pid = self.activePid;
        if (pid > 0) kill(pid, SIGTERM);
    }
    if (self.pullsActive) {
        self.pullCancelRequested = YES;
        [self.pullQueue cancelAllOperations];
        pid_t pid = self.pullPid;
        if (pid > 0) kill(pid, SIGTERM);
    }
    self.cancelButton.enabled = NO;
    self.statusLabel.stringValue = @"Stopping…";
}

#pragma mark Pull (device → Mac)

- (unsigned long long)remoteSizeOf:(NSString *)path serial:(NSString *)serial {
    NSString *out = nil;
    if (![self runQuietShell:[NSString stringWithFormat:@"du -s -k %@", [self shellQuote:path]] serial:serial output:&out]) {
        return 0;
    }
    return strtoull(out.UTF8String, NULL, 10) * 1024ull;
}

// Runs on the pull queue. Returns nil on success or the error text.
- (NSString *)pullItem:(RemoteItem *)item toPath:(NSString *)local serial:(NSString *)serial {
    if (!serial.length) return @"No device";

    __block BOOL cancelled = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (!self.pullsActive) self.pullCancelRequested = NO;
        cancelled = self.pullCancelRequested;
        if (cancelled) return;
        self.pullsActive++;
        self.cancelButton.enabled = YES;
        self.transferIcon.image = ADBSymbol(@"arrow.down.circle", 15, NSFontWeightRegular);
        if (!self.transferring) {
            self.progress.indeterminate = YES;
            [self.progress startAnimation:nil];
            [self setStatus:[NSString stringWithFormat:@"Copying “%@” to the Mac…", item.name] detail:@""];
        }
    });
    if (cancelled) return @"Cancelled";

    unsigned long long total = item.directory ? [self remoteSizeOf:item.path serial:serial] : item.size;
    NSDate *start = [NSDate date];

    ADBFlag *running = [ADBFlag new];
    running.value = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (running.value) {
            usleep(400000);
            if (!running.value) break;
            unsigned long long done = ADBLocalSize(local);
            NSTimeInterval elapsed = -start.timeIntervalSinceNow;
            double rate = elapsed > 1 ? done / elapsed : 0;
            NSMutableString *detail = [NSMutableString stringWithString:ADBFormatBytes(done)];
            if (total) [detail appendFormat:@" of %@", ADBFormatBytes(total)];
            if (rate > 0) {
                [detail appendFormat:@"  ·  %@/s", ADBFormatBytes((unsigned long long)rate)];
                if (total > done) [detail appendFormat:@"  ·  %@ left", ADBFormatDuration((total - done) / rate)];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!running.value || self.transferring || self.pullCancelRequested) return;
                if (total) {
                    self.progress.indeterminate = NO;
                    self.progress.doubleValue = MIN((double)done / (double)total, 1.0);
                }
                self.detailLabel.stringValue = detail;
            });
        }
    });

    NSString *error = nil;
    NSString *output = nil;
    BOOL ok = [self runADB:@[@"-s", serial, @"pull", @"-a", item.path, local]
                     quiet:NO
                   started:^(pid_t pid) {
                       self.pullPid = pid;
                       if (self.pullCancelRequested) kill(pid, SIGTERM);
                   }
                    output:&output
                     error:&error];
    self.pullPid = 0;
    running.value = NO;

    BOOL wasCancelled = self.pullCancelRequested;
    if (!ok || wasCancelled) {
        [[NSFileManager defaultManager] removeItemAtPath:local error:nil];
    } else if (item.modified) {
        [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: item.modified}
                                         ofItemAtPath:local error:nil];
    }
    NSTimeInterval elapsed = -start.timeIntervalSinceNow;
    unsigned long long bytes = ok ? ADBLocalSize(local) : 0;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pullsActive) self.pullsActive--;
        if (self.pullsActive) return;
        [self.progress stopAnimation:nil];
        self.progress.indeterminate = NO;
        [self updateTransferControls];
        if (self.transferring) return;

        if (wasCancelled) {
            [self setStatus:@"Stopped" detail:@""];
        } else if (ok) {
            [self setStatus:[NSString stringWithFormat:@"Copied “%@” to the Mac", item.name]
                     detail:[NSString stringWithFormat:@"%@ in %@", ADBFormatBytes(bytes), ADBFormatDuration(elapsed)]];
        } else {
            [self setStatus:[NSString stringWithFormat:@"Couldn't copy “%@”", item.name] detail:@""];
            self.detailLabel.stringValue = error ?: @"";
            self.detailLabel.textColor = NSColor.systemRedColor;
            self.detailLabel.toolTip = error;
            return;
        }
        [self scheduleHideTransferBar];
    });

    if (wasCancelled) return @"Cancelled";
    if (!ok) return error.length ? error : @"adb pull failed";
    return nil;
}

#pragma mark Media scanner

// Without this, photos and music copied over ADB don't show up in Gallery or
// music apps until the next reboot. Deleted and moved files are rescanned too,
// so their stale entries disappear.
- (void)rescanMedia:(NSArray<NSString *> *)paths serial:(NSString *)serial {
    static NSSet *mediaExtensions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mediaExtensions = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"gif", @"webp", @"heic", @"heif", @"bmp",
                                                @"dng", @"mp4", @"m4v", @"mov", @"3gp", @"mkv", @"webm", @"avi",
                                                @"mp3", @"m4a", @"aac", @"flac", @"ogg", @"opus", @"wav", @"amr"]];
    });

    NSMutableArray<NSString *> *commands = [NSMutableArray array];
    for (NSString *path in paths) {
        if (commands.count >= 500) break;
        if (![mediaExtensions containsObject:path.pathExtension.lowercaseString]) continue;
        NSString *uri = [@"file://" stringByAppendingString:
                         [path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]];
        [commands addObject:[NSString stringWithFormat:
                             @"am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d %@ >/dev/null 2>&1",
                             [self shellQuote:uri]]];
    }
    if (!commands.count || !serial.length) return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableString *batch = [NSMutableString string];
        for (NSUInteger i = 0; i <= commands.count; i++) {
            NSString *next = i < commands.count ? commands[i] : nil;
            if (batch.length && (!next || batch.length + next.length + 2 > kMaxShellCommandBytes)) {
                [self runQuietShell:batch serial:serial output:NULL];
                [batch setString:@""];
            }
            if (next) [batch appendFormat:@"%@%@", batch.length ? @"; " : @"", next];
        }
    });
}

#pragma mark Push (Mac → device)

// Asks before overwriting anything that already exists in the target folder.
- (void)uploadURLs:(NSArray<NSURL *> *)urls toFolder:(NSString *)dest {
    if (!urls.count || !dest.length) return;
    if (!self.serial.length) {
        NSBeep();
        return;
    }

    BOOL allAPKs = YES;
    for (NSURL *url in urls) allAPKs &= [url.pathExtension.lowercaseString isEqualToString:@"apk"];
    if (allAPKs && !self.window.attachedSheet) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = urls.count == 1
            ? [NSString stringWithFormat:@"Install “%@” on the device?", urls.firstObject.lastPathComponent]
            : [NSString stringWithFormat:@"Install %lu apps on the device?", (unsigned long)urls.count];
        alert.informativeText = @"You can install the app, or just copy the APK file to this folder.";
        [alert addButtonWithTitle:@"Install"];
        [alert addButtonWithTitle:@"Copy File"];
        [alert addButtonWithTitle:@"Cancel"];
        [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
            if (response == NSAlertFirstButtonReturn) [self installAPKs:urls];
            if (response == NSAlertSecondButtonReturn) [self checkConflictsAndSend:urls toFolder:dest];
        }];
        return;
    }
    [self checkConflictsAndSend:urls toFolder:dest];
}

- (void)installAPKs:(NSArray<NSURL *> *)urls {
    NSString *serial = [self.serial copy];
    if (!serial.length) return;
    self.pullsActive++;
    self.cancelButton.enabled = NO;
    self.transferIcon.image = ADBSymbol(@"app.badge", 15, NSFontWeightRegular);
    self.progress.indeterminate = YES;
    [self.progress startAnimation:nil];
    [self setStatus:urls.count == 1 ? [NSString stringWithFormat:@"Installing “%@”…", urls.firstObject.lastPathComponent]
                                    : [NSString stringWithFormat:@"Installing %lu apps…", (unsigned long)urls.count]
             detail:@""];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *errors = [NSMutableArray array];
        for (NSURL *url in urls) {
            NSString *out = nil;
            NSString *err = nil;
            // -r reinstalls over an existing version and keeps its data.
            if (![self runADB:@[@"-s", serial, @"install", @"-r", url.path] output:&out error:&err] ||
                [out containsString:@"Failure"]) {
                [errors addObject:[NSString stringWithFormat:@"%@\n%@", url.lastPathComponent, err ?: out]];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.pullsActive) self.pullsActive--;
            [self.progress stopAnimation:nil];
            self.progress.indeterminate = NO;
            [self updateTransferControls];
            if (errors.count) {
                [self setStatus:@"Installation failed" detail:@""];
                [self showError:@"Couldn't install" message:[errors componentsJoinedByString:@"\n\n"]];
            } else {
                [self setStatus:urls.count == 1 ? @"App installed" : @"Apps installed" detail:@""];
                [self scheduleHideTransferBar];
            }
        });
    });
}

- (void)checkConflictsAndSend:(NSArray<NSURL *> *)urls toFolder:(NSString *)dest {
    NSMutableDictionary<NSString *, NSURL *> *byName = [NSMutableDictionary dictionary];
    for (NSURL *url in urls) byName[[self safeName:url.lastPathComponent]] = url;

    [self existingNames:byName.allKeys inFolder:dest completion:^(NSArray<NSString *> *existing) {
        if (!existing.count) {
            [self sendURLs:urls destination:dest];
            return;
        }
        [self confirmReplacing:existing inFolder:dest then:^(BOOL replace) {
            if (replace) {
                [self sendURLs:urls destination:dest];
                return;
            }
            NSMutableArray *rest = [NSMutableArray array];
            for (NSString *name in byName) if (![existing containsObject:name]) [rest addObject:byName[name]];
            [self sendURLs:rest destination:dest];
        }];
    }];
}

- (void)sendURLs:(NSArray<NSURL *> *)urls destination:(NSString *)dest {
    if (!urls.count) return;

    if (self.transferring) {
        // Picked up when the current transfer finishes.
        [self.pendingDrops addObject:@{@"urls": urls, @"dest": dest}];
        self.detailLabel.stringValue = [NSString stringWithFormat:@"%lu more queued", (unsigned long)self.pendingDrops.count];
        return;
    }

    if (!self.serial.length) {
        NSBeep();
        return;
    }

    [self beginTransferWithURLs:urls files:nil destination:dest];
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
    self.cancelButton.enabled = YES;

    if (active) {
        self.cancelRequested = NO;
        self.progress.indeterminate = NO;
        self.progress.doubleValue = 0;
        self.transferIcon.image = ADBSymbol(@"arrow.up.circle", 15, NSFontWeightRegular);
        self.activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated
                                                                     reason:@"Copying files to Android"];
    } else {
        if (self.activity) [NSProcessInfo.processInfo endActivity:self.activity];
        self.activity = nil;
        NSApp.dockTile.badgeLabel = nil;
        // Show what just arrived.
        [self reloadSelecting:nil];
    }
    [self updateTransferControls];
}

// Either `urls` (fresh drop, scanned in the background) or `files` (retry) is given.
- (void)beginTransferWithURLs:(NSArray<NSURL *> *)urls
                        files:(NSArray<NSDictionary *> *)retryFiles
                  destination:(NSString *)dest {
    [self setTransferUIActive:YES];
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

        NSString *rootRemote = ADBJoinPath(dest, [self safeName:url.lastPathComponent]);

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
        [self finishWithTitle:@"Nothing to copy" message:@"The dropped items contain no files." failures:nil destination:dest];
        return;
    }

    [self appendLog:[NSString stringWithFormat:@"UPLOAD START %lu file(s), %@ → %@",
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
    NSString *destName = dest.lastPathComponent.length ? dest.lastPathComponent : dest;

    void (^report)(NSString *, unsigned long long) = ^(NSString *name, unsigned long long partial) {
        unsigned long long sent = bytesDone + partial;
        NSUInteger index = MIN(done + failedCount + 1, total);
        NSTimeInterval elapsed = -start.timeIntervalSinceNow;
        double rate = elapsed > 1.0 ? sent / elapsed : 0;

        NSString *status = total == 1
            ? [NSString stringWithFormat:@"Copying “%@” to %@", name, destName]
            : [NSString stringWithFormat:@"Copying %lu of %lu to %@ · %@",
               (unsigned long)index, (unsigned long)total, destName, name];
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

    [self appendLog:[NSString stringWithFormat:@"UPLOAD END %lu sent, %lu failed%@, %.1fs",
                     (unsigned long)done, (unsigned long)failures.count,
                     self.cancelRequested ? @", cancelled" : @"", elapsed]];

    NSString *summary = [NSString stringWithFormat:@"%lu file(s) · %@ in %@",
                         (unsigned long)done, ADBFormatBytes(bytesDone), ADBFormatDuration(elapsed)];

    NSMutableArray *sentPaths = [NSMutableArray array];
    for (NSDictionary *r in results) if ([r[@"ok"] boolValue]) [sentPaths addObject:r[@"file"][@"remote"]];
    [self rescanMedia:sentPaths serial:serial];

    if (self.cancelRequested) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setTransferUIActive:NO];
            [self setStatus:@"Stopped" results:results summary:summary];
        });
        return;
    }

    if (!failures.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setTransferUIActive:NO];
            [self setStatus:[NSString stringWithFormat:@"Copied to %@", destName] results:results summary:summary];
            [self scheduleHideTransferBar];
            if (!NSApp.active) [NSApp requestUserAttention:NSInformationalRequest];
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
