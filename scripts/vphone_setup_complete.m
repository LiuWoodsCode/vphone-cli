// Applied by strip_setup on the first guest boot, after the encrypted Data
// volume is available. Preserve any existing PurpleBuddy preferences.
#import <Foundation/Foundation.h>
#include <sys/stat.h>

static BOOL markSetupComplete(NSString *path) {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *parent = [path stringByDeletingLastPathComponent];
    NSError *error = nil;
    if (![files createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSLog(@"vphone setup: cannot create %@: %@", parent, error);
        return NO;
    }

    NSMutableDictionary *preferences = [NSMutableDictionary dictionary];
    NSData *existing = [NSData dataWithContentsOfFile:path];
    if (existing) {
        id decoded = [NSPropertyListSerialization propertyListWithData:existing
            options:NSPropertyListMutableContainersAndLeaves format:NULL error:&error];
        if (![decoded isKindOfClass:[NSDictionary class]]) {
            NSLog(@"vphone setup: invalid plist at %@: %@", path, error);
            return NO;
        }
        [preferences addEntriesFromDictionary:decoded];
    }

    preferences[@"SetupDone"] = @YES;
    preferences[@"SetupFinishedAllSteps"] = @YES;
    preferences[@"UserChoseLanguage"] = @YES;
    NSData *updated = [NSPropertyListSerialization dataWithPropertyList:preferences
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    if (!updated || ![updated writeToFile:path options:NSDataWritingAtomic error:&error]) {
        NSLog(@"vphone setup: cannot write %@: %@", path, error);
        return NO;
    }
    if (chown(path.fileSystemRepresentation, 501, 501) != 0 ||
        chmod(path.fileSystemRepresentation, 0644) != 0) {
        NSLog(@"vphone setup: cannot set ownership on %@", path);
        return NO;
    }
    return YES;
}

int main(void) {
    @autoreleasepool {
        // Data is encrypted offline and may not be mounted when launchd starts.
        if (![[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Library/Preferences"])
            return 1;

        BOOL user = markSetupComplete(@"/var/mobile/Library/Preferences/com.apple.purplebuddy.plist");
        BOOL managed = markSetupComplete(@"/var/Managed Preferences/mobile/com.apple.purplebuddy.plist");
        if (user && managed) {
            // Update the live preferences cache as well as the on-disk files.
            CFStringRef domain = CFSTR("com.apple.purplebuddy");
            CFStringRef mobile = CFSTR("mobile");
            CFPreferencesSetValue(CFSTR("SetupDone"), kCFBooleanTrue, domain, mobile, kCFPreferencesAnyHost);
            CFPreferencesSetValue(CFSTR("SetupFinishedAllSteps"), kCFBooleanTrue, domain, mobile, kCFPreferencesAnyHost);
            CFPreferencesSetValue(CFSTR("UserChoseLanguage"), kCFBooleanTrue, domain, mobile, kCFPreferencesAnyHost);
            CFPreferencesSynchronize(domain, mobile, kCFPreferencesAnyHost);
            NSLog(@"vphone setup: PurpleBuddy completion flags set");
            return 0;
        }
        return 1;
    }
}
