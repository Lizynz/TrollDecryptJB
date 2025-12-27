#import "TDUtils.h"
#import "TDDumpDecrypted.h"
#import "LSApplicationProxy+AltList.h"

static NSString *getDebugserverLogPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"debugserver.log"];
}

static NSString *getLLDBLogPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"lldb.log"];
}

static pid_t global_debugserver_pid = 0;
static pid_t global_lldb_pid = 0;
static NSString *global_binaryName = nil;

static UIWindow *overlayWindow = nil;

static void showOverlayAlert(UIAlertController *alert) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!overlayWindow) {
            overlayWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            overlayWindow.windowLevel = UIWindowLevelAlert + 100;
            overlayWindow.backgroundColor = [UIColor clearColor];
            UIViewController *vc = [UIViewController new];
            vc.modalPresentationStyle = UIModalPresentationFullScreen;
            overlayWindow.rootViewController = vc;
        }
        
        [overlayWindow.rootViewController dismissViewControllerAnimated:NO completion:nil];
        [overlayWindow makeKeyAndVisible];
        [overlayWindow.rootViewController presentViewController:alert animated:YES completion:nil];
    });
}

static void hideOverlayWindow(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (overlayWindow) {
            [overlayWindow.rootViewController dismissViewControllerAnimated:NO completion:nil];
            overlayWindow.hidden = YES;
            overlayWindow = nil;
        }
    });
}

NSArray *appList(void) {
    NSMutableArray *apps = [NSMutableArray array];

    NSArray <LSApplicationProxy *> *installedApplications = [[LSApplicationWorkspace defaultWorkspace] atl_allInstalledApplications];
    [installedApplications enumerateObjectsUsingBlock:^(LSApplicationProxy *proxy, NSUInteger idx, BOOL *stop) {
        if (![proxy atl_isUserApplication]) return;

        NSString *bundleID = [proxy atl_bundleIdentifier];
        NSString *name = [proxy atl_nameToDisplay];
        NSString *version = [proxy atl_shortVersionString];
        NSString *executable = proxy.canonicalExecutablePath;

        if (!bundleID || !name || !version || !executable) return;

        NSDictionary *item = @{
            @"bundleID":bundleID,
            @"name":name,
            @"version":version,
            @"executable":executable
        };

        [apps addObject:item];
    }];

    NSSortDescriptor *descriptor = [[NSSortDescriptor alloc] initWithKey:@"name" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)];
    [apps sortUsingDescriptors:@[descriptor]];

    [apps addObject:@{@"bundleID":@"", @"name":@"", @"version":@"", @"executable":@""}];

    return [apps copy];
}

NSUInteger iconFormat(void) {
    return (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) ? 8 : 10;
}

NSArray *sysctl_ps(void) {
    NSMutableArray *array = [[NSMutableArray alloc] init];

    int numberOfProcesses = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    pid_t pids[numberOfProcesses];
    bzero(pids, sizeof(pids));
    proc_listpids(PROC_ALL_PIDS, 0, pids, sizeof(pids));
    for (int i = 0; i < numberOfProcesses; ++i) {
        if (pids[i] == 0) continue;
        char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
        bzero(pathBuffer, PROC_PIDPATHINFO_MAXSIZE);
        if (proc_pidpath(pids[i], pathBuffer, sizeof(pathBuffer)) > 0) {
            NSString *processID = @(pids[i]).stringValue;
            NSString *processName = [[NSString stringWithUTF8String:pathBuffer] lastPathComponent];
            NSDictionary *dict = @{@"pid": processID, @"proc_name": processName};
            [array addObject:dict];
        }
    }

    return [array copy];
}

void cleanupDebugger(void) {
    if (global_lldb_pid > 0) {
        kill(global_lldb_pid, SIGTERM);
        sleep(1);
        if (kill(global_lldb_pid, 0) == 0) kill(global_lldb_pid, SIGKILL);
        global_lldb_pid = 0;
    }
    if (global_debugserver_pid > 0) {
        kill(global_debugserver_pid, SIGTERM);
        sleep(1);
        if (kill(global_debugserver_pid, 0) == 0) kill(global_debugserver_pid, SIGKILL);
        global_debugserver_pid = 0;
    }
    global_binaryName = nil;
}

