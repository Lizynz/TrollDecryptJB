#import <UIKit/UIKit.h>
#import <spawn.h>
#import <signal.h>
#import <sys/sysctl.h>
#import <errno.h>
#import <string.h>
#import <mach/mach_error.h>

#import "TDDecryptionTask.h"
#import "TDError.h"
#import "Extensions/LSApplicationProxy+AltList.h"
#import "Localize.h"
#import "LaunchdResponse.h"
#import "MemoryUtilities.h"
#import <objc/runtime.h>
#import <SSZipArchive/SSZipArchive.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import "Extensions/LSBundleProxy+TrollDecrypt.h"

static pid_t g_debugserver_pid = 0;
static pid_t g_lldb_pid = 0;

static NSString *getDebugserverLogPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"td_debugserver.log"];
}

static NSString *getLLDBLogPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"td_lldb.log"];
}

static void cleanupDebugger(void) {
    if (g_lldb_pid > 0) {
        kill(g_lldb_pid, SIGTERM);
        usleep(800000);
        if (kill(g_lldb_pid, 0) == 0) kill(g_lldb_pid, SIGKILL);
        g_lldb_pid = 0;
    }
    if (g_debugserver_pid > 0) {
        kill(g_debugserver_pid, SIGTERM);
        usleep(800000);
        if (kill(g_debugserver_pid, 0) == 0) kill(g_debugserver_pid, SIGKILL);
        g_debugserver_pid = 0;
    }
}

static void launchApp(NSString *bundleID) {
    Class LSApplicationWorkspace = objc_getClass("LSApplicationWorkspace");
    id workspace = [LSApplicationWorkspace performSelector:@selector(defaultWorkspace)];
    [workspace performSelector:@selector(openApplicationWithBundleID:) withObject:bundleID];
}

static void returnToDecryptor(void) {
    launchApp(@"com.fiore.trolldecrypt");
}

TDDecryptionTaskOptions TDDecryptionTaskOptionsMake(bool decryptBinaryOnly) {
    TDDecryptionTaskOptions options = {0};
    options.decryptBinaryOnly = decryptBinaryOnly;
    return options;
}

TDDecryptionTaskOptions TDDecryptionTaskDefaultOptions(void) {
    return TDDecryptionTaskOptionsMake(false);
}

@interface TDDecryptionTask ()

- (BOOL)createOutputDirectoryIfNeeded;
- (BOOL)_copyApplicationBundle;
- (BOOL)_buildIPAWithName:(NSString *)ipaName;

- (BOOL)decryptImageAtPath:(NSString *)imagePath forPID:(pid_t)pid;
- (BOOL)decryptImageAtPath:(NSString *)imagePath forPID:(pid_t)pid outputPath:(NSString *)outputPath;

- (BOOL)startDebugserverForBinary:(NSString *)binaryName;
- (BOOL)startAndConnectLLDB;
- (pid_t)waitForNewProcess:(NSString *)binaryName timeout:(int)seconds;
- (BOOL)isProcessRunning:(NSString *)binaryName;
- (NSArray *)runningProcesses;

@end

@implementation TDDecryptionTask {
    NSFileManager *_fileManager;
    NSString *_workingDirectoryPath;
    NSString *_destinationPath;
}

- (instancetype)initWithApplicationProxy:(LSApplicationProxy *)application {
    self = [super init];
    if (self) {
        _applicationProxy = application;
        _fileManager = [NSFileManager defaultManager];
    }
    return self;
}

- (void)executeWithCompletionHandler:(void (^)(BOOL success, NSURL *outputURL, NSError *error))completionHandler {
    [self executeWithCompletionHandler:completionHandler options:TDDecryptionTaskDefaultOptions()];
}

