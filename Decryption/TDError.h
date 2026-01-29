#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, TDErrorCode) {
    TDErrorCodeUnknown = -1,
    TDErrorCodeApplicationBundleCopyFailed,
    TDErrorCodeBinaryDecryptionFailed,
    TDErrorCodeLaunchFailed,
    TDErrorCodeIPAConstructionFailed,
    // ← можно добавить свои коды, если хочешь
    TDErrorCodeAppAlreadyRunning = -100,
    TDErrorCodeDebugServerFailed  = -101,
    TDErrorCodeLLDBConnectionFailed = -102,
    TDErrorCodeLaunchTimeout      = -103,
};

@interface TDError : NSError

+ (nonnull instancetype)errorWithCode:(TDErrorCode)code;
+ (nonnull instancetype)errorWithCode:(TDErrorCode)code description:(nullable NSString *)description;

@end
