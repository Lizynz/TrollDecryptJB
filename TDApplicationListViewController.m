#import "TDApplicationListViewController.h"
#import "TDAlternateIconViewController.h"
#import "Decryption/TDDecryptionTask.h"
#import "Localize.h"

#import "Extensions/UIImage+Private.h"
#import "Extensions/LSBundleProxy+TrollDecrypt.h"
#import "TDFileManagerViewController.h"
#import <MobileCoreServices/MobileCoreServices.h>
#import "Extensions/LSApplicationProxy+AltList.h"
#import "Extensions/LSApplicationProxy+AppState.h"

#import <spawn.h>
#import <rootless.h>
#import "appstoretrollerKiller/TSUtil.h"

static inline NSUInteger getEffectiveIconFormat(void) {
    return (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) ? 8 : 10;
}

@implementation TDApplicationListViewController {
    NSArray *_allAvailableApplications;
    NSArray *_filteredApplications;
    UISearchController *_searchController;

    UIImage *_placeholderIcon;
    NSMutableDictionary *_iconCache;
    UIAlertController *_progressAlert;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _hookPrefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.trolldecrypt.hook"];

        _iconCache = [NSMutableDictionary new];
        _placeholderIcon =
            [UIImage _applicationIconImageForBundleIdentifier:@"com.apple.WebSheet"
                                                       format:getEffectiveIconFormat()
                                                        scale:[UIScreen mainScreen].scale];

        [[LSApplicationWorkspace defaultWorkspace] addObserver:self];
        [self loadAvailableApplications];
    }
    return self;
}

- (void)dealloc {
	[[LSApplicationWorkspace defaultWorkspace] removeObserver:self];
}

- (void)applicationsDidInstall:(NSArray <LSApplicationProxy *> *)apps {
	[self refresh];
}

- (void)applicationsDidUninstall:(NSArray <LSApplicationProxy *> *)apps {
	[self refresh];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self _configureToolbarItems];
    [self _configureSearchController];
}

- (void)_configureToolbarItems {
    UIBarButtonItem *aboutButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"info.circle"] style:UIBarButtonItemStylePlain target:self action:@selector(about:)];
    self.navigationItem.rightBarButtonItem = aboutButton;
    
    if ([UIApplication sharedApplication].supportsAlternateIcons) {
        UIBarButtonItem *alternateIconButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"paintbrush.fill"] style:UIBarButtonItemStylePlain target:self action:@selector(_alternateIconButtonTapped)];
        self.navigationItem.leftBarButtonItem = alternateIconButton;
    }
}

- (void)_configureSearchController {
    _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    _searchController.searchResultsUpdater = self;
    _searchController.obscuresBackgroundDuringPresentation = NO;
    _searchController.searchBar.placeholder = [Localize localizedStringForKey:@"SEARCH_APPLICATIONS"];
    _searchController.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _searchController.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;

    self.navigationItem.searchController = _searchController;
    self.definesPresentationContext = YES;
}

- (void)patchMobileGestaltVersion:(NSString *)newVersion {
    NSString *plistPath = @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist";
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:plistPath]) {
        NSLog(@"[TrollDecrypt] MobileGestalt plist not found at %@", plistPath);
        return;
    }

    NSMutableDictionary *mgDict = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
    if (!mgDict) mgDict = [NSMutableDictionary dictionary];

    NSMutableDictionary *cacheExtra = [mgDict[@"CacheExtra"] mutableCopy];
    if (!cacheExtra) cacheExtra = [NSMutableDictionary dictionary];

    NSString *targetKey = @"qNNddlUK+B/YlooNoymwgA";
    cacheExtra[targetKey] = newVersion;
    mgDict[@"CacheExtra"] = cacheExtra;

    BOOL saved = [mgDict writeToFile:plistPath atomically:YES];
    NSLog(@"[TrollDecrypt] MobileGestalt plist saved: %@", saved ? @"YES" : @"NO");

    if (saved) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            killall(@"cfprefsd", YES);
            NSLog(@"[TrollDecrypt] MobileGestalt cache reset");

            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"iOS Version Patched"
                                                                               message:[NSString stringWithFormat:@"Version set to %@ for key %@", newVersion, targetKey]
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            });
        });
    }
}