- (void)executeWithCompletionHandler:(void (^)(BOOL success, NSURL *outputURL, NSError *error))completionHandler
                             options:(TDDecryptionTaskOptions)options {

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{

        NSString *bundleID = self->_applicationProxy.bundleIdentifier;
        NSString *displayName = [self->_applicationProxy atl_nameToDisplay] ?: bundleID;
        NSString *binaryName = self->_applicationProxy.td_canonicalExecutablePath.lastPathComponent;

        void (^progress)(NSString *) = ^(NSString *msg) {
            if (!self->_progressHandler) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_progressHandler(msg);
            });
        };

        if (![self createOutputDirectoryIfNeeded]) {
            NSError *err = [TDError errorWithCode:TDErrorCodeUnknown];
            dispatch_async(dispatch_get_main_queue(), ^{ if (completionHandler) completionHandler(NO, nil, err); });
            return;
        }

        if ([self isProcessRunning:binaryName]) {
            NSError *err = [TDError errorWithCode:TDErrorCodeUnknown];
            dispatch_async(dispatch_get_main_queue(), ^{ if (completionHandler) completionHandler(NO, nil, err); });
            return;
        }

        if (![self startDebugserverForBinary:binaryName]) {
            cleanupDebugger();
            NSError *err = [TDError errorWithCode:TDErrorCodeUnknown];
            dispatch_async(dispatch_get_main_queue(), ^{ if (completionHandler) completionHandler(NO, nil, err); });
            return;
        }

        if (![self startAndConnectLLDB]) {
            cleanupDebugger();
            NSError *err = [TDError errorWithCode:TDErrorCodeUnknown];
            dispatch_async(dispatch_get_main_queue(), ^{ if (completionHandler) completionHandler(NO, nil, err); });
            return;
        }

        progress([NSString stringWithFormat:
                  [Localize localizedStringForKey:@"CONNECTING_TO_APP"],
                  displayName]);
        
        sleep(10);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            launchApp(bundleID);
        });

        pid_t targetPID = [self waitForNewProcess:binaryName timeout:60];
        if (targetPID <= 0) {
            cleanupDebugger();
            NSError *err = [TDError errorWithCode:TDErrorCodeLaunchFailed];
            dispatch_async(dispatch_get_main_queue(), ^{ if (completionHandler) completionHandler(NO, nil, err); });
            return;
        }

        NSString *imagePath = self->_applicationProxy.td_canonicalExecutablePath;
        BOOL success = NO;
        NSURL *resultURL = nil;

        if (options.decryptBinaryOnly) {
            NSString *fname = [NSString stringWithFormat:@"%@_decrypted_%@",
                               binaryName, self->_applicationProxy.atl_shortVersionString];
            NSString *outPath = [ROOT_OUTPUT_PATH stringByAppendingPathComponent:fname];

            success = [self decryptImageAtPath:imagePath forPID:targetPID outputPath:outPath];
            if (success) resultURL = [NSURL fileURLWithPath:outPath];
        } else {
            progress([Localize localizedStringForKey:@"COPYING_BUNDLE"]);
            if (![self _copyApplicationBundle]) goto fail;

            success = [self decryptImageAtPath:imagePath forPID:targetPID];
            if (!success) goto fail;

            NSInteger i = 0;
            for (LSPlugInKitProxy *ext in self->_applicationProxy.plugInKitPlugins) {
                i++;
                progress([NSString stringWithFormat:@"Decrypting extension %ld/%lu…", (long)i, (unsigned long)self->_applicationProxy.plugInKitPlugins.count]);

                LaunchdResponse_t r = [ext td_launchProcess];
                if (r.pid > 0) {
                    [self decryptImageAtPath:[ext td_canonicalExecutablePath] forPID:r.pid];
                    kill(r.pid, SIGKILL);
                }
            }

            progress([Localize localizedStringForKey:@"BUILDING_IPA"]);
            NSString *ipaName = [NSString stringWithFormat:@"%@_decrypted_%@.ipa",
                                 bundleID, self->_applicationProxy.atl_shortVersionString];

            if ([self _buildIPAWithName:ipaName]) {
                NSString *p = [ROOT_OUTPUT_PATH stringByAppendingPathComponent:ipaName];
                resultURL = [NSURL fileURLWithPath:p];
                success = YES;
            }
        }

    fail:
        if (targetPID > 0) {
            kill(targetPID, SIGCONT);
        }

        cleanupDebugger();
        
        dispatch_async(dispatch_get_main_queue(), ^{
            returnToDecryptor();
        });

        if (success) {
            progress([Localize localizedStringForKey:@"DECRYPTION_COMPLETED"]);

            UIAlertController *successAlert =
                [UIAlertController alertControllerWithTitle:
                    [Localize localizedStringForKey:@"SUCCESS"]
                                                    message:nil
                                             preferredStyle:UIAlertControllerStyleAlert];

            [successAlert addAction:
                [UIAlertAction actionWithTitle:
                    [Localize localizedStringForKey:@"OK"]
                                          style:UIAlertActionStyleDefault
                                        handler:nil]];

            if (resultURL &&
                [[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"filza://"]]) {
                
                [successAlert addAction:
                 [UIAlertAction actionWithTitle:
                  [Localize localizedStringForKey:@"SHOW_IN_FILZA"]
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction * _Nonnull action) {
                    
                    NSURL *url = [NSURL URLWithString:
                                  [@"filza://view" stringByAppendingString:resultURL.path]];
                    if (url) {
                        [[UIApplication sharedApplication] openURL:url
                                                           options:@{}
                                                 completionHandler:nil];
                    }
                }]];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completionHandler) completionHandler(YES, resultURL, nil);
            });
        } else {
            NSError *err = [TDError errorWithCode:TDErrorCodeBinaryDecryptionFailed];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completionHandler) completionHandler(NO, nil, err);
            });
        }
    });
}

