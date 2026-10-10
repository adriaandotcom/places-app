#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Owns one local native matcher. It never receives an HTTP client.
@interface PLPlacesValhalla : NSObject
- (nullable instancetype)initWithConfigPath:(NSString *)configPath
                              timezonePath:(NSString *)timezonePath
                                     error:(NSError **)error;
- (nullable NSString *)traceAttributes:(NSString *)request error:(NSError **)error;
- (void)close;
@end
NS_ASSUME_NONNULL_END
