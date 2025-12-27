#import "TDUtils.h"
#import "TDDumpDecrypted.h"
#import "LSApplicationProxy+AltList.h"

static NSString *getDebugserverLogPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"debugserver.log"];
}

static NSString *getLLDBLogPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"lldb.log"];
}

UIWindow *alertWindow = NULL;
UIWindow *kw = NULL;
UIViewController *root = NULL;
UIAlertController *alertController = NULL;
UIAlertController *doneController = NULL;
UIAlertController *errorController = NULL;

static pid_t global_debugserver_pid = 0;
static pid_t global_lldb_pid = 0;
static NSString *global_binaryName = nil;

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
        if (pids[i] == 0) { continue; }
        char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
        bzero(pathBuffer, PROC_PIDPATHINFO_MAXSIZE);
        proc_pidpath(pids[i], pathBuffer, sizeof(pathBuffer));

        if (strlen(pathBuffer) > 0) {
            NSString *processID = [[NSString alloc] initWithFormat:@"%d", pids[i]];
            NSString *processName = [[NSString stringWithUTF8String:pathBuffer] lastPathComponent];
            NSDictionary *dict = [[NSDictionary alloc] initWithObjects:[NSArray arrayWithObjects:processID, processName, nil] forKeys:[NSArray arrayWithObjects:@"pid", @"proc_name", nil]];
            
            [array addObject:dict];
        }
    }

    return [array copy];
}

void cleanupDebugger(void){
    if(global_lldb_pid > 0){
        kill(global_lldb_pid,SIGTERM);
        sleep(1);
        if(kill(global_lldb_pid,0) == 0) kill(global_lldb_pid,SIGKILL);
        global_lldb_pid = 0;
    }
    if(global_debugserver_pid > 0){
        kill(global_debugserver_pid,SIGTERM);
        sleep(1);
        if(kill(global_debugserver_pid,0) == 0) kill(global_debugserver_pid,SIGKILL);
        global_debugserver_pid = 0;
    }
    global_binaryName = nil;
}

