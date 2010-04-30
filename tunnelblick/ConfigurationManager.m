/*
 * Copyright 2010 Jonathan K. Bullard. All rights reserved.
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License version 2
 *  as published by the Free Software Foundation.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program (see the file COPYING included with this
 *  distribution); if not, write to the Free Software Foundation, Inc.,
 *  59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#import "ConfigurationManager.h"
#import <Security/Security.h>
#import <Security/AuthSession.h>
#import <Security/AuthorizationTags.h>
#import <sys/param.h>
#import <sys/mount.h>
#import "helper.h"
#import "MenuController.h"
#import "NSApplication+LoginItem.h"
#import "TBUserDefaults.h"

extern NSMutableArray       * gConfigDirs;
extern NSString             * gDeployPath;
extern NSString             * gSharedPath;
extern NSString             * gPrivatePath;
extern NSFileManager        * gFileMgr;
extern TBUserDefaults       * gTbDefaults;
extern SecuritySessionId      gSecuritySessionId;

extern NSString * firstPartOfPath(NSString * thePath);
extern NSString * lastPartOfPath(NSString * thePath);
extern BOOL       folderContentsNeedToBeSecuredAtPath(NSString * theDirPath);

@interface ConfigurationManager() // PRIVATE METHODS

-(BOOL)         addConfigsFromPath:         (NSString *)                folderPath
                   thatArePackages:         (BOOL)                      onlyPkgs
                            toDict:         (NSMutableDictionary * )    dict
                      searchDeeply:         (BOOL)                      deep;

-(BOOL)         checkPermissions:           (NSString *)                permsShouldHave
                         forPath:           (NSString *)                path;

-(BOOL)         configNotProtected:         (NSString *)                configFile;

-(BOOL)         copyConfigPath:             (NSString *)                sourcePath
                        toPath:             (NSString *)                targetPath
                  usingAuthRef:             (AuthorizationRef)          authRef
                    warnDialog:             (BOOL)                      warn
                   moveNotCopy:             (BOOL)                      moveInstead;

-(BOOL)         createDir:                  (NSString *)                thePath;

-(NSString *)   displayNameForPath:         (NSString *)                thePath;

-(NSString *)   getLowerCaseStringForKey:   (NSString *)                key
                            inDictionary:   (NSDictionary *)            dict
                               defaultTo:   (id)                        replacement;

-(NSString *)   getPackageToInstall:        (NSString *)                thePath
                            withKey:        (NSString *)                key;

-(BOOL)         isSampleConfigurationAtPath:(NSString *)                cfgPath;

-(NSString *)   makeEmptyTblk:              (NSString *)                thePath
                      withKey:              (NSString *)                key;

-(BOOL)         makeSureFolderExistsAtPath: (NSString *)                folderPath
                                 usingAuth: (AuthorizationRef)          authRef;

-(BOOL)         onRemoteVolume:             (NSString *)                cfgPath;

-(NSArray *)    checkOneDotTblkPackage:     (NSString *)                filePath
                              withKey:      (NSString *)                key;

-(BOOL)         protectConfigurationFile:   (NSString *)                configFilePath
                               usingAuth:   (AuthorizationRef)          authRef;

@end

@implementation ConfigurationManager

+(id)   defaultManager
{
    return [[[ConfigurationManager alloc] init] autorelease];
}

// Returns a dictionary with information about the configuration files in gConfigDirs.
// The key for each entry is the display name for the configuration; the object is the path to the configuration file
// (which may be a .tblk package or a .ovpn or .conf file) for the configuration
//
// Only searches folders that are in gConfigDirs.
//
// First, it goes through gDeploy looking for packages,
//           then through gDeploy looking for configs NOT in packages,
//           then through gSharedPath looking for packages (does not look for configs that are not in packages in gSharedPath)
//           then through gPrivatePath looking for packages,
//           then through gPrivatePath looking for configs NOT in packages
-(NSMutableDictionary *) getConfigurations
{
    NSMutableDictionary * dict = [[[NSMutableDictionary alloc] init] autorelease];
    BOOL noneIgnored = TRUE;
    
    noneIgnored = [self addConfigsFromPath: gDeployPath  thatArePackages: YES toDict: dict searchDeeply: NO ] && noneIgnored;
    noneIgnored = [self addConfigsFromPath: gDeployPath  thatArePackages: NO  toDict: dict searchDeeply: NO ] && noneIgnored;
    noneIgnored = [self addConfigsFromPath: gSharedPath  thatArePackages: YES toDict: dict searchDeeply: NO ] && noneIgnored;
    noneIgnored = [self addConfigsFromPath: gPrivatePath thatArePackages: YES toDict: dict searchDeeply: NO ] && noneIgnored;
    noneIgnored = [self addConfigsFromPath: gPrivatePath thatArePackages: NO  toDict: dict searchDeeply: YES] && noneIgnored;
    
    if (  ! noneIgnored  ) {
        TBRunAlertPanelExtended(NSLocalizedString(@"Configuration(s) Ignored", @"Window title"),
                                NSLocalizedString(@"One or more configurations are being ignored. See the Console Log for details.", @"Window text"),
                                nil, nil, nil,
                                @"skipWarningAboutIgnoredConfigurations",          // Preference about seeing this message again
                                NSLocalizedString(@"Do not warn about this again", @"Checkbox text"),
                                nil);
    }
    return dict;
}

// Adds configurations to a dictionary based on input parameters
// Returns TRUE if succeeded, FALSE if one or more configurations were ignored.
//
// If searching gSharedPath, looks for .ovpn and .conf and ignores them even if searching for packages (so we can complain to the user)
-(BOOL)  addConfigsFromPath: (NSString *)               folderPath
            thatArePackages: (BOOL)                     onlyPkgs
                     toDict: (NSMutableDictionary *)    dict
               searchDeeply: (BOOL)                     deep
{
    if (  ! [gConfigDirs containsObject: folderPath]  ) {
        return TRUE;
    }
    
    BOOL ignored = FALSE;
    NSString * file;
    
    if (  deep  ) {
        // Search directory and subdirectories
        NSDirectoryEnumerator * dirEnum = [gFileMgr enumeratorAtPath: folderPath];
        while (file = [dirEnum nextObject]) {
            BOOL addIt = FALSE;
            NSString * fullPath = [folderPath stringByAppendingPathComponent: file];
            NSString * dispName = [lastPartOfPath(fullPath) stringByDeletingPathExtension];
            if (  itemIsVisible(fullPath)  ) {
                NSString * ext = [file pathExtension];
                if (  onlyPkgs  ) {
                    if (  [ext isEqualToString: @"tblk"]  ) {
                        NSString * tbPath = tblkPathFromConfigPath(fullPath);
                        if (  ! tbPath  ) {
                            NSLog(@"Tunnelblick VPN Configuration ignored: No .conf or .ovpn file in %@", fullPath);
                             ignored = TRUE;
                        } else {
                            addIt = TRUE;
                        }
                    }
                } else {
                    if (  [fullPath rangeOfString: @".tblk/"].length == 0  ) {  // Ignore .ovpn and .conf in a .tblk
                        if (  [ext isEqualToString: @"ovpn"] || [ext isEqualToString: @"ovpn"]  ) {
                            addIt = TRUE;
                        }
                    }
                }
            }
            
            if (  addIt  ) {
                if (  [dict objectForKey: dispName]  ) {
                    NSLog(@"Tunnelblick Configuration ignored: The name is already being used: %@", fullPath);
                     ignored = TRUE;
                } else {
                    [dict setObject: fullPath forKey: dispName];
                }
            }
        }
    } else {
        // Search directory only, not subdirectories.
        NSArray * dirContents = [gFileMgr directoryContentsAtPath: folderPath];
        int i;
        for (i=0; i < [dirContents count]; i++) {
            file = [dirContents objectAtIndex: i];
            BOOL addIt = FALSE;
            NSString * fullPath = [folderPath stringByAppendingPathComponent: file];
            NSString * dispName = [file stringByDeletingPathExtension];
            if (  itemIsVisible(fullPath)  ) {
                NSString * ext = [file pathExtension];
                if (  onlyPkgs  ) {
                    if (  [ext isEqualToString: @"tblk"]  ) {
                        NSString * tbPath = configPathFromTblkPath(fullPath);
                        if (  ! tbPath  ) {
                            NSLog(@"Tunnelblick VPN Configuration ignored: No .conf or .ovpn file in %@", fullPath);
                             ignored = TRUE;
                        } else {
                            addIt = TRUE;
                        }
                    }
                } else {
                    if (  [ext isEqualToString: @"ovpn"] || [ext isEqualToString: @"ovpn"]  ) {
                        addIt = TRUE;
                    }
                }
                if (   [folderPath isEqualToString: gSharedPath]
                    && ([ext isEqualToString: @"ovpn"] || [ext isEqualToString: @"ovpn"])  ) {
                    NSLog(@"Tunnelblick VPN Configuration ignored: Only Tunnelblick VPN Configurations (.tblk packages) may be shared %@", fullPath);
                     ignored = TRUE;
                }
            }
            
            if (  addIt  ) {
                if (  [dict objectForKey: dispName]  ) {
                    NSLog(@"Tunnelblick Configuration ignored: The name is already being used: %@", fullPath);
                     ignored = TRUE;
                } else {
                    [dict setObject: fullPath forKey: dispName];
                }
            }
        }
    }
    
    return  ! ignored;
}            

-(BOOL) userCanEditConfiguration: (NSString *) filePath
{
    NSString * realPath = filePath;
    if (  [[filePath pathExtension] isEqualToString: @"tblk"]  ) {
        realPath = [filePath stringByAppendingPathComponent: @"Contents/Resources/config.ovpn"];
    }
    
    // Must be able to write to parent directory of the file
    if (  ! [gFileMgr isWritableFileAtPath: [realPath stringByDeletingLastPathComponent]]  ) {
        return NO;
    }
    
    // If it doesn't exist, user can create it
    if (  ! [gFileMgr fileExistsAtPath: realPath]  ) {
        return YES;
    }
    
    // If it is writable, user can edit it
    if (  ! [gFileMgr isWritableFileAtPath: realPath]  ) {
        return YES;
    }
    
    // Otherwise must be admin or we must allow non-admins to edit configurations
    return (   [[NSApp delegate] userIsAnAdmin]
            || ( ! [gTbDefaults boolForKey: @"onlyAdminsCanUnprotectConfigurationFiles"] )   );
}

-(void) editConfigurationAtPath: (NSString *) thePath
{
    NSString * targetPath = [[thePath copy] autorelease];
    if ( ! targetPath  ) {
        targetPath = [gPrivatePath stringByAppendingPathComponent: @"openvpn.conf"];
    }
    
    if (  [[targetPath pathExtension] isEqualToString: @"tblk"]  ) {
        NSString * targetConfig;
        targetConfig = configPathFromTblkPath(targetPath);
        if (  ! targetConfig  ) {
            NSLog(@"No configuration file in %@", targetPath);
            return;
        }
        targetPath = targetConfig;
    }
    
    // To allow users to edit and save a configuration file, we allow the user to unprotect the file before editing. 
    // This is because TextEdit cannot save a file if it is protected (owned by root with 644 permissions).
    // But we only do this if the user can write to the file's parent directory, since TextEdit does that to save
    if (  [gFileMgr fileExistsAtPath: targetPath]  ) {
        BOOL userCanEdit = [self userCanEditConfiguration: thePath];
        BOOL isWritable = [gFileMgr isWritableFileAtPath: targetPath];
        if (  userCanEdit && (! isWritable)  ) {
            // Ask if user wants to unprotect the configuration file
            int button = TBRunAlertPanelExtended(NSLocalizedString(@"The configuration file is protected", @"Window title"),
                                                 NSLocalizedString(@"You may examine the configuration file, but if you plan to modify it, you must unprotect it now. If you unprotect the configuration file now, you will need to provide an administrator username and password the next time you connect using it.", @"Window text"),
                                                 NSLocalizedString(@"Examine", @"Button"),                  // Default button
                                                 NSLocalizedString(@"Unprotect and Modify", @"Button"),     // Alternate button
                                                 NSLocalizedString(@"Cancel", @"Button"),                   // Other button
                                                 @"skipWarningAboutConfigFileProtectedAndAlwaysExamineIt",  // Preference about seeing this message again
                                                 NSLocalizedString(@"Do not warn about this again, always 'Examine'", @"Checkbox text"),
                                                 nil);
            if (  button == NSAlertOtherReturn  ) {
                return;
            }
            if (  button == NSAlertAlternateReturn  ) {
                if (  ! [[ConfigurationManager defaultManager] unprotectConfigurationFile: targetPath]  ) {
                    int button = TBRunAlertPanel(NSLocalizedString(@"Examine the configuration file?", @"Window title"),
                                                 NSLocalizedString(@"Tunnelblick could not unprotect the configuration file. Details are in the Console Log.\n\nDo you wish to examine the configuration file even though you will not be able to modify it?", @"Window text"),
                                                 NSLocalizedString(@"Cancel", @"Button"),    // Default button
                                                 NSLocalizedString(@"Examine", @"Button"),   // Alternate button
                                                 nil);
                    if (  button != NSAlertAlternateReturn  ) {
                        return;
                    }
                }
            }
        }
    }
    
    [[NSWorkspace sharedWorkspace] openFile: targetPath withApplication: @"TextEdit"];
}

// Make a private configuration shared, or a shared configuration private
-(void) shareOrPrivatizeAtPath: (NSString *) path
{
    if (  [[path pathExtension] isEqualToString: @"tblk"]  ) {
        NSString * last = lastPartOfPath(path);
        NSString * name = [last stringByDeletingPathExtension];
        if (  [path hasPrefix: gSharedPath]  ) {
            NSString * lastButOvpn = [name stringByAppendingPathExtension: @"ovpn"];
            NSString * lastButConf = [name stringByAppendingPathExtension: @"conf"];
            if (   [gFileMgr fileExistsAtPath: [gPrivatePath stringByAppendingPathComponent: last]]
                || [gFileMgr fileExistsAtPath: [gPrivatePath stringByAppendingPathComponent: lastButOvpn]]
                || [gFileMgr fileExistsAtPath: [gPrivatePath stringByAppendingPathComponent: lastButConf]]  ) {
                int result = TBRunAlertPanel(NSLocalizedString(@"Replace Existing Configuration?", @"Window title"),
                                             [NSString stringWithFormat: NSLocalizedString(@"A private configuration named '%@' already exists.\n\nDo you wish to replace it with the shared configuration?", @"Window text"), name],
                                             NSLocalizedString(@"Replace", @"Button"),
                                             NSLocalizedString(@"Cancel" , @"Button"),
                                             nil);
                if (  result == NSAlertAlternateReturn  ) {
                    return;
                }
            }
            
            NSString * source = [[path copy] autorelease];
            NSString * target = [gPrivatePath stringByAppendingPathComponent: last];
            NSString * msg = [NSString stringWithFormat: NSLocalizedString(@"You have asked to make the '%@' configuration private, instead of shared.", @"Window text"), name];
            AuthorizationRef authRef = [NSApplication getAuthorizationRef: msg];
            if ( authRef == nil ) {
                NSLog(@"Make private authorization cancelled by user");
                return;
            }
            [self copyConfigPath: source
                          toPath: target
                    usingAuthRef: authRef
                      warnDialog: YES
                     moveNotCopy: YES];
        } else if (  [path hasPrefix: gPrivatePath]  ) {
            NSString * source = [[path copy] autorelease];
            NSString * target = [gSharedPath stringByAppendingPathComponent: last];
            NSString * msg = [NSString stringWithFormat: NSLocalizedString(@"You have asked to make the '%@' configuration shared, instead of private.", @"Window text"), name];
            AuthorizationRef authRef = [NSApplication getAuthorizationRef: msg];
            if ( authRef == nil ) {
                NSLog(@"Make shared authorization cancelled by user");
                return;
            }
            [self copyConfigPath: source
                          toPath: target
                    usingAuthRef: authRef
                      warnDialog: YES
                     moveNotCopy: YES];
        }
    }
}

// Unprotect a configuration file without using authorization by replacing the root-owned
// file with a user-owned writable copy so it can be edited (keep root-owned file as a backup)
// Sets ownership/permissions on the copy to the current user:group/0666 without using authorization
// Invoke with path to .ovpn or .conf file or .tblk package
// Returns TRUE if succeeded
// Returns FALSE if can't find config in .tblk or couldn't change owner/permissions or user doesn't have write access to the parent folder
-(BOOL)unprotectConfigurationFile: (NSString *) filePath
{
    NSString * actualConfigPath = [[filePath copy] autorelease];
    if (  [[actualConfigPath pathExtension] isEqualToString: @"tblk"]  ) {
        NSString * actualPath = configPathFromTblkPath(actualConfigPath);
        if (  ! actualPath  ) {
            NSLog(@"No configuration file in %@", actualConfigPath);
            return FALSE;
        }
        actualConfigPath = actualPath;
    }
    
    NSString * parentFolder = [actualConfigPath stringByDeletingLastPathComponent];
    if (  ! [gFileMgr isWritableFileAtPath: parentFolder]  ) {
        NSLog(@"No write permission on configuration file's parent directory %@", parentFolder);
        return FALSE;
    }
    
    NSString * configTempPath   = [actualConfigPath stringByAppendingPathExtension:@"temp"];
    NSString * oldExtension = [actualConfigPath pathExtension];
    NSString * configBackupPath = [[[actualConfigPath stringByDeletingPathExtension] stringByAppendingString:@"-previous"] stringByAppendingPathExtension: oldExtension];
    
    // Although the documentation for copyPath:toPath:handler: says that the file's ownership and permissions are copied, the ownership
    // of a file owned by root is NOT copied. Instead, the owner is the currently logged-in user:group, which is *exactly* what we want!
    [gFileMgr removeFileAtPath: configTempPath handler: nil];
    if (  ! [gFileMgr copyPath: actualConfigPath toPath: configTempPath handler: nil]  ) {
        NSLog(@"Unable to copy %@ to %@", actualConfigPath, configTempPath);
        return FALSE;
    }
    
    [gFileMgr removeFileAtPath: configBackupPath handler: nil];
    if (  ! [gFileMgr movePath: actualConfigPath toPath: configBackupPath handler: nil]  ) {
        NSLog(@"Unable to rename %@ to %@", actualConfigPath, configBackupPath);
        return FALSE;
    }
    
    if (  ! [gFileMgr movePath: configTempPath toPath: actualConfigPath handler: nil]  ) {
        NSLog(@"Unable to rename %@ to %@", configTempPath, actualConfigPath);
        return FALSE;
    }
    
    return TRUE;
}

-(void) openDotTblkPackages: (NSArray *) filePaths usingAuth: (AuthorizationRef) authRef
{
    if (  [gTbDefaults boolForKey: @"doNotOpenDotTblkFiles"]  )  {
        TBRunAlertPanel(NSLocalizedString(@"Tunnelblick VPN Configuration Installation Error", @"Window title"),
                        NSLocalizedString(@"Installation of .tblk packages is not allowed", "Window text"),
                        nil, nil, nil);
        [NSApp replyToOpenOrPrint: NSApplicationDelegateReplyFailure];
        return;
    }
    
    // If any paths are to a folder instead of a .tblk package, we search the folder and it's subfolders (including invisible
    // subfolders except for ._ resource forks) for .tblk packages and add them to augmentedFilePaths, which we use for processing
    // We do this to implement the automatic installation of configurations when Tunnelblick is installed from a disk image
    NSMutableArray * augmentedFilePaths = [NSMutableArray arrayWithArray: filePaths];
    NSString * file;
    BOOL isDir;
    int i;
    for (i=0; i < [filePaths count]; i++) {
        file = [filePaths objectAtIndex: i];
        if (  ! [[file pathExtension] isEqualToString: @"tblk"]  ) {
            [augmentedFilePaths removeObjectAtIndex: i];
            if (   [gFileMgr fileExistsAtPath:file isDirectory:&isDir]
                && isDir  ) {
                // Search the folder (deeply)
                NSString * tblkPath;
                NSDirectoryEnumerator * dirEnum = [gFileMgr enumeratorAtPath: file];
                while ( tblkPath = [dirEnum nextObject]  ) {
                    if (   [[tblkPath pathExtension] isEqualToString: @"tblk"]
                        && ( ! [[tblkPath lastPathComponent] hasPrefix: @"._"] )  ) {
                        NSDictionary * dict = [NSDictionary dictionaryWithContentsOfFile: [file stringByAppendingString: tblkPath]];
                        NSString * installIt = [self getLowerCaseStringForKey: @"TBInstallWhenInstallingTunnelblick" inDictionary: dict defaultTo: @"yes"];
                        if (  ! [installIt isEqualToString: @"no"]  ) {
                            int result = NSAlertDefaultReturn;  // Assume we do install it
                            if (   [installIt isEqualToString: @"ask"]  ) {
                                NSString * pkgShare = [self getLowerCaseStringForKey: @"TBSharePackage" inDictionary: dict defaultTo: @"ask"];
                                if (  ! [pkgShare isEqualToString: @"ask"]  ) {   // If will ask later (shared/private), don't ask now
                                    NSString * name = [[tblkPath lastPathComponent] stringByDeletingPathExtension];
                                    result = TBRunAlertPanel(NSLocalizedString(@"Install Tunnelblick VPN Configuration?", @"Window title"),
                                                             [NSString stringWithFormat: NSLocalizedString(@"Do you wish to install Tunnelblick VPN Configuration '%@'?", @"Window text"), name],
                                                             NSLocalizedString(@"Install", @"Button"),           // Default
                                                             NSLocalizedString(@"Do Not Install", @"Button"),    // Alternate
                                                             nil);
                                }
                            }
                            if (  result == NSAlertDefaultReturn  ) {
                                [augmentedFilePaths addObject: [file stringByAppendingPathComponent: tblkPath]];
                            }
                        }
                    }
                }
            }
        }
    }

    NSMutableArray * sourceList = [NSMutableArray arrayWithCapacity: [augmentedFilePaths count]];        // Paths to source of files OK to install
    NSMutableArray * targetList = [NSMutableArray arrayWithCapacity: [augmentedFilePaths count]];        // Paths to destination to install them
    NSMutableArray * errList    = [NSMutableArray arrayWithCapacity: [augmentedFilePaths count]];        // Paths to files not installed
    
    NSArray * dest;
    // Go through the augmented array, check each .tblk package, and add it to the install list if it is OK
    for (i=0; i < [augmentedFilePaths count]; i++) {
        file = [augmentedFilePaths objectAtIndex: i];
        dest = [self checkOneDotTblkPackage: file withKey: [NSString stringWithFormat: @"%d", i]];
        if (  dest  ) {
            if (  [dest count] != 0  ) {
                [sourceList addObject: [dest objectAtIndex: 0]];
                [targetList addObject: [dest objectAtIndex: 1]];
            }
        } else {
            [errList addObject: file];
        }
    }
    
    if (  [sourceList count] == 0  ) {
        return;
    }
    
    NSString * errPrefix;
    if (  [errList count] == 0  ) {
        errPrefix = @"";
    } else {
        errPrefix = NSLocalizedString(@"There was a problem with one or more configurations. Details are in the Console Log\n\n", @"Window text");
    }
    
    NSString * windowText = nil;
    if (  [sourceList count] == 1  ) {
        if (  [errList count] != 0) {
            windowText = NSLocalizedString(@"Do you wish to install one configuration?", @"Window text");
        }
    } else {
        int nConfigs = (int) [sourceList count];
        windowText = [NSString stringWithFormat: NSLocalizedString(@"Do you wish to install %d configurations?", @"Window text"),
                      nConfigs];
    }
    
    if (  windowText  ) {
        int result = TBRunAlertPanel(NSLocalizedString(@"Perform installation?", @"Window title"),
                                     [NSString stringWithFormat: @"%@%@", errPrefix, windowText],
                                     NSLocalizedString(@"OK", @"Button"),       // Default
                                     nil,                                       // Alternate
                                     NSLocalizedString(@"Cancel", @"Button"));  // Other
        if (  result == NSAlertOtherReturn  ) {
            if (  [errList count] == 0  ) {
                [NSApp replyToOpenOrPrint: NSApplicationDelegateReplyCancel];
            } else {
                [NSApp replyToOpenOrPrint: NSApplicationDelegateReplyFailure];
            }
            return;
        }
    }
    
    // **************************************************************************************
    // Install the packages
    
    AuthorizationRef localAuth = authRef;
    if ( ! authRef  ) {    // If we weren't given an AuthorizationRef, get our own
        NSString * msg = NSLocalizedString(@"Tunnelblick needs to install one or more Tunnelblick VPN Configurations.", @"Window text");
        localAuth = [NSApplication getAuthorizationRef: msg];
    }
    
    if (  ! localAuth  ) {
        NSLog(@"Configuration installer: The Tunnelblick VPN Configuration installation was cancelled by the user.");
        [NSApp replyToOpenOrPrint: NSApplicationDelegateReplyCancel];
        return;
    }
    
    int nErrors = 0;
    for (  i=0; i < [sourceList count]; i++  ) {
        NSString * source = [sourceList objectAtIndex: i];
        if (  ! [self copyConfigPath: source
                              toPath: [targetList objectAtIndex: i]
                        usingAuthRef: localAuth
                          warnDialog: NO
                         moveNotCopy: NO]  ) {
            nErrors++;
        }
        if (  [source hasPrefix: NSTemporaryDirectory()]  ) {
            [gFileMgr removeFileAtPath: [source stringByDeletingLastPathComponent] handler: nil];
        }
    }
    
    if (  ! authRef  ) {    // If we weren't given an AuthorizationRef, free the one we got
        AuthorizationFree(localAuth, kAuthorizationFlagDefaults);
    }
    
    if (  nErrors != 0  ) {
        NSString * msg;
        if (  nErrors == 1) {
            msg = NSLocalizedString(@"A configuration was not installed. See the Console log for details.", @"Window text");
        } else {
            msg = [NSString stringWithFormat: NSLocalizedString(@"%d configurations were not installed. See the Console Log for details.", "Window text"),
                   nErrors];
        }
        TBRunAlertPanel(NSLocalizedString(@"Tunnelblick VPN Configuration Installation Error", @"Window title"),
                        msg,
                        nil, nil, nil);
        [NSApp replyToOpenOrPrint: NSApplicationDelegateReplyFailure];
    } else {
        int nOK = [sourceList count];
        NSString * msg;
        if (  nOK == 1  ) {
            msg = NSLocalizedString(@"The Tunnelblick VPN Configuration was installed successfully.", @"Window text");
        } else {
            msg = [NSString stringWithFormat: NSLocalizedString(@"%d Tunnelblick VPN Configurations were installed successfully.", @"Window text"), nOK];
        }
        TBRunAlertPanel(NSLocalizedString(@"Tunnelblick VPN Configuration Installation", @"Window title"),
                        msg,
                        nil, nil, nil);
        [NSApp replyToOpenOrPrint: NSApplicationDelegateReplySuccess];
    }
}

// Checks one .tblk package to make sure it should be installed
// Returns an array with [source, dest] paths if it should be installed
// Returns an empty array if the user cancelled the installation
// Returns nil if an error occurred
-(NSArray *) checkOneDotTblkPackage: (NSString *) filePath withKey: (NSString *) key
{
    if (   [filePath hasPrefix: gPrivatePath]
        || [filePath hasPrefix: gSharedPath]
        || [filePath hasPrefix: gDeployPath]  ) {
        NSLog(@"Configuration installer: Tunnelblick VPN Configuration is already installed: %@", filePath);
        TBRunAlertPanel(NSLocalizedString(@"Configuration Installation Error", @"Window title"),
                        NSLocalizedString(@"You cannot install a Tunnelblick VPN configuration from an installed copy.\n\nYou can copy the installation and install from the copy.", @"Window text"),
                        nil, nil, nil);
        return nil;
    }
    
    BOOL pkgIsOK = TRUE;     // Assume it is OK to install the package
    
    NSString * tryDisplayName;      // Try to use this display name, but deal with conflicts
    tryDisplayName = [[filePath lastPathComponent] stringByDeletingPathExtension];
    
    // Do some preliminary checking to see if this is a well-formed .tblk. Return with path to .tblk to use
    // (which might be a temporary file with a "fixed" version of the .tblk).
    NSString * pathToTblk = [self getPackageToInstall: filePath withKey: key];
    if (  ! pathToTblk  ) {
        return nil;                     // Error occured
    }
    if (  [pathToTblk length] == 0) {
        return [NSArray array];         // User cancelled
    }
    
    // **************************************************************************************
    // Get the following data from Info.plist (and make sure nothing else is in it except TBPreference***):
    
    NSString * pkgId;
    NSString * pkgVersion;
//  NSString * pkgShortVersionString;
    NSString * pkgPkgVersion;
    NSString * pkgReplaceIdentical;
    NSString * pkgSharePackage;
    NSString * pkgInstallWhenInstalling;
    
    NSString * infoPath = [pathToTblk stringByAppendingPathComponent: @"Contents/Info.plist"];
    NSDictionary * infoDict = [NSDictionary dictionaryWithContentsOfFile: infoPath];
    
    if (  infoDict  ) {
        pkgId = [self getLowerCaseStringForKey: @"CFBundleIdentifier" inDictionary: infoDict defaultTo: nil];
        if (  pkgId  ) {
            if (  [pkgId length] == 0  ) {
                pkgId = [pathToTblk lastPathComponent];
            }
        }
        
        pkgVersion = [self getLowerCaseStringForKey: @"CFBundleVersion" inDictionary: infoDict defaultTo: nil];
        
        //  pkgShortVersionString = [self getLowerCaseStringForKey: @"CFBundleShortVersionString" inDictionary: infoDict defaultTo: nil];
        
        pkgPkgVersion = [self getLowerCaseStringForKey: @"TBPackageVersion" inDictionary: infoDict defaultTo: nil];
        if (  ! [pkgPkgVersion isEqualToString: @"1"]  ) {
            NSLog(@"Configuration installer: Unknown 'TBPackageVersion' = '%@' (only '1' is allowed) in %@", pkgPkgVersion, infoPath);
            pkgIsOK = FALSE;
        }
        
        pkgReplaceIdentical = [self getLowerCaseStringForKey: @"TBReplaceIdentical" inDictionary: infoDict defaultTo: @"ask"];
        NSArray * okValues = [NSArray arrayWithObjects: @"no", @"yes", @"force", @"ask", nil];
        if ( ! [okValues containsObject: pkgReplaceIdentical]  ) {
            NSLog(@"Configuration installer: Invalid value '%@' (only 'no', 'yes', 'force', or 'ask' are allowed) for 'TBReplaceIdentical' in %@", pkgReplaceIdentical, infoPath);
            pkgIsOK = FALSE;
        }
        
        pkgSharePackage = [self getLowerCaseStringForKey: @"TBSharePackage" inDictionary: infoDict defaultTo: @"ask"];
        okValues = [NSArray arrayWithObjects: @"private", @"shared", @"ask", nil];
        if ( ! [okValues containsObject: pkgSharePackage]  ) {
            NSLog(@"Configuration installer: Invalid value '%@' (only 'shared', 'private', or 'ask' are allowed) for 'TBSharePackage' in %@", pkgSharePackage, infoPath);
            pkgIsOK = FALSE;
        }
        
        pkgInstallWhenInstalling = [self getLowerCaseStringForKey: @"TBInstallWhenInstallingTunnelblick" inDictionary: infoDict defaultTo: @"ask"];
        okValues = [NSArray arrayWithObjects: @"no", @"yes", @"ask", nil];
        if ( ! [okValues containsObject: pkgInstallWhenInstalling]  ) {
            NSLog(@"Configuration installer: Invalid value '%@' (only 'yes', 'no', or 'ask' are allowed) for 'TBInstallWhenInstallingTunnelblick' in %@", pkgInstallWhenInstalling, infoPath);
        }
        
        NSString * key;
        NSArray * validKeys = [NSArray arrayWithObjects: @"CFBundleIdentifier", @"CFBundleVersion", @"CFBundleShortVersionString",
                               @"TBPackageVersion", @"TBReplaceIdentical", @"TBSharePackage", @"TBInstallWhenInstallingTunnelblick", nil];
        NSEnumerator * e = [infoDict keyEnumerator];
        while (  key = [e nextObject]  ) {
            if (  ! [validKeys containsObject: key]  ) {
                if (  ! [key hasPrefix: @"TBPreference"]  ) {
                    NSLog(@"Configuration installer: Unknown key '%@' in %@", key, infoPath);
                    pkgIsOK = FALSE;
                }
            }
        }
    } else {
        // No Info.plist, so use default values
        pkgId                       = nil;
        pkgVersion                  = nil;
        pkgReplaceIdentical         = @"ask";
        pkgSharePackage             = @"ask";
//        pkgInstallWhenInstalling    = @"ask";
    }

        
    // **************************************************************************************
    // Make sure there is exactly one configuration file
    int numberOfConfigFiles = 0;
    BOOL haveConfigDotOvpn = FALSE;
    NSString * file;
    NSString * folder = [pathToTblk stringByAppendingPathComponent: @"Contents/Resources"];
    NSDirectoryEnumerator *dirEnum = [gFileMgr enumeratorAtPath: folder];
    while (file = [dirEnum nextObject]) {
        if (  itemIsVisible([folder stringByAppendingPathComponent: file])  ) {
            NSString * ext = [file pathExtension];
            if (  [file isEqualToString: @"config.ovpn"]  ) {
                haveConfigDotOvpn = TRUE;
                numberOfConfigFiles++;
            } else if (  [ext isEqualToString: @"conf"] || [ext isEqualToString: @"ovpn"]  ) {
                numberOfConfigFiles++;
            }
        }
    }
    
    
    if (  ! haveConfigDotOvpn  ) {
        NSLog(@"Configuration installer: No configuration file '/Contents/Resources/config.ovpn' in %@", tryDisplayName);
        pkgIsOK = FALSE;
    }
    
    if (  numberOfConfigFiles != 1  ) {
        NSLog(@"Configuration installer: Exactly one configuration file, '/Contents/Resources/config.ovpn', is allowed in a .tblk package. %d configuration files were found in %@", numberOfConfigFiles, tryDisplayName);
        pkgIsOK = FALSE;
    }
    
    if ( ! pkgIsOK  ) {
        return nil;
    }
    
    // **************************************************************************************
    // See if there is a package with the same CFBundleIdentifier and deal with that
    NSString * replacementPath = nil;   // Complete path of package this one is replacing, or nil if not replacing

    if (  pkgId  ) {
        NSString * key;
        NSEnumerator * e = [[[NSApp delegate] myConfigDictionary] keyEnumerator];
        while (key = [e nextObject]) {
            NSString * path = [[[NSApp delegate] myConfigDictionary] objectForKey: key];
            NSString * last = lastPartOfPath(path);
            NSString * oldDisplayFirstPart = firstPathComponent(last);
            if (  [[oldDisplayFirstPart pathExtension] isEqualToString: @"tblk"]  ) {
                NSDictionary * oldInfo = [NSDictionary dictionaryWithContentsOfFile: [path stringByAppendingPathComponent: @"Contents/Info.plist"]];
                NSString * oldVersion = [oldInfo objectForKey: @"CFBundleVersion"];
                if (  [[oldInfo objectForKey: @"CFBundleIdentifier"] isEqualToString: pkgId]) {
                    if (  [pkgReplaceIdentical isEqualToString: @"no"]  ) {
                        NSLog(@"Configuration installer: Tunnelblick VPN Configuration %@ has NOT been installed: TBReplaceOption=NO.", tryDisplayName);
                        return nil;
                    } else if (  [pkgReplaceIdentical isEqualToString: @"force"]  ) {
                        // Fall through to install
                    } else if (  [pkgReplaceIdentical isEqualToString: @"yes"]  ) {
                        if (  [oldVersion compare: pkgVersion options: NSNumericSearch] == NSOrderedDescending  ) {
                            NSLog(@"Configuration installer: Tunnelblick VPN Configuration %@ has NOT been installed: it has a lower version number.", tryDisplayName);
                            return nil;
                        } else {
                            // Fall through to install
                        }
                    } else if (  [pkgReplaceIdentical isEqualToString: @"ask"]  ) {
                        NSString * msg;
                        replacementPath = [[[NSApp delegate] myConfigDictionary] objectForKey: key];
                        NSString * sharedPrivateDeployed;
                        if (  [replacementPath hasPrefix: gSharedPath]  ) {
                            sharedPrivateDeployed = @" (Shared)";
                        } else if (  [replacementPath hasPrefix: gPrivatePath]  ) {
                            sharedPrivateDeployed = @" (Private)";
                        } else {
                            sharedPrivateDeployed = @" (Deployed)";
                        }
                        if (  [oldVersion compare: pkgVersion options: NSNumericSearch] == NSOrderedSame  ) {
                            msg = [NSString stringWithFormat: NSLocalizedString(@"Do you wish to reinstall '%@'%@ version %@?", @"Window text"),
                                   tryDisplayName,
                                   sharedPrivateDeployed,
                                   pkgVersion];
                        } else {
                            msg = [NSString stringWithFormat: NSLocalizedString(@"Do you wish to replace '%@'%@ version %@ with version %@?", @"Window text"),
                                   tryDisplayName,
                                   sharedPrivateDeployed,
                                   pkgVersion,
                                   oldVersion];
                        }
                        int result = TBRunAlertPanel(NSLocalizedString(@"Replace Tunnelblick VPN Configuration", @"Window title"),
                                                     msg,
                                                     NSLocalizedString(@"Replace", @"Button"),  // Default
                                                     NSLocalizedString(@"Cancel", @"Button"),   // Alternate
                                                     nil);
                        if (  result == NSAlertAlternateReturn  ) {
                            NSLog(@"Configuration installer: Tunnelblick VPN Configuration %@ installation declined by user.", tryDisplayName);
                            return [NSArray array];
                        }
                    }
                    
                    tryDisplayName = [last stringByDeletingPathExtension];
                    replacementPath = [[[NSApp delegate] myConfigDictionary] objectForKey: key];
                    if (  [replacementPath hasPrefix: gSharedPath]  ) {
                        pkgSharePackage = @"shared";
                    } else {
                        pkgSharePackage = @"private";
                    }
                    break;
                }
            }
        }
    }
        
    // **************************************************************************************
    // Check for name conflicts if not replacing a package
    if (  ! replacementPath  ) {
        while (   ([tryDisplayName length] == 0)
               || [[[NSApp delegate] myConfigDictionary] objectForKey: tryDisplayName]  ) {
            NSString * msg;
            if (  [tryDisplayName length] == 0  ) {
                msg = NSLocalizedString(@"The VPN name cannot be empty.\n\nPlease enter a new name.", @"Window text");
            } else {
                msg = [NSString stringWithFormat: NSLocalizedString(@"The VPN name '%@' is already in use.\n\nPlease enter a new name.", @"Window text"), tryDisplayName];
            }
            
            NSMutableDictionary* panelDict = [[NSMutableDictionary alloc] initWithCapacity:6];
            [panelDict setObject:NSLocalizedString(@"Name In Use", @"Window title")   forKey:(NSString *)kCFUserNotificationAlertHeaderKey];
            [panelDict setObject:msg                                                forKey:(NSString *)kCFUserNotificationAlertMessageKey];
            [panelDict setObject:@""                                                forKey:(NSString *)kCFUserNotificationTextFieldTitlesKey];
            [panelDict setObject:NSLocalizedString(@"OK", @"Button")                forKey:(NSString *)kCFUserNotificationDefaultButtonTitleKey];
            [panelDict setObject:NSLocalizedString(@"Cancel", @"Button")            forKey:(NSString *)kCFUserNotificationAlternateButtonTitleKey];
            [panelDict setObject:[NSURL fileURLWithPath:[[NSBundle mainBundle]
                                                         pathForResource:@"tunnelblick"
                                                         ofType: @"icns"]]               forKey:(NSString *)kCFUserNotificationIconURLKey];
            SInt32 error;
            CFUserNotificationRef notification;
            CFOptionFlags response;
            
            // Get a name from the user
            notification = CFUserNotificationCreate(NULL, 30, 0, &error, (CFDictionaryRef)panelDict);
            [panelDict release];
            
            if((error) || (CFUserNotificationReceiveResponse(notification, 0, &response))) {
                CFRelease(notification);    // Couldn't receive a response
                NSLog(@"Configuration installer: The Tunnelblick VPN Package has NOT been installed.\n\nAn unknown error occured.", tryDisplayName);
                return nil;
            }
            
            if((response & 0x3) != kCFUserNotificationDefaultResponse) {
                CFRelease(notification);    // User clicked "Cancel"
                NSLog(@"Configuration installer: Installation of Tunnelblick VPN Package %@ has been cancelled.", tryDisplayName);
                return [NSArray array];
            }
            
            // Get the new name from the textfield
            tryDisplayName = [(NSString*)CFUserNotificationGetResponseValue(notification, kCFUserNotificationTextFieldValuesKey, 0)
                              stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            CFRelease(notification);
            if (  [[tryDisplayName pathExtension] isEqualToString: @"tblk"]  ) {
                tryDisplayName = [tryDisplayName stringByDeletingPathExtension];
            }
        }
    }
    
    if (   pkgIsOK ) {
        // **************************************************************************************
        // Ask if it should be shared or private
        if ( ! replacementPath  ) {
            if (  [pkgSharePackage isEqualToString: @"ask"]  ) {
                int result = TBRunAlertPanel(NSLocalizedString(@"Install Configuration For All Users?", @"Window title"),
                                             [NSString stringWithFormat: NSLocalizedString(@"Do you wish to install the '%@' configuration so that all users can use it, or so that only you can use it?\n\n", @"Window text"), tryDisplayName],
                                             NSLocalizedString(@"Only Me", @"Button"),      //Default button
                                             NSLocalizedString(@"All Users", @"Button"),    // Alternate button
                                             NSLocalizedString(@"Cancel", @"Button"));      // Alternate button);
                if (  result == NSAlertDefaultReturn  ) {
                    pkgSharePackage = @"private";
                } else if (  result == NSAlertAlternateReturn  ) {
                    pkgSharePackage = @"shared";
                } else {
                    NSLog(@"Configuration installer: Installation of Tunnelblick VPN Package %@ has been cancelled.", tryDisplayName);
                    return [NSArray array];
                }
            }
        }
        
        // **************************************************************************************
        // Indicate the package is to be installed
        NSString * tblkName = [tryDisplayName stringByAppendingPathExtension: @"tblk"];
        if (  [pkgSharePackage isEqualToString: @"private"]  ) {
            return [NSArray arrayWithObjects: pathToTblk, [gPrivatePath stringByAppendingPathComponent: tblkName], nil];
        } else if (  [pkgSharePackage isEqualToString: @"shared"]  ) {
            return [NSArray arrayWithObjects: pathToTblk, [gSharedPath  stringByAppendingPathComponent: tblkName], nil];
        }
    }
    
    return nil;
}

-(NSString *) getLowerCaseStringForKey: (NSString *) key inDictionary: (NSDictionary *) dict defaultTo: (id) replacement
{
    id retVal;
    retVal = [[dict objectForKey: key] lowercaseString];
    if (  retVal  ) {
        if (  ! [[retVal class] isSubclassOfClass: [NSString class]]  ) {
            NSLog(@"The value for Info.plist key '%@' is not a string. The entry will be ignored.");
            return nil;
        }
    } else {
        retVal = replacement;
    }

    return retVal;
}

// Does simple checks on a .tblk package.
// If it has a single folder at the top level named "Contents", returns the .tblk's path without looking inside "Contents"
// If it can be "fixed", returns the path to a temporary copy with the problems fixed.
// If it is empty, and the use chooses, a path to a temporay copy with the sample configuration file is returned.
// If it is empty, and the user cancels, an empty string (@"") is returned.
// Otherwise, returns nil to indicate an error;
// Can fix the following:
//   * Package contains, or has a single folder which contains, one .ovpn or .conf, and any number of .key, .crt, etc. files:
//          Moves the .ovpn or .conf to Contents/Resources/config.ovpn
//          Moves the .key, .crt, etc. files to Contents/Resources
-(NSString *) getPackageToInstall: (NSString *) thePath withKey: (NSString *) key;

{
    NSMutableArray * pkgList = [[gFileMgr directoryContentsAtPath: thePath] mutableCopy];
    if (  ! pkgList  ) {
        return nil;
    }
    
    // Remove invisible files and folders
    int i;
    for (i=0; i < [pkgList count]; i++) {
        if (  ! itemIsVisible([pkgList objectAtIndex: i])  ) {
            [pkgList removeObjectAtIndex: i];
            i--;
        }
    }
    
    // If empty package, make a sample config
    if (  [pkgList count] == 0  ) {
        int result = TBRunAlertPanel(NSLocalizedString(@"Install Sample Configuration?", @"Window Title"),
                                     [NSString stringWithFormat: NSLocalizedString(@"Tunnelblick VPN Configuration '%@' is empty. Do you wish to install a sample configuration with that name?", @"Window text"),
                                      [[thePath lastPathComponent]stringByDeletingPathExtension]],
                                     NSLocalizedString(@"Install Sample", @"Button"),
                                     NSLocalizedString(@"Cancel", @"Button"),
                                     nil);
        if (  result != NSAlertDefaultReturn  ) {
            [pkgList release];
            return @"";
        }

        [pkgList release];
        return [self makeTemporarySampleTblkWithName: [thePath lastPathComponent] andKey: key];
    }
    
    // If the .tblk contains only a single subfolder, "Contents", then return .tblk path
    NSString * firstItem = [pkgList objectAtIndex: 0];
    if (   ([pkgList count] == 1)
        && ( [[firstItem lastPathComponent] isEqualToString: @"Contents"])  ) {
        [pkgList release];
        return [[thePath copy] autorelease];
    }
    
    NSString * searchPath;    // Use this from here on
    
    // If the .tblk contains only a single subfolder (not "Contents"), look in that folder for stuff to put into Contents/Resources
    BOOL isDir;
    if (   ([pkgList count] == 1)
        && [gFileMgr fileExistsAtPath: firstItem isDirectory: &isDir]
        && isDir  ) {
        [pkgList release];
        pkgList = [[gFileMgr directoryContentsAtPath: firstItem] mutableCopy];
        searchPath = [[firstItem copy] autorelease];
    } else {
        searchPath = [[thePath copy] autorelease];
    }
    
    NSArray * extensionsFor600Permissions = [NSArray arrayWithObjects: @"cer", @"crt", @"der", @"key", @"p12", @"p7b", @"p7c", @"pem", @"pfx", nil];

    // Look through the package and see what's in it
    unsigned int nConfigs = 0;   // # of configuration files we've seen
    unsigned int nInfos   = 0;   // # of Info.plist files we've seen
    unsigned int nUnknown = 0;   // # of folders or unknown files we've seen
    for (i=0; i < [pkgList count]; i++) {
        NSString * ext = [[pkgList objectAtIndex: i] pathExtension];
        if (  itemIsVisible(thePath)  ) {
            if (   [gFileMgr fileExistsAtPath: thePath isDirectory: &isDir]
                && ( ! isDir )  ) {
                if (   [ext isEqualToString: @"conf"]
                    || [ext isEqualToString: @"ovpn"]  ) {
                    nConfigs++;
                } else if (  [[[pkgList objectAtIndex: i] lastPathComponent] isEqualToString: @"Info.plist"]  ) {
                    nInfos++;
                } else if (  [ext isEqualToString: @"sh"]  ) {
                    ;
                } else if (  [extensionsFor600Permissions containsObject: ext]  ) {
                    ;
                } else {
                    nUnknown++;
                }
            } else {
                nUnknown++;
            }
        }
    }
    
    if (  nConfigs == 0  ) {
        NSLog(@"Must have one configuration in a .tblk, %d were found in %@", nConfigs, searchPath);
        [pkgList release];
        return nil;
    }
    
    if (  nInfos > 1  ) {
        NSLog(@"Must have at most one Info.plist in a .tblk, %d were found in %@", nInfos, searchPath);
        [pkgList release];
        return nil;
    }
    
    if (  nUnknown != 0  ) {
        NSLog(@"Folder(s) or unrecognized file(s) found in %@", searchPath);
        [pkgList release];
        return nil;
    }
    
    // Create an empty .tblk and copy stuff in the folder to its Contents/Resources (Copy Info.plist to Contents)
    NSString * emptyTblk = [self makeEmptyTblk: thePath withKey: key];
    if (  ! emptyTblk  ) {
        [pkgList release];
        return nil;
    }
    
    NSString * emptyResources = [emptyTblk stringByAppendingPathComponent: @"Contents/Resources"];

    for (i=0; i < [pkgList count]; i++) {
        NSString * oldPath = [pkgList objectAtIndex: i];
        NSString * newPath;
        NSString * ext = [oldPath pathExtension];
        if (   [ext isEqualToString: @"conf"]
            || [ext isEqualToString: @"ovpn"]  ) {
            newPath = [emptyResources stringByAppendingPathComponent: @"config.ovpn"];
        } else if (  [[oldPath lastPathComponent] isEqualToString: @"Info.plist"]  ) {
            newPath = [[emptyResources stringByDeletingLastPathComponent] stringByAppendingPathComponent: @"Info.plist"];
        } else{
            newPath = [emptyResources stringByAppendingPathComponent: [oldPath lastPathComponent]];
        }

        if (  [gFileMgr copyPath: oldPath toPath: newPath handler: nil]  ) {
            NSLog(@"Unable to copy %@ to %@", oldPath, newPath);
            [pkgList release];
            return nil;
        }
    }
    
    [pkgList release];
    return emptyTblk;
}

-(BOOL) createDir: (NSString *) thePath
{
    BOOL result = [gFileMgr createDirectoryAtPath: thePath attributes: nil];
    if (  ! result  ) {
        NSLog(@"Unable to create folder at ", thePath);
    }
    return result;
}

-(NSString *) makeTemporarySampleTblkWithName: (NSString *) name andKey: (NSString *) key
{
    NSString * emptyTblk = [self makeEmptyTblk: name withKey: key];
    if (  ! emptyTblk  ) {
        NSLog(@"Unable to create temporary .tblk");
        return nil;
    }
    
    NSString * source = [[NSBundle mainBundle] pathForResource: @"openvpn" ofType: @"conf"];
    NSString * target = [emptyTblk stringByAppendingPathComponent: @"Contents/Resources/config.ovpn"];
    if (  ! [gFileMgr copyPath: source toPath: target handler: nil]  ) {
        NSLog(@"Unable to copy sample configuration file to %@", target);
        return nil;
    }
    return emptyTblk;
}    

// Creates an "empty" .tblk with name taken from input arugment, and with Contents/Resources created,
// in a newly-created temporary folder
// Returns nil on error, or with the path to the .tblk
-(NSString *) makeEmptyTblk: (NSString *) thePath withKey: (NSString *) key
{
    NSString * tempFolder = [NSTemporaryDirectory() stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"TunnelblickConfigInstallFolder-%d-%@", gSecuritySessionId, key]];
    
    NSString * tempTblk = [tempFolder stringByAppendingPathComponent: [thePath lastPathComponent]];
    
    NSString * tempContents = [tempTblk stringByAppendingPathComponent: @"Contents"];
    
    NSString * tempResources = [tempTblk stringByAppendingPathComponent: @"Contents/Resources"];
    
    [gFileMgr removeFileAtPath: tempFolder handler: nil];
    
    int result = [self createDir: tempFolder];
    if (  result == 0  ) {
        return nil;
    }
    result = [self createDir: tempTblk];
    if (  result == 0  ) {
        return nil;
    }
    result = [self createDir: tempContents];
    if (  result == 0  ) {
        return nil;
    }
    result = [self createDir: tempResources];
    if (  result == 0  ) {
        return nil;
    }
    
    return tempTblk;
}

// Given paths to a configuration (either a .conf or .ovpn file, or a .tblk package) in one of the gConfigDirs
// (~/Library/Application Support/Tunnelblick/Configurations, /Library/Application Support/Tunnelblick/Shared, or /Resources/Deploy,
// and an alternate config in /Library/Application Support/Tunnelblick/Users/<username>/
// Returns the path to use, or nil if can't use either one
-(NSString *) getConfigurationToUse:(NSString *)cfgPath orAlt:(NSString *)altCfgPath
{
    if (  [[ConfigurationManager defaultManager] isSampleConfigurationAtPath: cfgPath]  ) {             // Don't use the sample configuration file
        return nil;
    }
    
    if (  ! [self configNotProtected:cfgPath]  ) {                              // If config is protected
        if (  ! [gTbDefaults boolForKey:@"useShadowConfigurationFiles"]  ) {    //    If not using shadow configuration files
            return cfgPath;                                                     //    Then use it
        } else { 
            NSString * folder = firstPartOfPath(cfgPath);                       //    Or if are using shadow configuration files
            if (  ! [folder isEqualToString: gPrivatePath]  ) {                 //    And in Shared or Deploy (even if using shadow copies)
                return cfgPath;                                                 //    Then use it (we don't need to shadow copy them)
            }
        }
    }
    
    // Repair the configuration file or use the alternate
    AuthorizationRef authRef;
    if (   (! [self onRemoteVolume:cfgPath] )
        && (! [gTbDefaults boolForKey:@"useShadowConfigurationFiles"] )
        && ([cfgPath hasPrefix: gPrivatePath] )  ) {
        
        // We don't use a shadow configuration file
		NSLog(@"Configuration file %@ needs ownership/permissions repair", cfgPath);
        authRef = [NSApplication getAuthorizationRef: NSLocalizedString(@"Tunnelblick needs to repair ownership/permissions of the configuration file to secure it.", @"Window text")]; // Try to repair regular config
        if ( authRef == nil ) {
            NSLog(@"Repair authorization cancelled by user");
            AuthorizationFree(authRef, kAuthorizationFlagDefaults);	
            return nil;
        }
        if( ! [[ConfigurationManager defaultManager] protectConfigurationFile:cfgPath usingAuth:authRef] ) {
            AuthorizationFree(authRef, kAuthorizationFlagDefaults);
            return nil;
        }
        AuthorizationFree(authRef, kAuthorizationFlagDefaults);                         // Repair worked, so return the regular conf
        return cfgPath;
    } else {
        
        // We should use a shadow configuration file
        if ( [gFileMgr fileExistsAtPath:altCfgPath] ) {                                 // See if alt config exists
            // Alt config exists
            if ( [gFileMgr contentsEqualAtPath:cfgPath andPath:altCfgPath] ) {          // See if files are the same
                // Alt config exists and is the same as regular config
                if ( [self configNotProtected:altCfgPath] ) {                            // Check ownership/permissions
                    // Alt config needs repair
                    NSLog(@"The shadow copy of configuration file %@ needs ownership/permissions repair", cfgPath);
                    authRef = [NSApplication getAuthorizationRef: NSLocalizedString(@"Tunnelblick needs to repair ownership/permissions of the shadow copy of the configuration file to secure it.", @"Window text")]; // Repair if necessary
                    if ( authRef == nil ) {
                        NSLog(@"Repair authorization cancelled by user");
                        AuthorizationFree(authRef, kAuthorizationFlagDefaults);
                        return nil;
                    }
                    if(  ! [[ConfigurationManager defaultManager] protectConfigurationFile:altCfgPath usingAuth:authRef]  ) {
                        AuthorizationFree(authRef, kAuthorizationFlagDefaults);
                        return nil;                                                     // Couldn't repair alt file
                    }
                    AuthorizationFree(authRef, kAuthorizationFlagDefaults);
                }
                return altCfgPath;                                                      // Return the alt config
            } else {
                // Alt config exists but is different
                NSLog(@"The shadow copy of configuration file %@ needs to be updated from the original", cfgPath);
                authRef = [NSApplication getAuthorizationRef: NSLocalizedString(@"Tunnelblick needs to update the shadow copy of the configuration file from the original.", @"Window text")];// Overwrite it with the standard one and set ownership & permissions
                if ( authRef == nil ) {
                    NSLog(@"Authorization for update of shadow copy cancelled by user");
                    AuthorizationFree(authRef, kAuthorizationFlagDefaults);	
                    return nil;
                }
                if ( [self copyConfigPath: cfgPath toPath: altCfgPath usingAuthRef: authRef warnDialog: YES moveNotCopy: NO] ) {
                    AuthorizationFree(authRef, kAuthorizationFlagDefaults);
                    return altCfgPath;                                                  // And return the alt config
                } else {
                    AuthorizationFree(authRef, kAuthorizationFlagDefaults);             // Couldn't overwrite alt file with regular one
                    return nil;
                }
            }
        } else {
            // Alt config doesn't exist. We must create it (and maybe the folders that contain it)
            NSLog(@"Creating shadow copy of configuration file %@", cfgPath);
            
            // Folder creation code below needs alt config to be in /Library/Application Support/Tunnelblick/Users/<username>/xxx.conf
            NSString * altCfgFolderPath  = [altCfgPath stringByDeletingLastPathComponent]; // Strip off xxx.conf to get path to folder that holds it
            if (  ! [[altCfgFolderPath stringByDeletingLastPathComponent] isEqualToString:@"/Library/Application Support/Tunnelblick/Users"]  ) {
                NSLog(@"Internal Tunnelblick error: altCfgPath\n%@\nmust be in\n/Library/Application Support/Tunnelblick/Users/<username>", altCfgFolderPath);
                return nil;
            }
            
            authRef = [NSApplication getAuthorizationRef: NSLocalizedString(@"Tunnelblick needs to create a shadow copy of the configuration file.", @"Window text")]; // Create folders if they don't exist:
            if ( authRef == nil ) {
                NSLog(@"Authorization to create a shadow copy of the configuration file cancelled by user.");
                AuthorizationFree(authRef, kAuthorizationFlagDefaults);	
                return nil;
            }
            if ( ! [self makeSureFolderExistsAtPath:@"/Library/Application Support/Tunnelblick" usingAuth:authRef] ) {
                AuthorizationFree(authRef, kAuthorizationFlagDefaults);
                return nil;
            }
            if ( ! [self makeSureFolderExistsAtPath:@"/Library/Application Support/Tunnelblick/Users" usingAuth:authRef] ) {
                AuthorizationFree(authRef, kAuthorizationFlagDefaults);
                return nil;
            }
            if ( ! [self makeSureFolderExistsAtPath:altCfgFolderPath usingAuth:authRef] ) {     // /Library/.../<username>
                AuthorizationFree(authRef, kAuthorizationFlagDefaults);
                return nil;
            }
            if ( [self copyConfigPath: cfgPath toPath: altCfgPath usingAuthRef: authRef warnDialog: YES moveNotCopy: NO] ) {    // Copy the config to the alt config
                AuthorizationFree(authRef, kAuthorizationFlagDefaults);
                return altCfgPath;                                                              // Return the alt config
            }
            AuthorizationFree(authRef, kAuthorizationFlagDefaults);                             // Couldn't make alt file
            return nil;
        }
    }
}

-(BOOL) isSampleConfigurationAtPath: (NSString *) cfgPath
{
    NSString * samplePath = [[NSBundle mainBundle] pathForResource: @"openvpn" ofType: @"conf"];
    if (  [[cfgPath pathExtension] isEqualToString: @"tblk"]  ) {
        if (  ! [gFileMgr contentsEqualAtPath: [cfgPath stringByAppendingPathComponent: @"Contents/Resources/config.ovpn"] andPath: samplePath]  ) {
            return FALSE;
        }
    } else {
        if (  ! [gFileMgr contentsEqualAtPath: cfgPath andPath: samplePath]  ) {
            return FALSE;
        }
    }
    
    int button = TBRunAlertPanel(NSLocalizedString(@"You cannot connect using the sample configuration", @"Window title"),
                                 NSLocalizedString(@"You have tried to connect using a configuration file that is the same as the sample configuration file installed by Tunnelblick. The configuration file must be modified to connect to a VPN. You may also need other files, such as certificate or key files, to connect to the VPN.\n\nConsult your network administrator or your VPN service provider to obtain configuration and other files or the information you need to modify the sample file.\n\nOpenVPN documentation is available at\n\n     http://openvpn.net/index.php/open-source/documentation.html\n", @"Window text"),
                                 NSLocalizedString(@"Cancel", @"Button"),                           // Default button
                                 NSLocalizedString(@"Go to the OpenVPN documentation on the web", @"Button"), // Alternate button
                                 nil);                                                              // No Other button
	
    if( button == NSAlertAlternateReturn ) {
		[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://openvpn.net/index.php/open-source/documentation.html"]];
	}
    
    return TRUE;
}

// Checks ownership and permisions of .tblk package, or .ovpn or .conf file
// Returns YES if not secure, NO if secure
-(BOOL)configNotProtected:(NSString *)configFile 
{
    if (  [[configFile pathExtension] isEqualToString: @"tblk"]  ) {
        BOOL isDir;
        if (  [gFileMgr fileExistsAtPath: configFile isDirectory: &isDir]
            && isDir  ) {
            return folderContentsNeedToBeSecuredAtPath(configFile);
        } else {
            return YES;
        }
    }
    
    NSDictionary *fileAttributes = [gFileMgr fileAttributesAtPath:configFile traverseLink:YES];
    unsigned long perms = [fileAttributes filePosixPermissions];
    NSString *octalString = [NSString stringWithFormat:@"%o",perms];
    NSNumber *fileOwner = [fileAttributes fileOwnerAccountID];
    
    if ( (![octalString isEqualToString:@"644"])  || (![fileOwner isEqualToNumber:[NSNumber numberWithInt:0]])) {
        // NSLog(@"Configuration file %@ has permissions: 0%@, is owned by %@ and needs repair",configFile,octalString,fileOwner);
        return YES;
    }
    return NO;
}

-(BOOL) checkPermissions: (NSString *) permsShouldHave forPath: (NSString *) path
{
    NSDictionary *fileAttributes = [[NSFileManager defaultManager] fileAttributesAtPath: path traverseLink:YES];
    unsigned long perms = [fileAttributes filePosixPermissions];
    NSString *octalString = [NSString stringWithFormat:@"%o",perms];
    
    return [octalString isEqualToString: permsShouldHave];
}

// Returns TRUE if a file is on a remote volume or statfs on it fails, FALSE otherwise
-(BOOL) onRemoteVolume:(NSString *)cfgPath
{
    const char * fileName = [cfgPath UTF8String];
    struct statfs stats_buf;
    
    if (  0 == statfs(fileName, &stats_buf)  ) {
        if (  (stats_buf.f_flags & MNT_LOCAL) == MNT_LOCAL  ) {
            return FALSE;
        }
    } else {
        NSLog(@"statfs on %@ failed; assuming it is a remote volume\nError was '%s'", cfgPath, strerror(errno));
    }
    return TRUE;   // Network volume or error accessing the file's data.
}

// Attempts to set ownership/permissions on a config file to root:wheel/0644
// Returns TRUE if succeeded, FALSE if failed, having already output an error message to the console log
-(BOOL)protectConfigurationFile: (NSString *) configFilePath usingAuth: (AuthorizationRef) authRef
{
    NSString * launchPath = [[NSBundle mainBundle] pathForResource: @"installer" ofType: nil];
    NSArray * arguments = [NSArray arrayWithObjects: @"0", @"0", configFilePath, nil];
    
    OSStatus status;
    BOOL okNow;
    
    int i;
    for (i=0; i < 5; i++) {  // We retry this up to five times
        status = [NSApplication executeAuthorized:launchPath withArguments: arguments withAuthorizationRef: authRef];
        if (  status != 0  ) {
            NSLog(@"Returned status of %d indicates failure of installer execution of %@: %@", status, launchPath, arguments);
        }
        
        // installer creates a file to act as a flag that the installation failed. installer deletes it before a success return
        // The filename needs the session ID to support fast user switching
        NSString * installFailureFlagFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                                 [NSString stringWithFormat:@"TunnelblickInstallationFailed-%d.txt", gSecuritySessionId]];
        BOOL failed = [gFileMgr fileExistsAtPath: installFailureFlagFilePath];
        if (  failed  ) {
            NSLog(@"Presence of error file indicates failure of installer execution of %@: %@", launchPath, arguments);
            [gFileMgr removeFileAtPath: installFailureFlagFilePath handler: nil];
        }
        
        okNow = ! [self configNotProtected: configFilePath];
        if (  okNow  ) {
            break;
        }
        
        sleep(1);   //OS X caches info and if we secure and immediately check that it's been secured, sometimes it hasn't
        
        okNow = ! [self configNotProtected: configFilePath];
        if (  okNow  ) {
            break;
        }
        
        NSLog(@"installer failed to protect the configuration; retrying");
    }
    
    if (  ! okNow  ) {
        NSLog(@"Could not protect configuration. Failed installer execution of %@: %@", launchPath, arguments);
        NSLog(@"Could not change ownership and/or permissions of configuration file %@", configFilePath);
        TBRunAlertPanel([NSString stringWithFormat:@"%@: %@",
                         [self displayNameForPath: configFilePath],
                         NSLocalizedString(@"Not connecting", @"Window title")],
                        NSLocalizedString(@"Tunnelblick could not change ownership and permissions of the configuration file to secure it. See the Console Log for details.", @"Window text"),
                        nil,
                        nil,
                        nil);
        return FALSE;
    }
    
    NSLog(@"Secured configuration file %@", configFilePath);
    return TRUE;
}

// Copies or moves a config file or package and sets ownership and permissions on the target
// Returns TRUE if succeeded, FALSE if failed, having already output an error message to the console log
-(BOOL) copyConfigPath: (NSString *) sourcePath toPath: (NSString *) targetPath usingAuthRef: (AuthorizationRef) authRef warnDialog: (BOOL) warn moveNotCopy: (BOOL) moveInstead
{
    if (  [sourcePath isEqualToString: targetPath]  ) {
        NSLog(@"You cannot copy or move a configuration to itself. Trying to do that with %@", sourcePath);
        return FALSE;
    }
    
    NSString * moveFlag = (moveInstead ? @"1" : @"0");
    
    NSString * launchPath = [[NSBundle mainBundle] pathForResource: @"installer" ofType: nil];
    NSArray * arguments = [NSArray arrayWithObjects: @"0", @"0", targetPath, sourcePath, moveFlag, nil];
    
    OSStatus status;
    BOOL okNow;
    int i;
    for (i=0; i< 5; i++) {  // Retry up to five times
        status = [NSApplication executeAuthorized:launchPath withArguments: arguments withAuthorizationRef: authRef];
        if (  status != 0  ) {
            NSLog(@"Returned status of %d indicates failure of installer execution of %@: %@", status, launchPath, arguments);
        }
        
        // installer creates a file to act as a flag that the installation failed. installer deletes it before a success return
        // The filename needs the session ID to support fast user switching
        NSString * installFailureFlagFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                                 [NSString stringWithFormat:@"TunnelblickInstallationFailed-%d.txt", gSecuritySessionId]];
        BOOL failed = [gFileMgr fileExistsAtPath: installFailureFlagFilePath];
        if (  failed  ) {
            NSLog(@"Presence of error file indicates failure of installer execution of %@: %@", launchPath, arguments);
            [gFileMgr removeFileAtPath: installFailureFlagFilePath handler: nil];
        }
        
        okNow = ! [self configNotProtected: targetPath];
        if (  okNow  ) {
            break;
        }
        
        sleep(1);   //OS X caches info and if we secure and immediately check that it's been secured, sometimes it hasn't
        
        okNow = ! [self configNotProtected: targetPath];
        if (  okNow  ) {
            break;
        }
        
        NSLog(@"installer failed trying to copy the configuration; retrying");
    }
    
    if (  ! okNow  ) {
        NSLog(@"Could not copy/move and secure configuration file %@ to %@", sourcePath, targetPath);
        if (  warn  ) {
            NSString * name = lastPartOfPath(sourcePath);
            NSString * title;
            NSString * msg;
            if (  moveFlag  ) {
                title = NSLocalizedString(@"Could Not Move and Secure Configuration", @"Window title");
                msg = [NSString stringWithFormat: NSLocalizedString(@"Tunnelblick could not move the '%@' configuration file and secure it in its new location. See the Console Log for details.", @"Window text"),
                       name];
            } else {
                title = NSLocalizedString(@"Could Not Copy and Secure Configuration", @"Window title");
                msg = [NSString stringWithFormat: NSLocalizedString(@"Tunnelblick could not copy the '%@' configuration and secure the copy. See the Console Log for details.", @"Window text"),
                       name];
            }

            TBRunAlertPanel(title, msg, nil, nil, nil);
        }
        return FALSE;
    }
    
    if (  moveInstead  ) {
        NSLog(@"Moved configuration file %@ to %@ and secured the copy", sourcePath, targetPath);
    } else {
        NSLog(@"Copied configuration file %@ to %@ and secured the copy", sourcePath, targetPath);
    }
    
    return TRUE;
}

// If the specified folder doesn't exist, uses root to create it so it is owned by root:wheel and has permissions 0755.
// If the folder exists, ownership doesn't matter (as long as we can read/execute it).
// Returns TRUE if the folder already existed or was created successfully, returns FALSE otherwise, having already output an error message to the console log.
-(BOOL) makeSureFolderExistsAtPath:(NSString *)folderPath usingAuth: (AuthorizationRef) authRef
{
    BOOL isDir;
    
    if (   [gFileMgr fileExistsAtPath:folderPath isDirectory:&isDir]
        && isDir  ) {
        return TRUE;
    }
    
    NSString *launchPath = @"/bin/mkdir";
	NSArray *arguments = [NSArray arrayWithObjects:folderPath, nil];
    OSStatus status;
	int i;
    
	for (i=0; i <= 5; i++) {
		status = [NSApplication executeAuthorized:launchPath withArguments:arguments withAuthorizationRef:authRef];
        if (  status != 0  ) {
            NSLog(@"Returned status of %d indicates failure of execution of %@: %@", status, launchPath, arguments);
        }
        
		if (   [gFileMgr fileExistsAtPath:folderPath isDirectory:&isDir] 
            && isDir  ) {
			break;
		}
        
        sleep(1);   //OS X caches info or something and if we create it and immediately check that it's been created, sometimes it hasn't
        
		if (   [gFileMgr fileExistsAtPath:folderPath isDirectory:&isDir] 
            && isDir  ) {
			break;
		}
        
        NSLog(@"mkdir failed; retrying");
	}
    
    if (   [gFileMgr fileExistsAtPath:folderPath isDirectory:&isDir]
        && isDir  ) {
        return TRUE;
    }
    
    NSLog(@"Tunnelblick could not create folder %@ for the alternate configuration in 5 attempts. OSStatus %ld.", folderPath, status);
    TBRunAlertPanel(NSLocalizedString(@"Not connecting", @"Window title"),
                    NSLocalizedString(@"Tunnelblick could not create a folder for the alternate local configuration. See the Console Log for details.", @"Window text"),
                    nil,
                    nil,
                    nil);
    return FALSE;
}

-(NSString *) displayNameForPath: (NSString *) thePath
{
    return [lastPartOfPath(thePath) stringByDeletingPathExtension];
}

@end