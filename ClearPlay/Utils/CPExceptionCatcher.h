#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 捕获 ObjC 异常（Swift 无法 catch NSException，
/// 用于安全探测 CKContainer(identifier:) —— 无 entitlement 时它会直接抛异常）
@interface CPExceptionCatcher : NSObject

/// 执行 tryBlock；抛出 NSException 时转换为 NSError 返回，否则返回 nil
+ (nullable NSError *)catchException:(void (NS_NOESCAPE ^_Nonnull)(void))tryBlock;

@end

NS_ASSUME_NONNULL_END