- (BOOL)startDebugserverForBinary:(NSString *)binaryName {
    const char *ds_path = "/var/jb/usr/bin/debugserver-16"; // rootlessJB
    int port = 5678; // debugserver port, you can change it if needed

    char port_str[32];
    snprintf(port_str, sizeof(port_str), "localhost:%d", port);

    const char *ds_args[] = {
        "debugserver",
        port_str,
        "--waitfor",
        binaryName.UTF8String,
        NULL
    };

    NSString *log = getDebugserverLogPath();
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, log.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);

    int stat = posix_spawn(&g_debugserver_pid, ds_path, &actions, NULL, (char *const *)ds_args, NULL);
    posix_spawn_file_actions_destroy(&actions);

    if (stat != 0 || g_debugserver_pid <= 0) return NO;

    usleep(600 * 1000);
    return YES;
}

- (BOOL)startAndConnectLLDB {
    const char *lldb_path = "/var/jb/usr/bin/lldb"; // rootlessJB

    NSString *scriptPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"td_lldb_connect.txt"];
    NSString *script = @"process connect connect://localhost:5678\n";
    [script writeToFile:scriptPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    const char *l_args[] = { "lldb", "-s", scriptPath.UTF8String, NULL };

    NSString *log = getLLDBLogPath();
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, log.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);

    int stat = posix_spawn(&g_lldb_pid, lldb_path, &actions, NULL, (char *const *)l_args, NULL);
    posix_spawn_file_actions_destroy(&actions);

    return (stat == 0 && g_lldb_pid > 0);
}

- (pid_t)waitForNewProcess:(NSString *)binaryName timeout:(int)seconds {
    NSMutableSet *oldPIDs = [NSMutableSet set];

    NSArray *procs = [self runningProcesses];
    for (NSDictionary *p in procs) {
        if ([[p[@"proc_name"] lastPathComponent] isEqualToString:binaryName]) {
            [oldPIDs addObject:p[@"pid"]];
        }
    }

    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];

    while ([[NSDate date] compare:end] == NSOrderedAscending) {
        procs = [self runningProcesses];
        for (NSDictionary *p in procs) {
            if ([[p[@"proc_name"] lastPathComponent] isEqualToString:binaryName]) {
                NSString *pidStr = p[@"pid"];
                if (![oldPIDs containsObject:pidStr]) {
                    return pidStr.intValue;
                }
            }
        }
        sleep(1);
    }
    return -1;
}