void decryptApp(NSDictionary *app){
    dispatch_async(dispatch_get_main_queue(),^{
        alertWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        alertWindow.rootViewController = [UIViewController new];
        alertWindow.windowLevel = UIWindowLevelAlert + 1;
        [alertWindow makeKeyAndVisible];
        kw = alertWindow;
        root = kw.rootViewController;
        root.modalPresentationStyle = UIModalPresentationFullScreen;
    });

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0),^{
        NSString *name = app[@"name"];
        NSString *version = app[@"version"];
        NSString *executable = app[@"executable"];
        NSString *binaryName = [executable lastPathComponent];
        global_binaryName = binaryName;

        cleanupDebugger();

        NSLog(@"[trolldecrypt] Starting debugserver localhost:5678 --waitfor \"%@\"",binaryName);

        NSString *escapedName = [binaryName stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
        const int port = 5678;
        const char *debugserver_path = "/var/jb/usr/bin/debugserver-16"; // rootlessJB

        char port_str[32];
        snprintf(port_str,sizeof(port_str),"localhost:%d",port);

        const char *ds_args[] = {"debugserver",port_str,"--waitfor",[escapedName UTF8String],NULL};

        NSString *ds_log = getDebugserverLogPath();
        posix_spawn_file_actions_t ds_actions;
        posix_spawn_file_actions_init(&ds_actions);
        posix_spawn_file_actions_addopen(&ds_actions,STDOUT_FILENO,[ds_log UTF8String],O_WRONLY | O_CREAT | O_TRUNC,0644);
        posix_spawn_file_actions_addopen(&ds_actions,STDERR_FILENO,[ds_log UTF8String],O_WRONLY | O_CREAT | O_APPEND,0644);

        int status = posix_spawn(&global_debugserver_pid,debugserver_path,&ds_actions,NULL,(char *const *)ds_args,NULL);
        posix_spawn_file_actions_destroy(&ds_actions);

        if(status != 0 || global_debugserver_pid <= 0){
            dispatch_async(dispatch_get_main_queue(),^{
                errorController = [UIAlertController alertControllerWithTitle:@"Error" message:@"Failed to start debugserver" preferredStyle:UIAlertControllerStyleAlert];
                [errorController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){ [kw removeFromSuperview]; }]];
                [root presentViewController:errorController animated:YES completion:nil];
            });
            return;
        }

        NSLog(@"[trolldecrypt] debugserver started (PID: %d)",global_debugserver_pid);
        sleep(2);

        NSString *lldb_script = [NSTemporaryDirectory() stringByAppendingPathComponent:@"lldb_connect.txt"];
        NSString *connectCmd = [NSString stringWithFormat:@"process connect connect://localhost:%d\n",port];
        [connectCmd writeToFile:lldb_script atomically:YES encoding:NSUTF8StringEncoding error:nil];

        const char *lldb_path = "/var/jb/usr/bin/lldb"; // rootlessJB
        const char *lldb_args[] = {"lldb","-s",[lldb_script UTF8String],NULL};

        NSString *lldb_log = getLLDBLogPath();
        posix_spawn_file_actions_t lldb_actions;
        posix_spawn_file_actions_init(&lldb_actions);
        posix_spawn_file_actions_addopen(&lldb_actions,STDOUT_FILENO,[lldb_log UTF8String],O_WRONLY | O_CREAT | O_TRUNC,0644);
        posix_spawn_file_actions_addopen(&lldb_actions,STDERR_FILENO,[lldb_log UTF8String],O_WRONLY | O_CREAT | O_APPEND,0644);

        status = posix_spawn(&global_lldb_pid,lldb_path,&lldb_actions,NULL,(char *const *)lldb_args,NULL);
        posix_spawn_file_actions_destroy(&lldb_actions);

        if(status != 0 || global_lldb_pid <= 0){
            kill(global_debugserver_pid,SIGKILL);
            global_debugserver_pid = 0;
            dispatch_async(dispatch_get_main_queue(),^{
                errorController = [UIAlertController alertControllerWithTitle:@"Error" message:@"Failed to connect lldb" preferredStyle:UIAlertControllerStyleAlert];
                [errorController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){ [kw removeFromSuperview]; }]];
                [root presentViewController:errorController animated:YES completion:nil];
            });
            return;
        }

        NSLog(@"[trolldecrypt] lldb connected (PID: %d)",global_lldb_pid);

        dispatch_async(dispatch_get_main_queue(),^{
            alertController = [UIAlertController alertControllerWithTitle:@"Tap the app!"
                                                                  message:[NSString stringWithFormat:@"Now manually open %@.\n\nIt will freeze immediately — this is normal.\nDecryption will start automatically.",name]
                                                           preferredStyle:UIAlertControllerStyleAlert];
            [root presentViewController:alertController animated:YES completion:nil];
        });

        pid_t target_pid = -1;
        int attempts = 60;
        while(attempts-- > 0 && target_pid == -1){
            sleep(1);
            for(NSDictionary *proc in sysctl_ps()){
                if([[proc[@"proc_name"] lastPathComponent] isEqualToString:binaryName]){
                    target_pid = [proc[@"pid"] intValue];
                    NSLog(@"[trolldecrypt] App frozen! PID: %d",target_pid);
                    break;
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(),^{
            [alertController dismissViewControllerAnimated:YES completion:nil];
        });

        if(target_pid == -1){
            cleanupDebugger();
            dispatch_async(dispatch_get_main_queue(),^{
                errorController = [UIAlertController alertControllerWithTitle:@"Timeout" message:@"App not launched or not caught in time" preferredStyle:UIAlertControllerStyleAlert];
                [errorController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){ [kw removeFromSuperview]; }]];
                [root presentViewController:errorController animated:YES completion:nil];
            });
            return;
        }

        char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
        proc_pidpath(target_pid,pathbuf,sizeof(pathbuf));
        NSString *fullPath = [NSString stringWithUTF8String:pathbuf];

        DumpDecrypted *dd = [[DumpDecrypted alloc] initWithPathToBinary:fullPath appName:name appVersion:version];
        if(!dd){
            cleanupDebugger();
            dispatch_async(dispatch_get_main_queue(),^{
                errorController = [UIAlertController alertControllerWithTitle:@"Error" message:@"Failed to initialize dumper" preferredStyle:UIAlertControllerStyleAlert];
                [errorController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){ [kw removeFromSuperview]; }]];
                [root presentViewController:errorController animated:YES completion:nil];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(),^{
            alertController = [UIAlertController alertControllerWithTitle:@"Decrypting..." message:@"Dumping decrypted binary..." preferredStyle:UIAlertControllerStyleAlert];
            [root presentViewController:alertController animated:YES completion:nil];
        });

        [dd createIPAFile:target_pid];

        cleanupDebugger();

        dispatch_async(dispatch_get_main_queue(),^{
            [alertController dismissViewControllerAnimated:YES completion:nil];
            doneController = [UIAlertController alertControllerWithTitle:@"Success!"
                                                                 message:[NSString stringWithFormat:@"Decrypted IPA saved:\n%@", [dd IPAPath]]
                                                          preferredStyle:UIAlertControllerStyleAlert];
            [doneController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){ [kw removeFromSuperview]; }]];
            if([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"filza://"]]){
                [doneController addAction:[UIAlertAction actionWithTitle:@"Open in Filza" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
                    [kw removeFromSuperview];
                    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:[NSString stringWithFormat:@"filza://view%@", [dd IPAPath]]] options:@{} completionHandler:nil];
                }]];
            }
            [root presentViewController:doneController animated:YES completion:nil];
        });
    });
}