- (void)about:(id)sender {
    BOOL hookEnabled = [self.hookPrefs boolForKey:@"hookEnabled"];
    BOOL updatesEnabled = [self.hookPrefs boolForKey:@"updatesEnabled"];
    NSString *iosVersion = [self.hookPrefs objectForKey:@"iOSVersion"];
    if (iosVersion == nil || [iosVersion length] == 0) {
        iosVersion = @"99.0.0";
    }
    
    NSString *hookStatus = hookEnabled ? @"Enabled" : @"Disabled";
    NSString *updatesStatus = updatesEnabled ? @"Enabled" : @"Disabled (buyProduct only)";
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"TrollDecrypt JB"
        message:[NSString stringWithFormat:@"Original by fiore\nModified by 34306 and khanhduytran0\nIcon by @super.user\nbfdecrypt by @bishopfox\ndumpdecrypted by @i0n1c\nUpdated for TrollStore by @wh1te4ever\nNathan and mineek for appstoretroller\n\n\nAppStore Spoof: %@\nSpoof iOS Version: %@\nShow Update (in AppStore): %@\n\nThis modified version support decrypt higher requirement iOS application.\nThanks to khanhduytran0, appstoretroller, lldb, modified by 34306.", hookStatus, iosVersion, updatesStatus]
        preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *dismiss = [UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleCancel handler:nil];
    
    if (hookEnabled) {
        UIAlertAction *toggleHook = [UIAlertAction actionWithTitle:@"Disable Hook"
            style:UIAlertActionStyleDestructive
            handler:^(UIAlertAction *action) {
                [self toggleAppStoreHook];
            }];
        
        UIAlertAction *setIOSVersion = [UIAlertAction actionWithTitle:@"Set iOS Version"
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                [self setIOSVersion];
            }];
        
        UIAlertAction *toggleUpdates = [UIAlertAction actionWithTitle:updatesEnabled ? @"Disable All Updates" : @"Enable All Updates"
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                [self toggleUpdatesEnabled];
            }];
        
        [alert addAction:toggleHook];
        [alert addAction:setIOSVersion];
        [alert addAction:toggleUpdates];
    } else {
        UIAlertAction *toggleHook = [UIAlertAction actionWithTitle:@"Enable Hook"
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                [self toggleAppStoreHook];
            }];
        [alert addAction:toggleHook];
    }
    
    [alert addAction:dismiss];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toggleAppStoreHook {
    BOOL currentState = [self.hookPrefs boolForKey:@"hookEnabled"];
    BOOL newState = !currentState;
    
    [self.hookPrefs setBool:newState forKey:@"hookEnabled"];
    [self.hookPrefs synchronize];
    
    NSString *status = newState ? @"enabled" : @"disabled";
    NSString *message = [NSString stringWithFormat:@"AppStore hook has been %@.\n\nClick Apply to restart daemons and activate changes.", status];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Hook Status Changed"
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    
    // UIAlertAction *ok = [UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil];
    
    UIAlertAction *apply = [UIAlertAction actionWithTitle:@"Apply"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            [self applyChanges];
        }];
    
    [alert addAction:apply];
    //[alert addAction:ok];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)setIOSVersion {
    NSString *currentVersion = [self.hookPrefs objectForKey:@"iOSVersion"];
    if (currentVersion == nil || [currentVersion length] == 0) {
        currentVersion = @"99.0.0";
    }
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Set iOS Version"
        message:[NSString stringWithFormat:@"Enter the iOS version to spoof (e.g., 18.0.0).\n\nCurrent: %@", currentVersion]
        preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"e.g., 18.0.0";
        textField.text = currentVersion;
        textField.keyboardType = UIKeyboardTypeDecimalPad;
    }];
    
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *newVersion = alert.textFields.firstObject.text;
        if (newVersion && [newVersion length] > 0) {
            
            [self.hookPrefs setObject:newVersion forKey:@"iOSVersion"];
            [self.hookPrefs synchronize];
            
            [self patchMobileGestaltVersion:newVersion];
            
            UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"iOS Version Updated"
                message:[NSString stringWithFormat:@"iOS version set to %@.\n\nClick Apply to restart daemons and activate changes.", newVersion]
                preferredStyle:UIAlertControllerStyleAlert];
            
            UIAlertAction *apply = [UIAlertAction actionWithTitle:@"Apply"
                style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) {
                    [self applyChanges];
                }];
            
            [successAlert addAction:apply];
            [self presentViewController:successAlert animated:YES completion:nil];
        }
    }];
    
    [alert addAction:save];
    [alert addAction:cancel];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toggleUpdatesEnabled {
    BOOL currentState = [self.hookPrefs boolForKey:@"updatesEnabled"];
    BOOL newState = !currentState;
    
    [self.hookPrefs setBool:newState forKey:@"updatesEnabled"];
    [self.hookPrefs synchronize];
    
    NSString *status = newState ? @"All app updates will now be spoofed" : @"Only buyProduct requests will be spoofed";
    NSString *message = [NSString stringWithFormat:@"%@.\n\nApply to activate changes.", status];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Updates Setting Changed"
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    
    // UIAlertAction *ok = [UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil];
    
    UIAlertAction *apply = [UIAlertAction actionWithTitle:@"Apply"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            [self applyChanges];
        }];
    
    [alert addAction:apply];
    //[alert addAction:ok];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)applyChanges {
    // kill: appstored, installd, and AppStore app
    NSString *killerPath = ROOT_PATH_NS(@"/usr/local/bin/TDDaemonKiller");
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *stdOut = nil;
        NSString *stdErr = nil;
        int result = spawnRoot(killerPath, @[], &stdOut, &stdErr);
        
        NSLog(@"[TrollDecrypt] appstoretrollerKiller result: %d", result);
        if (stdOut && stdOut.length > 0) {
            NSLog(@"[TrollDecrypt] stdout: %@", stdOut);
        }
        if (stdErr && stdErr.length > 0) {
            NSLog(@"[TrollDecrypt] stderr: %@", stdErr);
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Changes Applied"
                message:@"Daemons restarted successfully. Hook settings are now active."
                preferredStyle:UIAlertControllerStyleAlert];
            
            UIAlertAction *ok = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
            [alert addAction:ok];
            
            // Present on the topmost view controller
            UIViewController *topVC = self;
            while (topVC.presentedViewController) {
                topVC = topVC.presentedViewController;
            }
            [topVC presentViewController:alert animated:YES completion:nil];
        });
    });
}