void decryptApp(NSDictionary *app) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{

        NSString *name       = app[@"name"];
        NSString *version    = app[@"version"];
        NSString *executable = app[@"executable"];
        NSString *binaryName = executable.lastPathComponent;
        global_binaryName = binaryName;

        cleanupDebugger();

        NSLog(@"[trolldecrypt] Starting debugserver for %@", binaryName);

        const int port = 5678;
        const char *debugserver_path = "/var/jb/usr/bin/debugserver-16"; // rootlessJB

        char port_str[32];
        snprintf(port_str, sizeof(port_str), "localhost:%d", port);

        const char *ds_args[] = {
            "debugserver",
            port_str,
            "--waitfor",
            binaryName.UTF8String,
            NULL
        };

        NSString *ds_log = getDebugserverLogPath();
        posix_spawn_file_actions_t ds_actions;
        posix_spawn_file_actions_init(&ds_actions);
        posix_spawn_file_actions_addopen(&ds_actions,STDOUT_FILENO,[ds_log UTF8String],O_WRONLY | O_CREAT | O_TRUNC,0644);
        posix_spawn_file_actions_addopen(&ds_actions,STDERR_FILENO,[ds_log UTF8String],O_WRONLY | O_CREAT | O_APPEND,0644);

        int status = posix_spawn(&global_debugserver_pid, debugserver_path, &ds_actions, NULL, (char *const *)ds_args, NULL);
        posix_spawn_file_actions_destroy(&ds_actions);

        if (status != 0 || global_debugserver_pid <= 0) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error"
                                                                           message:@"Failed to start debugserver"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { hideOverlayWindow(); }]];
            showOverlayAlert(alert);
            return;
        }

        usleep(500 * 1000);

        NSString *lldb_script = [NSTemporaryDirectory() stringByAppendingPathComponent:@"lldb.txt"];
        NSString *script = [NSString stringWithFormat:@"process connect connect://localhost:%d\n", port];
        [script writeToFile:lldb_script atomically:YES encoding:NSUTF8StringEncoding error:nil];

        const char *lldb_path = "/var/jb/usr/bin/lldb"; // rootlessJB
        const char *lldb_args[] = {"lldb", "-s", lldb_script.UTF8String, NULL};

        NSString *lldb_log = getLLDBLogPath();
        posix_spawn_file_actions_t lldb_actions;
        posix_spawn_file_actions_init(&lldb_actions);
        posix_spawn_file_actions_addopen(&lldb_actions,STDOUT_FILENO,[lldb_log UTF8String],O_WRONLY | O_CREAT | O_TRUNC,0644);
        posix_spawn_file_actions_addopen(&lldb_actions,STDERR_FILENO,[lldb_log UTF8String],O_WRONLY | O_CREAT | O_APPEND,0644);

        status = posix_spawn(&global_lldb_pid, lldb_path, &lldb_actions, NULL, (char *const *)lldb_args, NULL);
        posix_spawn_file_actions_destroy(&lldb_actions);

        if (status != 0 || global_lldb_pid <= 0) {
            cleanupDebugger();
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error"
                                                                           message:@"Failed to connect lldb"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { hideOverlayWindow(); }]];
            showOverlayAlert(alert);
            return;
        }
        
        UIAlertController *tapAlert = [UIAlertController alertControllerWithTitle:@"Tap the app!"
                                                                          message:[NSString stringWithFormat:@"Open %@ now.\n\nIt will freeze — this is normal.\nDecryption will start automatically.", name]
                                                                   preferredStyle:UIAlertControllerStyleAlert];
        showOverlayAlert(tapAlert);

        pid_t target_pid = -1;
        for (int i = 0; i < 60 && target_pid == -1; i++) {
            sleep(1);
            for (NSDictionary *proc in sysctl_ps()) {
                NSString *procName = [proc[@"proc_name"] lastPathComponent];
                if ([procName isEqualToString:binaryName]) {
                    target_pid = [proc[@"pid"] intValue];
                    break;
                }
            }
        }

        if (target_pid <= 0) {
            cleanupDebugger();
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Timeout"
                                                                           message:@"App not launched in time"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { hideOverlayWindow(); }]];
            showOverlayAlert(alert);
            return;
        }

        char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
        proc_pidpath(target_pid, pathbuf, sizeof(pathbuf));
        NSString *fullPath = [NSString stringWithUTF8String:pathbuf];

        DumpDecrypted *dd = [[DumpDecrypted alloc] initWithPathToBinary:fullPath appName:name appVersion:version];
        if (!dd) {
            cleanupDebugger();
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error"
                                                                           message:@"Failed to init dumper"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { hideOverlayWindow(); }]];
            showOverlayAlert(alert);
            return;
        }

        UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"Decrypting…"
                                                                               message:@"Dumping decrypted binary..."
                                                                        preferredStyle:UIAlertControllerStyleAlert];
        showOverlayAlert(progressAlert);

        [dd createIPAFile:target_pid];

        kill(target_pid, SIGCONT);
        cleanupDebugger();

        UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"Success!"
                                                                              message:[NSString stringWithFormat:@"Saved:\n%@", dd.IPAPath]
                                                                       preferredStyle:UIAlertControllerStyleAlert];
        [successAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { hideOverlayWindow(); }]];

        if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"filza://"]]) {
            [successAlert addAction:[UIAlertAction actionWithTitle:@"Open in Filza" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                hideOverlayWindow();
                [[UIApplication sharedApplication] openURL:[NSURL URLWithString:[NSString stringWithFormat:@"filza://view%@", dd.IPAPath]] options:@{} completionHandler:nil];
            }]];
        }

        showOverlayAlert(successAlert);
    });
}

