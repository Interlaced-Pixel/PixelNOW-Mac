#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AWDLMonitor : NSObject

- (nullable instancetype)init;
- (void)setAwdlEnabled:(BOOL)enabled;
- (void)restoreAndStop;

@end

NS_ASSUME_NONNULL_END