- (void)_alternateIconButtonTapped {
    // present modally
    TDAlternateIconViewController *iconVC = [[TDAlternateIconViewController alloc] init];
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:iconVC];
    [self presentViewController:navController animated:YES completion:nil];
}


- (void)refresh {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self loadAvailableApplications];
        
        [self.tableView reloadData];
    });
}

- (void)loadAvailableApplications {
    NSMutableArray *apps = [NSMutableArray array];

    NSArray <LSApplicationProxy *> *allInstalledApps = [[LSApplicationWorkspace defaultWorkspace] atl_allInstalledApplications];
    [allInstalledApps enumerateObjectsWithOptions:NSEnumerationReverse usingBlock:^(LSApplicationProxy *proxy, NSUInteger idx, BOOL *stop) {
        _LSApplicationState *state = proxy.appState;
        
        bool shouldSkip = (![proxy atl_isUserApplication] ||
            ![proxy atl_bundleIdentifier] ||
            ![proxy atl_nameToDisplay] ||
            ![proxy atl_shortVersionString] ||
            ![proxy bundleURL] ||
            !state.isInstalled ||
            state.isPlaceholder);

        if (shouldSkip) return;

        [apps addObject:proxy];
    }];

    NSSortDescriptor *sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"atl_nameToDisplay" ascending:YES];
    _allAvailableApplications = [apps sortedArrayUsingDescriptors:@[sortDescriptor]];

    [self _applySearchFilter];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [_filteredApplications count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {    
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DecryptionAppCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"DecryptionAppCell"];

    LSApplicationProxy *application = _filteredApplications[indexPath.row];

    cell.textLabel.text = [application atl_nameToDisplay];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@", [application atl_shortVersionString], [application atl_bundleIdentifier]];
    
    if ([_iconCache objectForKey:[application atl_bundleIdentifier]]) {
        cell.imageView.image = [_iconCache objectForKey:[application atl_bundleIdentifier]];
        return cell;
    }

    cell.imageView.image = _placeholderIcon;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:[application atl_bundleIdentifier] format:getEffectiveIconFormat() scale:[UIScreen mainScreen].scale];
        if (icon) {
            [_iconCache setObject:icon forKey:[application atl_bundleIdentifier]];
            dispatch_async(dispatch_get_main_queue(), ^{
                UITableViewCell *updateCell = [tableView cellForRowAtIndexPath:indexPath];
                if (updateCell) {
                    updateCell.imageView.image = icon;
                    [updateCell setNeedsLayout];
                }
            });
        }
    });

    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 80.0f;
}