NSArray *decryptedFileList(void) {
    NSMutableArray *fileNames = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = docPath();
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:path];

    for (NSString *file in enumerator) {
        if ([[file pathExtension] isEqualToString:@"ipa"]) {
            [fileNames addObject:file];
        }
    }

    NSArray *sorted = [fileNames sortedArrayUsingComparator:^NSComparisonResult(NSString *f1, NSString *f2) {
        NSString *p1 = [path stringByAppendingPathComponent:f1];
        NSString *p2 = [path stringByAppendingPathComponent:f2];
        NSDate *d1 = [fm attributesOfItemAtPath:p1 error:nil][NSFileModificationDate];
        NSDate *d2 = [fm attributesOfItemAtPath:p2 error:nil][NSFileModificationDate];
        return [d2 compare:d1];
    }];

    return sorted;
}

NSString *docPath(void) {
    NSString *path = @"/var/mobile/Documents/TrollDecrypt/decrypted";
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}

void decryptAppWithPID(pid_t pid) {
    char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
    proc_pidpath(pid, pathbuf, sizeof(pathbuf));

    NSString *executable = [NSString stringWithUTF8String:pathbuf];
    NSString *path = [executable stringByDeletingLastPathComponent];
    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
    NSString *bundleID = infoPlist[@"CFBundleIdentifier"];

    if (!bundleID) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error"
                                                                       message:[NSString stringWithFormat:@"Failed to get bundle ID for PID: %d", pid]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            hideOverlayWindow();
        }]];
        showOverlayAlert(alert);
        return;
    }

    LSApplicationProxy *proxy = [LSApplicationProxy applicationProxyForIdentifier:bundleID];
    if (!proxy) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error"
                                                                       message:[NSString stringWithFormat:@"No app found with bundle ID: %@", bundleID]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            hideOverlayWindow();
        }]];
        showOverlayAlert(alert);
        return;
    }

    NSDictionary *appInfo = @{
        @"bundleID": bundleID,
        @"name": [proxy atl_nameToDisplay],
        @"version": [proxy atl_shortVersionString],
        @"executable": executable
    };
    
    UIAlertController *confirmAlert = [UIAlertController alertControllerWithTitle:@"Decrypt"
                                                                          message:[NSString stringWithFormat:@"Decrypt %@?", appInfo[@"name"]]
                                                                   preferredStyle:UIAlertControllerStyleAlert];

    [confirmAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        hideOverlayWindow();
    }]];

    [confirmAlert addAction:[UIAlertAction actionWithTitle:@"Yes" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        hideOverlayWindow();
        decryptApp(appInfo);
    }]];

    showOverlayAlert(confirmAlert);
}

// void github_fetchLatedVersion(NSString *repo, void (^completionHandler)(NSString *latestVersion)) {
//     NSString *urlString = [NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", repo];
//     NSURL *url = [NSURL URLWithString:urlString];

//     NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
//         if (!error) {
//             if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
//                 NSError *jsonError;
//                 NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];

//                 if (!jsonError) {
//                     NSString *version = [json[@"tag_name"] stringByReplacingOccurrencesOfString:@"v" withString:@""];
//                     completionHandler(version);
//                 }
//             }
//         }
//     }];

//     [task resume];
// }

void fetchLatestTrollDecryptVersion(void (^completionHandler)(NSString *version)) {
    //github_fetchLatedVersion(@"donato-fiore/TrollDecrypt", completionHandler);
}

NSString *trollDecryptVersion(void) {
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
}
