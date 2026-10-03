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

static BOOL markRestoreSetupSkippable(void) {
    NSString *path = @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles/CloudConfigurationDetails.plist";
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *parent = [path stringByDeletingLastPathComponent];
    NSError *error = nil;
    if (![files createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSLog(@"vphone setup: cannot create %@: %@", parent, error);
        return NO;
    }

    NSMutableDictionary *configuration = [NSMutableDictionary dictionary];
    NSData *existing = [NSData dataWithContentsOfFile:path];
    if (existing) {
        id decoded = [NSPropertyListSerialization propertyListWithData:existing
            options:NSPropertyListMutableContainersAndLeaves format:NULL error:&error];
        if (![decoded isKindOfClass:[NSDictionary class]]) {
            NSLog(@"vphone setup: invalid plist at %@: %@", path, error);
            return NO;
        }
        [configuration addEntriesFromDictionary:decoded];
    }

    // Nugget's post-restore skip path includes both the restore-completed pane
    // and the normal setup panes. Preserve any existing skip list and MDM data.
    NSArray<NSString *> *skip = @[
        @"RestoreCompleted", @"UpdateCompleted", @"Restore", @"AppleID", @"TOS",
        @"Location", @"Siri", @"ScreenTime", @"Diagnostics", @"Passcode",
        @"Biometric", @"Payment", @"Appearance", @"Privacy", @"SoftwareUpdate"
    ];
    NSMutableOrderedSet<NSString *> *merged = [NSMutableOrderedSet orderedSet];
    if ([configuration[@"SkipSetup"] isKindOfClass:[NSArray class]])
        [merged addObjectsFromArray:configuration[@"SkipSetup"]];
    [merged addObjectsFromArray:skip];
    configuration[@"SkipSetup"] = merged.array;
    configuration[@"ConfigurationWasApplied"] = @YES;
    configuration[@"CloudConfigurationUIComplete"] = @YES;
    configuration[@"PostSetupProfileWasInstalled"] = @YES;

    NSData *updated = [NSPropertyListSerialization dataWithPropertyList:configuration
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    if (!updated || ![updated writeToFile:path options:NSDataWritingAtomic error:&error]) {
        NSLog(@"vphone setup: cannot write %@: %@", path, error);
        return NO;
    }
    if (chown(path.fileSystemRepresentation, 0, 0) != 0 ||
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
        BOOL cloud = markRestoreSetupSkippable();
        if (user && managed && cloud) {
            // Update the live preferences cache as well as the on-disk files.
            CFStringRef domain = CFSTR("com.apple.purplebuddy");
            CFStringRef mobile = CFSTR("mobile");
            CFPreferencesSetValue(CFSTR("SetupDone"), kCFBooleanTrue, domain, mobile, kCFPreferencesAnyHost);
            CFPreferencesSetValue(CFSTR("SetupFinishedAllSteps"), kCFBooleanTrue, domain, mobile, kCFPreferencesAnyHost);
            CFPreferencesSetValue(CFSTR("UserChoseLanguage"), kCFBooleanTrue, domain, mobile, kCFPreferencesAnyHost);
            CFPreferencesSynchronize(domain, mobile, kCFPreferencesAnyHost);
            NSString *marker = @"/var/mobile/.vphone_setup_complete";
            NSError *markerError = nil;
            if (![@"PurpleBuddy and restore setup flags staged\n" writeToFile:marker
                    atomically:YES encoding:NSUTF8StringEncoding error:&markerError]) {
                NSLog(@"vphone setup: cannot write marker: %@", markerError);
                return 1;
            }
            chown(marker.fileSystemRepresentation, 501, 501);
            NSLog(@"vphone setup: PurpleBuddy and post-restore setup flags set; reboot to reload setup state");
            return 0;
        }
        return 1;
    }
}
