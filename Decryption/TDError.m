#import "TDError.h"

@implementation TDError

+ (instancetype)errorWithCode:(TDErrorCode)code {
    return [self errorWithCode:code description:nil];
}

+ (instancetype)errorWithCode:(TDErrorCode)code description:(nullable NSString *)description {
    NSString *defaultDesc = [self descriptionForErrorCode:code];
    NSString *finalDesc = description ?: defaultDesc;

    NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: finalDesc };
    return [super errorWithDomain:@"com.fiore.TDError" code:code userInfo:userInfo];
}

+ (NSString *)descriptionForErrorCode:(TDErrorCode)code {
    switch (code) {
        case TDErrorCodeApplicationBundleCopyFailed:
            return @"Application bundle copy failed";
        case TDErrorCodeBinaryDecryptionFailed:
            return @"Binary decryption failed";
        case TDErrorCodeLaunchFailed:
            return @"Application launch failed";
        case TDErrorCodeIPAConstructionFailed:
            return @"IPA construction failed";
        case TDErrorCodeAppAlreadyRunning:
            return @"Приложение уже запущено — закройте его полностью";
        case TDErrorCodeDebugServerFailed:
            return @"Не удалось запустить debugserver";
        case TDErrorCodeLLDBConnectionFailed:
            return @"Не удалось подключить lldb";
        case TDErrorCodeLaunchTimeout:
            return @"Таймаут — приложение не запустилось за отведённое время";
        case TDErrorCodeUnknown:
        default:
            return @"Неизвестная ошибка";
    }
}

@end
