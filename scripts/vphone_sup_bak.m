// Installs or removes the staged ConfigurationProfiles backup after Data mounts.
#import <Foundation/Foundation.h>
#include <sys/stat.h>

static NSString * const stage = @"/cores/vphone_sup_bak_data";
static NSString * const target = @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles";
static NSString * const modePath = @"/cores/vphone_sup_bak_mode";

static BOOL copyTree(NSString *source, NSString *destination) {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:source isDirectory:&isDir]) return NO;
    NSError *error = nil;
    if (isDir) {
        if (![fm createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:&error]) return NO;
        NSArray *names = [fm contentsOfDirectoryAtPath:source error:&error];
        if (!names) return NO;
        for (NSString *name in names)
            if (!copyTree([source stringByAppendingPathComponent:name], [destination stringByAppendingPathComponent:name])) return NO;
        chown(destination.fileSystemRepresentation, 0, 0);
        chmod(destination.fileSystemRepresentation, 0755);
        return YES;
    }
    NSDictionary *attrs = [fm attributesOfItemAtPath:source error:&error];
    if (!attrs || attrs[NSFileType] != NSFileTypeRegular) return NO;
    NSString *parent = [destination stringByDeletingLastPathComponent];
    if (![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:&error]) return NO;
    if ([fm fileExistsAtPath:destination] && ![fm removeItemAtPath:destination error:&error]) return NO;
    if (![fm copyItemAtPath:source toPath:destination error:&error]) return NO;
    chown(destination.fileSystemRepresentation, 0, 0);
    chmod(destination.fileSystemRepresentation, 0644);
    return YES;
}

static BOOL removeTree(NSString *path) {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) return YES;
    if (isDir) {
        NSError *error = nil;
        NSArray *names = [fm contentsOfDirectoryAtPath:path error:&error];
        if (!names) return NO;
        for (NSString *name in names)
            if (!removeTree([path stringByAppendingPathComponent:name])) return NO;
        NSArray *remaining = [fm contentsOfDirectoryAtPath:path error:&error];
        if (!remaining) return NO;
        // Remove directories created by the backup only when empty.
        return remaining.count == 0 ? [fm removeItemAtPath:path error:&error] : YES;
    }
    NSError *error = nil;
    return [fm removeItemAtPath:path error:&error];
}

int main(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        if (![fm fileExistsAtPath:@"/var/containers/Shared/SystemGroup"]) return 1;
        NSString *mode = [NSString stringWithContentsOfFile:modePath encoding:NSUTF8StringEncoding error:nil];
        NSError *error = nil;
        BOOL ok = NO;
        if ([mode isEqualToString:@"remove\n"] || [mode isEqualToString:@"remove"]) {
            NSArray *names = [fm contentsOfDirectoryAtPath:stage error:&error];
            if (!names) return 1;
            ok = YES;
            for (NSString *name in names)
                if (!removeTree([target stringByAppendingPathComponent:name])) { ok = NO; break; }
        } else {
            ok = copyTree(stage, target);
        }
        if (!ok) { NSLog(@"vphone sup_bak: operation failed: %@", error); return 1; }
        NSLog(@"vphone sup_bak: %@ completed", mode ?: @"install");
        return 0;
    }
}
