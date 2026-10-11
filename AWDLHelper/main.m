#import <Foundation/Foundation.h>
#import <os/log.h>

#import "AWDLHelperProtocol.h"
#import "AWDLMonitor.h"

@interface AWDLHelperService : NSObject <PixelNOWAWDLHelperProtocol, NSXPCListenerDelegate>
@property(nonatomic, strong) AWDLMonitor *monitor;
@property(nonatomic, assign) BOOL isExiting;
@end

@implementation AWDLHelperService

- (instancetype)init {
    self = [super init];
    if (self) {
        _monitor = [AWDLMonitor new];
    }
    return self;
}

- (void)checkInWithReply:(void (^)(BOOL))reply {
    reply(self.monitor != nil);
}

- (void)setAWDLEnabled:(BOOL)enabled withReply:(void (^)(BOOL))reply {
    if (!self.monitor) {
        reply(NO);
        return;
    }
    [self.monitor setAwdlEnabled:enabled];
    reply(YES);
}

- (void)connectionDidEnd {
    if (self.isExiting) {
        return;
    }
    self.isExiting = YES;
    [self.monitor restoreAndStop];
    exit(EXIT_SUCCESS);
}

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PixelNOWAWDLHelperProtocol)];
    connection.exportedObject = self;
    connection.interruptionHandler = ^{
        [self connectionDidEnd];
    };
    connection.invalidationHandler = ^{
        [self connectionDidEnd];
    };
    [connection resume];
    return YES;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        AWDLHelperService *service = [AWDLHelperService new];
        if (!service.monitor) {
            os_log_error(OS_LOG_DEFAULT, "AWDL helper could not initialize its monitor");
            return EXIT_FAILURE;
        }

        NSXPCListener *listener = [[NSXPCListener alloc] initWithMachServiceName:@"com.interlacedpixel.pixelnow.AWDLHelper"];
        [listener setConnectionCodeSigningRequirement:@"anchor apple generic and identifier \"com.interlacedpixel.pixelnow\" and certificate leaf[subject.OU] = \"MPZW7ERR2D\""];
        listener.delegate = service;
        [listener activate];
        dispatch_main();
    }
    return EXIT_SUCCESS;
}
