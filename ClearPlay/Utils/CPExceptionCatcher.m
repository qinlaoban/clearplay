#import "CPExceptionCatcher.h"

@implementation CPExceptionCatcher

+ (nullable NSError *)catchException:(void (NS_NOESCAPE ^)(void))tryBlock {
    @try {
        tryBlock();
        return nil;
    } @catch (NSException *exception) {
        return [NSError errorWithDomain:@"com.clearplay.app.exception"
                                   code:-1
                               userInfo:@{
            NSLocalizedDescriptionKey: exception.reason ?: exception.name,
            @"ExceptionName": exception.name
        }];
    }
}

@end