- (BOOL)isProcessRunning:(NSString *)binaryName {
    NSArray *procs = [self runningProcesses];
    for (NSDictionary *p in procs) {
        if ([[p[@"proc_name"] lastPathComponent] isEqualToString:binaryName]) return YES;
    }
    return NO;
}

- (NSArray *)runningProcesses {
    NSMutableArray *processes = [NSMutableArray array];

    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t needed = 0;

    if (sysctl(mib, 4, NULL, &needed, NULL, 0) == -1) {
        NSLog(@"[TDDecryptionTask] sysctl size failed: %s", strerror(errno));
        return @[];
    }

    struct kinfo_proc *procList = malloc(needed);
    if (!procList) {
        NSLog(@"[TDDecryptionTask] malloc failed");
        return @[];
    }

    if (sysctl(mib, 4, procList, &needed, NULL, 0) == -1) {
        NSLog(@"[TDDecryptionTask] sysctl data failed: %s", strerror(errno));
        free(procList);
        return @[];
    }

    int count = (int)(needed / sizeof(struct kinfo_proc));

    for (int i = 0; i < count; i++) {
        struct kinfo_proc *proc = &procList[i];
        pid_t pid = proc->kp_proc.p_pid;
        if (pid <= 0) continue;

        NSString *name = [NSString stringWithUTF8String:proc->kp_proc.p_comm];
        if (name.length == 0) continue;

        [processes addObject:@{
            @"pid": @(pid).stringValue,
            @"proc_name": name
        }];
    }

    free(procList);
    return processes;
}