// TDDecryptionTask
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    LSApplicationProxy *application = _filteredApplications[indexPath.row];

    NSString *title = [Localize localizedStringForKey:@"DECRYPT"];
    NSString *subtitle = [NSString stringWithFormat:[Localize localizedStringForKey:@"DECRYPTION_PROMPT"], [application atl_nameToDisplay]];
    // UIAlertController *alert = [UIAlertController alertControllerWithTitle:[Localize localizedStringForKey:@"DECRYPT"] message:[NSString stringWithFormat:@"Do you want to decrypt %@?", [application atl_nameToDisplay]] preferredStyle:UIAlertControllerStyleActionSheet];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:subtitle preferredStyle:UIAlertControllerStyleActionSheet];


    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:[Localize localizedStringForKey:@"CANCEL"] style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:cancelAction];

    UIAlertAction *decryptBinaryOnlyAction = [UIAlertAction actionWithTitle:[Localize localizedStringForKey:@"MAIN_BINARY_ONLY"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        TDDecryptionTaskOptions options = TDDecryptionTaskOptionsMake(true);
        [self _decryptApplicationProxy:application options:options];
    }];
    [alert addAction:decryptBinaryOnlyAction];

    UIAlertAction *decryptAction = [UIAlertAction actionWithTitle:[Localize localizedStringForKey:@"FULL_IPA"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self _decryptApplicationProxy:application];
    }];
    [alert addAction:decryptAction];

    // iPad popover fix - @NightwindDev
    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (popover) {
        popover.sourceView = self.view;
        popover.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
        popover.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }

    [self presentViewController:alert animated:YES completion:nil];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (void)_decryptApplicationProxy:(LSApplicationProxy *)application {
    [self _decryptApplicationProxy:application options:TDDecryptionTaskDefaultOptions()];
}

- (void)_decryptApplicationProxy:(LSApplicationProxy *)application options:(TDDecryptionTaskOptions)options {
    NSLog(@"Starting decryption for %@", [application atl_bundleIdentifier]);
    TDDecryptionTask *decryptionTask = [[TDDecryptionTask alloc] initWithApplicationProxy:application];
    decryptionTask.progressHandler = ^(NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_progressAlert) {
                self->_progressAlert.message = message;
                return;
            }

            self->_progressAlert =
                [UIAlertController alertControllerWithTitle:[Localize localizedStringForKey:@"DECRYPTING"]
                                                    message:message
                                            preferredStyle:UIAlertControllerStyleAlert];
            [self presentViewController:self->_progressAlert animated:YES completion:nil];
        });
    };


    [decryptionTask executeWithCompletionHandler:^(BOOL success, NSURL *outputURL, NSError *error) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (_progressAlert) {
                [_progressAlert dismissViewControllerAnimated:YES completion:^{
                    _progressAlert = nil;
                }];
            }

            UIAlertController *resultAlert;
            if (success) {
                resultAlert = [UIAlertController alertControllerWithTitle:[Localize localizedStringForKey:@"SUCCESS"] message:[Localize localizedStringForKey:@"DECRYPTION_COMPLETED"] preferredStyle:UIAlertControllerStyleAlert];
                
                // @iCrazeiOS
                if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"filza://"]]) {
                    [resultAlert addAction:[UIAlertAction actionWithTitle:[Localize localizedStringForKey:@"SHOW_IN_FILZA"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                        NSURL *url = [[NSURL URLWithString:@"filza://view"] URLByAppendingPathComponent:[outputURL path]];
                        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
                    }]];
                }
            } else {
                resultAlert = [UIAlertController alertControllerWithTitle:[Localize localizedStringForKey:@"ERROR"] message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            }
            
            [resultAlert addAction:[UIAlertAction actionWithTitle:[Localize localizedStringForKey:@"OK"] style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:resultAlert animated:YES completion:nil];
        });
    } options:options];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    NSString *q = sc.searchBar.text ?: @"";
    q = [q stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

    static NSString *last = nil;
    if (last && [last isEqualToString:q]) return;   // no-op if same query
    last = [q copy];

    [self _applySearchFilter];
    [self.tableView reloadData];
}

- (void)_applySearchFilter {
    NSString *query = _searchController.searchBar.text ?: @"";
    query = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (query.length == 0) {
        _filteredApplications = _allAvailableApplications ?: @[];
        return;
    }

    _filteredApplications = [_allAvailableApplications filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(LSApplicationProxy *application, NSDictionary *bindings) {
        NSString *name = [[application atl_nameToDisplay] lowercaseString];
        NSString *bundleID = [[application atl_bundleIdentifier] lowercaseString];
        NSString *lowercaseQuery = [query lowercaseString];

        return ([name containsString:lowercaseQuery] || [bundleID containsString:lowercaseQuery]);
    }]];
}

@end