NSArray *decryptedFileList(void) {
    NSMutableArray *files = [NSMutableArray array];
    NSMutableArray *fileNames = [NSMutableArray array];

    // iterate through all files in the Documents directory
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDirectoryEnumerator *directoryEnumerator = [fileManager enumeratorAtPath:docPath()];

    NSString *file;
    while (file = [directoryEnumerator nextObject]) {
        if ([[file pathExtension] isEqualToString:@"ipa"]) {
            NSString *filePath = [[docPath() stringByAppendingPathComponent:file] stringByStandardizingPath];

            NSDictionary *fileAttributes = [fileManager attributesOfItemAtPath:filePath error:nil];
            NSDate *modificationDate = fileAttributes[NSFileModificationDate];

            NSDictionary *fileInfo = @{@"fileName": file, @"modificationDate": modificationDate};
            [files addObject:fileInfo];
        }
    }

    // Sort the array based on modification date
    NSArray *sortedFiles = [files sortedArrayUsingComparator:^NSComparisonResult(id obj1, id obj2) {
        NSDate *date1 = [obj1 objectForKey:@"modificationDate"];
        NSDate *date2 = [obj2 objectForKey:@"modificationDate"];
        return [date2 compare:date1];
    }];

    // Get the file names from the sorted array
    for (NSDictionary *fileInfo in sortedFiles) {
        [fileNames addObject:[fileInfo objectForKey:@"fileName"]];
    }

    return [fileNames copy];
}

NSString *docPath(void) {
    NSError * error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Documents/TrollDecrypt/decrypted" withIntermediateDirectories:YES attributes:nil error:&error];
    if (error != nil) {
        NSLog(@"[trolldecrypt] error creating directory: %@", error);
    }

    return @"/var/mobile/Documents/TrollDecrypt/decrypted";
}

void decryptAppWithPID(pid_t pid) {
    // generate App NSDictionary object to pass into decryptApp()
    // proc_pidpath(self.pid, buffer, sizeof(buffer));
    NSString *message = nil;
    NSString *error = nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        alertWindow = [[UIWindow alloc] initWithFrame: [UIScreen mainScreen].bounds];
        alertWindow.rootViewController = [UIViewController new];
        alertWindow.windowLevel = UIWindowLevelAlert + 1;
        [alertWindow makeKeyAndVisible];
        
        // Show a "Decrypting!" alert on the device and block the UI
            
        kw = alertWindow;
        if([kw respondsToSelector:@selector(topmostPresentedViewController)])
            root = [kw performSelector:@selector(topmostPresentedViewController)];
        else
            root = [kw rootViewController];
        root.modalPresentationStyle = UIModalPresentationFullScreen;
    });

    NSLog(@"[trolldecrypt] pid: %d", pid);

    char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
    proc_pidpath(pid, pathbuf, sizeof(pathbuf));

    NSString *executable = [NSString stringWithUTF8String:pathbuf];
    NSString *path = [executable stringByDeletingLastPathComponent];
    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
    NSString *bundleID = infoPlist[@"CFBundleIdentifier"];

    if (!bundleID) {
        error = @"Error: -2";
        message = [NSString stringWithFormat:@"Failed to get bundle id for pid: %d", pid];
    }

    LSApplicationProxy *app = [LSApplicationProxy applicationProxyForIdentifier:bundleID];
    if (!app) {
        error = @"Error: -3";
        message = [NSString stringWithFormat:@"Failed to get LSApplicationProxy for bundle id: %@", bundleID];
    }

    if (message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [alertController dismissViewControllerAnimated:NO completion:nil];
            NSLog(@"[trolldecrypt] failed to get bundleid for pid: %d", pid);

            errorController = [UIAlertController alertControllerWithTitle:error message:message preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction *okAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Ok", @"Ok") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                NSLog(@"[trolldecrypt] Ok action");
                [errorController dismissViewControllerAnimated:NO completion:nil];
                [kw removeFromSuperview];
                kw.hidden = YES;
            }];

            [errorController addAction:okAction];
            [root presentViewController:errorController animated:YES completion:nil];
        });
    }

    NSLog(@"[trolldecrypt] app: %@", app);

    NSDictionary *appInfo = @{
        @"bundleID":bundleID,
        @"name":[app atl_nameToDisplay],
        @"version":[app atl_shortVersionString],
        @"executable":executable
    };

    NSLog(@"[trolldecrypt] appInfo: %@", appInfo);

    dispatch_async(dispatch_get_main_queue(), ^{
        [alertController dismissViewControllerAnimated:NO completion:nil];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Decrypt" message:[NSString stringWithFormat:@"Decrypt %@?", appInfo[@"name"]] preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
        UIAlertAction *decrypt = [UIAlertAction actionWithTitle:@"Yes" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            decryptApp(appInfo);
        }];

        [alert addAction:decrypt];
        [alert addAction:cancel];
        
        [root presentViewController:alert animated:YES completion:nil];
    });
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