- (BOOL)decryptImageAtPath:(NSString *)imagePath forPID:(pid_t)pid {
    NSString *delimeter = [_destinationPath lastPathComponent];
    NSString *rhs = [imagePath componentsSeparatedByString:delimeter].lastObject;
    NSString *outputPath = [_destinationPath stringByAppendingString:rhs];

    NSString *scInfoPath = [[outputPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"SC_Info"];
    if ([_fileManager fileExistsAtPath:scInfoPath]) {
        NSError *removeError = nil;
        NSLog(@"Removing SC_Info at path: %@", scInfoPath);
        [_fileManager removeItemAtPath:scInfoPath error:&removeError];
        if (removeError) {
            NSLog(@"failed to remove existing SC_Info at path %@, error: %@", scInfoPath, removeError);
            return NO;
        }
    }

    return [self decryptImageAtPath:imagePath forPID:pid outputPath:outputPath];
}

- (BOOL)decryptImageAtPath:(NSString *)imagePath forPID:(pid_t)pid outputPath:(NSString *)outputPath {
    vm_map_t task = 0;
    if (task_for_pid(mach_task_self(), pid, &task)) {
        NSLog(@"failed to get task for pid %d", pid);
        return NO;
    }

    MainImageInfo_t mainImageInfo = imageInfoForPIDWithRetry([imagePath UTF8String], task, pid);
    if (!mainImageInfo.ok) {
        NSLog(@"failed to get main image load address for pid %d", pid);
        return NO;
    }

    NSLog(@"main image info: %@", NSStringFromMainImageInfo(mainImageInfo));

    struct encryption_info_command encryptionInfo = {0};
    uint64_t loadCommandAddress = 0;
    if (!readEncryptionInfo(task, mainImageInfo.loadAddress, &encryptionInfo, &loadCommandAddress)) {
        NSLog(@"failed to read encryption info for pid %d", pid);
        return NO;
    }

    NSLog(@"encryption info: cryptoff=0x%x cryptsize=0x%x cryptid=%d",
          encryptionInfo.cryptoff, encryptionInfo.cryptsize, encryptionInfo.cryptid);
    
    if (encryptionInfo.cryptid == 0) {
        NSLog(@"image is not encrypted");
        return YES;
    }

    if (!rebuildDecryptedImageAtPath(imagePath, task, mainImageInfo.loadAddress, &encryptionInfo, loadCommandAddress, outputPath)) {
        NSLog(@"failed to rebuild decrypted image for pid %d", pid);
        return NO;
    }

    return YES;
}

- (BOOL)_buildIPAWithName:(NSString *)ipaName {
    NSString *ipaPath = [ROOT_OUTPUT_PATH stringByAppendingPathComponent:ipaName];

    NSError *error = nil;
    if ([_fileManager fileExistsAtPath:ipaPath]) {
        [_fileManager removeItemAtPath:ipaPath error:&error];
        if (error) {
            NSLog(@"Failed to remove existing IPA at path %@, error: %@", ipaPath, error);
            return NO;
        }
    }

    NSDate *methodStart = [NSDate date];
    NSLog(@"Zipping IPA to path: %@", ipaPath);
    NSLog(@"_workingDirectoryPath: %@", _workingDirectoryPath);

    BOOL success = [SSZipArchive createZipFileAtPath:ipaPath withContentsOfDirectory:_workingDirectoryPath];
    if (!success) {
        NSLog(@"failed to create zip archive at path: %@", ipaPath);
        return NO;
    }

    NSTimeInterval methodEnd = -[methodStart timeIntervalSinceNow];
    NSLog(@"Zipping IPA took %.3f seconds", methodEnd);

    NSLog(@"Successfully created IPA at path %@", ipaPath);

    NSError *cleanupError = nil;
    [_fileManager removeItemAtPath:_workingDirectoryPath error:&cleanupError];
    if (cleanupError) {
        NSLog(@"failed to clean up working directory: %@, error: %@", _workingDirectoryPath, cleanupError);
        return NO;
    }

    NSLog(@"Successfully created IPA at path %@", ipaPath);
    return YES;
}

- (BOOL)createOutputDirectoryIfNeeded {
    BOOL isDirectory = NO;
    if ([_fileManager fileExistsAtPath:ROOT_OUTPUT_PATH isDirectory:&isDirectory]) {
        return isDirectory;
    }

    NSError *error = nil;
    [_fileManager createDirectoryAtPath:ROOT_OUTPUT_PATH withIntermediateDirectories:YES attributes:nil error:&error];
    if (error) {
        NSLog(@"Error creating output directory: %@", error);
        return NO;
    }

    return YES;
}

- (BOOL)_copyApplicationBundle {
    NSString *workingPath = [ROOT_OUTPUT_PATH stringByAppendingPathComponent:@".work"];

    NSError *error = nil;
    if ([_fileManager fileExistsAtPath:workingPath]) {
        [_fileManager removeItemAtPath:workingPath error:&error];
        if (error) {
            NSLog(@"Failed to remove existing working directory: %@, error: %@", workingPath, error);
            return NO;
        }
    }

    NSString *payloadPath = [workingPath stringByAppendingPathComponent:@"Payload"];

    NSError *copyError = nil;
    [_fileManager createDirectoryAtPath:payloadPath withIntermediateDirectories:YES attributes:nil error:&copyError];
    if (copyError) {
        NSLog(@"Failed to create Payload directory: %@, error: %@", payloadPath, copyError);
        return NO;
    }

    _destinationPath = [payloadPath stringByAppendingPathComponent:[_applicationProxy.bundleURL lastPathComponent]];
    copyError = nil;
    [_fileManager copyItemAtURL:_applicationProxy.bundleURL toURL:[NSURL fileURLWithPath:_destinationPath] error:&copyError];
    if (copyError) {
        NSLog(@"Failed to copy application bundle to %@, error: %@", _destinationPath, copyError);
        return NO;
    }

    _workingDirectoryPath = workingPath;
    return YES;
}

@end
