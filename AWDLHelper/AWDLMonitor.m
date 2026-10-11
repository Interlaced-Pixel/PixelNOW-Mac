#import "AWDLMonitor.h"

#import <errno.h>
#import <fcntl.h>
#import <net/if.h>
#import <net/route.h>
#import <os/log.h>
#import <poll.h>
#import <sys/ioctl.h>
#import <sys/socket.h>
#import <unistd.h>
#import <string.h>

static const char *AWDLInterfaceName = "awdl0";

@interface AWDLMonitor () {
    int _controlPipe[2];
    int _routeSocket;
    int _ioctlSocket;
    NSThread *_monitorThread;
    dispatch_semaphore_t _threadExit;
    BOOL _desiredEnabled;
}
@end

@implementation AWDLMonitor

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    _routeSocket = -1;
    _ioctlSocket = -1;
    _controlPipe[0] = -1;
    _controlPipe[1] = -1;
    _desiredEnabled = YES;
    _routeSocket = socket(AF_ROUTE, SOCK_RAW, 0);
    _ioctlSocket = socket(AF_INET, SOCK_DGRAM, 0);
    if (_routeSocket < 0 || _ioctlSocket < 0 || pipe(_controlPipe) != 0) {
        os_log_error(OS_LOG_DEFAULT, "Could not create AWDL helper sockets: %{public}s", strerror(errno));
        [self closeDescriptors];
        return nil;
    }

    if (fcntl(_routeSocket, F_SETFL, O_NONBLOCK) < 0 || fcntl(_controlPipe[0], F_SETFL, O_NONBLOCK) < 0) {
        os_log_error(OS_LOG_DEFAULT, "Could not configure AWDL helper descriptors: %{public}s", strerror(errno));
        [self closeDescriptors];
        return nil;
    }

    _threadExit = dispatch_semaphore_create(0);
    _monitorThread = [[NSThread alloc] initWithTarget:self selector:@selector(monitorRouteChanges) object:nil];
    [_monitorThread start];
    return self;
}

- (void)setAwdlEnabled:(BOOL)enabled {
    _desiredEnabled = enabled;
    char message = enabled ? 'U' : 'D';
    if (write(_controlPipe[1], &message, 1) != 1) {
        os_log_error(OS_LOG_DEFAULT, "Could not send AWDL state request: %{public}s", strerror(errno));
    }
}

- (void)restoreAndStop {
    char message = 'Q';
    if (write(_controlPipe[1], &message, 1) == 1) {
        dispatch_semaphore_wait(_threadExit, DISPATCH_TIME_FOREVER);
    }
}

- (void)monitorRouteChanges {
    BOOL shouldQuit = NO;
    BOOL enabled = _desiredEnabled;
    while (!shouldQuit) {
        struct pollfd descriptors[] = {
            { .fd = _routeSocket, .events = POLLIN, .revents = 0 },
            { .fd = _controlPipe[0], .events = POLLIN, .revents = 0 }
        };

        if (poll(descriptors, 2, -1) < 0) {
            if (errno == EINTR) {
                continue;
            }
            os_log_error(OS_LOG_DEFAULT, "AWDL route monitor failed: %{public}s", strerror(errno));
            break;
        }

        if (descriptors[0].revents & POLLIN) {
            [self enforceDisabledStateIfNeeded:enabled];
        }

        if (descriptors[1].revents & POLLIN) {
            char message = 0;
            while (read(_controlPipe[0], &message, 1) == 1) {
                switch (message) {
                    case 'D':
                        enabled = NO;
                        [self setInterfaceEnabled:NO];
                        break;
                    case 'U':
                        enabled = YES;
                        [self setInterfaceEnabled:YES];
                        break;
                    case 'Q':
                        [self setInterfaceEnabled:YES];
                        shouldQuit = YES;
                        break;
                    default:
                        break;
                }
            }
        }
    }

    dispatch_semaphore_signal(_threadExit);
}

- (void)enforceDisabledStateIfNeeded:(BOOL)enabled {
    if (enabled) {
        return;
    }

    struct ifreq interfaceRequest = {0};
    strlcpy(interfaceRequest.ifr_name, AWDLInterfaceName, IFNAMSIZ);
    if (ioctl(_ioctlSocket, SIOCGIFFLAGS, &interfaceRequest) < 0) {
        return;
    }
    if ((interfaceRequest.ifr_flags & IFF_UP) != 0) {
        interfaceRequest.ifr_flags &= ~IFF_UP;
        if (ioctl(_ioctlSocket, SIOCSIFFLAGS, &interfaceRequest) < 0) {
            os_log_error(OS_LOG_DEFAULT, "Could not re-disable AWDL: %{public}s", strerror(errno));
        }
    }
}

- (void)setInterfaceEnabled:(BOOL)enabled {
    struct ifreq interfaceRequest = {0};
    strlcpy(interfaceRequest.ifr_name, AWDLInterfaceName, IFNAMSIZ);
    if (ioctl(_ioctlSocket, SIOCGIFFLAGS, &interfaceRequest) < 0) {
        os_log_error(OS_LOG_DEFAULT, "Could not read AWDL interface state: %{public}s", strerror(errno));
        return;
    }

    BOOL currentlyEnabled = (interfaceRequest.ifr_flags & IFF_UP) != 0;
    if (currentlyEnabled == enabled) {
        return;
    }

    if (enabled) {
        interfaceRequest.ifr_flags |= IFF_UP;
    } else {
        interfaceRequest.ifr_flags &= ~IFF_UP;
    }
    if (ioctl(_ioctlSocket, SIOCSIFFLAGS, &interfaceRequest) < 0) {
        os_log_error(OS_LOG_DEFAULT, "Could not set AWDL interface state: %{public}s", strerror(errno));
    }
}

- (void)closeDescriptors {
    if (_routeSocket >= 0) {
        close(_routeSocket);
        _routeSocket = -1;
    }
    if (_ioctlSocket >= 0) {
        close(_ioctlSocket);
        _ioctlSocket = -1;
    }
    if (_controlPipe[0] >= 0) {
        close(_controlPipe[0]);
        _controlPipe[0] = -1;
    }
    if (_controlPipe[1] >= 0) {
        close(_controlPipe[1]);
        _controlPipe[1] = -1;
    }
}

- (void)dealloc {
    [self closeDescriptors];
}

@end
