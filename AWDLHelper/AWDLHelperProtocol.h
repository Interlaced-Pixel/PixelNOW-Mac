#import <Foundation/Foundation.h>

@protocol PixelNOWAWDLHelperProtocol <NSObject>
- (void)checkInWithReply:(void (^)(BOOL accepted))reply;
- (void)setAWDLEnabled:(BOOL)enabled withReply:(void (^)(BOOL accepted))reply;
@end
