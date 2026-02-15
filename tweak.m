/*
 * FileRedirectDylib - tweak.m
 *
 * Hooks file-access functions so that when the game reads from its .app bundle,
 * it checks the Documents folder first. If a replacement file exists there, the
 * hooked function transparently returns that path instead.
 *
 * Works on non-jailbroken iOS (sideloaded IPAs) using Facebook's fishhook
 * for C-level hooks and ObjC method swizzling for NSBundle/NSFileManager.
 *
 * Usage:
 *   1. Build as a dylib for iOS arm64.
 *   2. Inject into the target IPA (insert_dylib / optool).
 *   3. Place your modded game files in Documents/, mirroring the .app structure.
 *      For Bully:  Documents/BullyOrig/Scripts/scripts.img + scripts.dir
 *      For GTA SA: Documents/texdb/gta3.txd  (or whatever path the file has in .app)
 *
 *   Bully-specific: The .app has BullyOrig as a zip file. This dylib makes
 *   the game see your Documents/BullyOrig/ folder instead of that zip, so
 *   the engine loads your modded scripts.img/scripts.dir from there.
 *   4. The game will transparently load your files instead of the originals.
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>
#include <dlfcn.h>
#include "fishhook.h"

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------

static NSString *g_bundlePath    = nil; // e.g. /var/containers/…/MyApp.app
static NSString *g_documentsPath = nil; // e.g. /var/containers/…/Documents

// Set to 1 to log every redirected access (useful for debugging).
// In production you probably want this off (0).
#define REDIRECT_LOG_ENABLED 1

static void redirect_log(const char *func, const char *original, const char *redirected) {
#if REDIRECT_LOG_ENABLED
    NSLog(@"[FileRedirect] %s: %s -> %s", func, original, redirected);
#endif
}

// ---------------------------------------------------------------------------
// Helper: given an absolute path that lives inside the .app bundle, return
// the equivalent path under Documents/disk/ — or NULL if the replacement
// file does not exist.
// ---------------------------------------------------------------------------

static const char *redirected_path_if_exists(const char *path) {
    if (!path || !g_bundlePath || !g_documentsPath) return NULL;

    NSString *nsPath = [NSString stringWithUTF8String:path];
    if (![nsPath hasPrefix:g_bundlePath]) return NULL;

    // Strip the bundle prefix and prepend the Documents path
    NSString *relative = [nsPath substringFromIndex:[g_bundlePath length]];
    NSString *candidate = [g_documentsPath stringByAppendingString:relative];

    // Check existence
    if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
        return [candidate UTF8String];
    }
    return NULL;
}

// Same helper but returns an NSString (for ObjC hooks)
static NSString *redirected_nspath_if_exists(NSString *path) {
    if (!path || !g_bundlePath || !g_documentsPath) return nil;
    if (![path hasPrefix:g_bundlePath]) return nil;

    NSString *relative = [path substringFromIndex:[g_bundlePath length]];
    NSString *candidate = [g_documentsPath stringByAppendingString:relative];

    if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
        return candidate;
    }
    return nil;
}

// ---------------------------------------------------------------------------
// C-level hooks (via fishhook)
// ---------------------------------------------------------------------------

// ---- fopen ----
static FILE *(*orig_fopen)(const char *, const char *);
static FILE *hook_fopen(const char *path, const char *mode) {
    const char *redir = redirected_path_if_exists(path);
    if (redir) {
        redirect_log("fopen", path, redir);
        return orig_fopen(redir, mode);
    }
    return orig_fopen(path, mode);
}

// ---- open ----
static int (*orig_open)(const char *, int, ...);
static int hook_open(const char *path, int flags, ...) {
    const char *redir = redirected_path_if_exists(path);
    const char *use_path = redir ? redir : path;
    if (redir) redirect_log("open", path, redir);

    // Handle optional mode_t argument (used with O_CREAT)
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode_t mode = (mode_t)va_arg(ap, int);
        va_end(ap);
        return orig_open(use_path, flags, mode);
    }
    return orig_open(use_path, flags);
}

// ---- stat ----
static int (*orig_stat)(const char *, struct stat *);
static int hook_stat(const char *path, struct stat *buf) {
    const char *redir = redirected_path_if_exists(path);
    if (redir) {
        redirect_log("stat", path, redir);
        return orig_stat(redir, buf);
    }
    return orig_stat(path, buf);
}

// ---- access ----
static int (*orig_access)(const char *, int);
static int hook_access(const char *path, int amode) {
    const char *redir = redirected_path_if_exists(path);
    if (redir) {
        redirect_log("access", path, redir);
        return orig_access(redir, amode);
    }
    return orig_access(path, amode);
}

// ---- lstat (some engines use lstat instead of stat) ----
static int (*orig_lstat)(const char *, struct stat *);
static int hook_lstat(const char *path, struct stat *buf) {
    const char *redir = redirected_path_if_exists(path);
    if (redir) {
        redirect_log("lstat", path, redir);
        return orig_lstat(redir, buf);
    }
    return orig_lstat(path, buf);
}

// ---- opendir (critical for Bully: makes BullyOrig look like a folder) ----
static DIR *(*orig_opendir)(const char *);
static DIR *hook_opendir(const char *path) {
    const char *redir = redirected_path_if_exists(path);
    if (redir) {
        redirect_log("opendir", path, redir);
        return orig_opendir(redir);
    }
    return orig_opendir(path);
}

// ---------------------------------------------------------------------------
// ObjC swizzling helpers
// ---------------------------------------------------------------------------

static void swizzle_instance_method(Class cls, SEL orig, SEL replacement) {
    Method origMethod = class_getInstanceMethod(cls, orig);
    Method replMethod = class_getInstanceMethod(cls, replacement);
    if (class_addMethod(cls, orig,
                        method_getImplementation(replMethod),
                        method_getTypeEncoding(replMethod))) {
        class_replaceMethod(cls, replacement,
                            method_getImplementation(origMethod),
                            method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, replMethod);
    }
}

// ---------------------------------------------------------------------------
// NSBundle swizzle: -pathForResource:ofType:
// ---------------------------------------------------------------------------

@interface NSBundle (FileRedirect)
- (NSString *)fr_pathForResource:(NSString *)name ofType:(NSString *)ext;
@end

@implementation NSBundle (FileRedirect)
- (NSString *)fr_pathForResource:(NSString *)name ofType:(NSString *)ext {
    // Call original
    NSString *original = [self fr_pathForResource:name ofType:ext];
    if (!original) return nil;

    NSString *redir = redirected_nspath_if_exists(original);
    if (redir) {
        NSLog(@"[FileRedirect] NSBundle pathForResource: %@ -> %@", original, redir);
        return redir;
    }
    return original;
}
@end

// ---------------------------------------------------------------------------
// NSBundle swizzle: -pathForResource:ofType:inDirectory:
// ---------------------------------------------------------------------------

@interface NSBundle (FileRedirect2)
- (NSString *)fr_pathForResource:(NSString *)name ofType:(NSString *)ext inDirectory:(NSString *)subpath;
@end

@implementation NSBundle (FileRedirect2)
- (NSString *)fr_pathForResource:(NSString *)name ofType:(NSString *)ext inDirectory:(NSString *)subpath {
    NSString *original = [self fr_pathForResource:name ofType:ext inDirectory:subpath];
    if (!original) return nil;

    NSString *redir = redirected_nspath_if_exists(original);
    if (redir) {
        NSLog(@"[FileRedirect] NSBundle pathForResource:ofType:inDirectory: %@ -> %@", original, redir);
        return redir;
    }
    return original;
}
@end

// ---------------------------------------------------------------------------
// NSFileManager swizzle: -contentsAtPath:
// ---------------------------------------------------------------------------

@interface NSFileManager (FileRedirect)
- (NSData *)fr_contentsAtPath:(NSString *)path;
@end

@implementation NSFileManager (FileRedirect)
- (NSData *)fr_contentsAtPath:(NSString *)path {
    NSString *redir = redirected_nspath_if_exists(path);
    if (redir) {
        NSLog(@"[FileRedirect] NSFileManager contentsAtPath: %@ -> %@", path, redir);
        return [self fr_contentsAtPath:redir];
    }
    return [self fr_contentsAtPath:path];
}
@end

// ---------------------------------------------------------------------------
// Constructor — runs automatically when the dylib is loaded
// ---------------------------------------------------------------------------

__attribute__((constructor))
static void file_redirect_init(void) {
    @autoreleasepool {
        // Resolve paths
        g_bundlePath    = [[NSBundle mainBundle] bundlePath];
        NSArray *docPaths = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
        g_documentsPath = [docPaths firstObject];

        NSLog(@"[FileRedirect] === Initializing ===");
        NSLog(@"[FileRedirect] Bundle path:    %@", g_bundlePath);
        NSLog(@"[FileRedirect] Documents path: %@", g_documentsPath);

        // Auto-create BullyOrig/Scripts/ in Documents for convenience
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *bullyScripts = [g_documentsPath stringByAppendingPathComponent:@"BullyOrig/Scripts"];
        if (![fm fileExistsAtPath:bullyScripts]) {
            NSError *err = nil;
            [fm createDirectoryAtPath:bullyScripts
          withIntermediateDirectories:YES
                           attributes:nil
                                error:&err];
            if (err) {
                NSLog(@"[FileRedirect] Failed to create BullyOrig/Scripts: %@", err);
            } else {
                NSLog(@"[FileRedirect] Created Documents/BullyOrig/Scripts/");
            }
        }

        // ---- C-level hooks via fishhook ----
        struct rebinding rebindings[] = {
            {"fopen",   (void *)hook_fopen,   (void **)&orig_fopen},
            {"open",    (void *)hook_open,    (void **)&orig_open},
            {"stat",    (void *)hook_stat,    (void **)&orig_stat},
            {"lstat",   (void *)hook_lstat,   (void **)&orig_lstat},
            {"access",  (void *)hook_access,  (void **)&orig_access},
            {"opendir", (void *)hook_opendir, (void **)&orig_opendir},
        };
        rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
        NSLog(@"[FileRedirect] C hooks installed (fopen, open, stat, lstat, access, opendir)");

        // ---- ObjC swizzles ----
        swizzle_instance_method(
            [NSBundle class],
            @selector(pathForResource:ofType:),
            @selector(fr_pathForResource:ofType:));

        swizzle_instance_method(
            [NSBundle class],
            @selector(pathForResource:ofType:inDirectory:),
            @selector(fr_pathForResource:ofType:inDirectory:));

        swizzle_instance_method(
            [NSFileManager class],
            @selector(contentsAtPath:),
            @selector(fr_contentsAtPath:));

        NSLog(@"[FileRedirect] ObjC swizzles installed (NSBundle, NSFileManager)");
        NSLog(@"[FileRedirect] === Ready! Place mod files in Documents/ (e.g. Documents/BullyOrig/Scripts/) ===");
    }
}
