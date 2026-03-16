#import "ECConnectionTester.h"
#import <arpa/inet.h>
#import <netdb.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>

@implementation ECConnectionTester

static NSOperationQueue *_pingQueue;

+ (void)initialize {
  if (self == [ECConnectionTester class]) {
    _pingQueue = [[NSOperationQueue alloc] init];
    _pingQueue.maxConcurrentOperationCount = 10;
  }
}

+ (void)pingHost:(NSString *)host
            port:(int)port
      completion:
          (void (^)(NSInteger timingMs, NSError *_Nullable error))completion {
  if (!host || host.length == 0 || port <= 0) {
    if (completion)
      completion(-1, [NSError errorWithDomain:@"ECConnectionTester"
                                         code:1
                                     userInfo:@{
                                       NSLocalizedDescriptionKey :
                                           @"Invalid host or port"
                                     }]);
    return;
  }

  [_pingQueue addOperationWithBlock:^{
    struct hostent *remoteHostEnt = gethostbyname([host UTF8String]);
    if (!remoteHostEnt) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (completion)
          completion(-1,
                     [NSError errorWithDomain:@"ECConnectionTester"
                                         code:2
                                     userInfo:@{
                                       NSLocalizedDescriptionKey : @"DNS Failed"
                                     }]);
      });
      return;
    }

    struct in_addr *remoteInAddr =
        (struct in_addr *)remoteHostEnt->h_addr_list[0];
    struct sockaddr_in remoteAddr;
    memset(&remoteAddr, 0, sizeof(remoteAddr));
    remoteAddr.sin_family = AF_INET;
    remoteAddr.sin_addr = *remoteInAddr;
    remoteAddr.sin_port = htons(port);

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (completion)
          completion(-1, [NSError errorWithDomain:@"ECConnectionTester"
                                             code:3
                                         userInfo:@{
                                           NSLocalizedDescriptionKey :
                                               @"Socket Create Failed"
                                         }]);
      });
      return;
    }

    // Set 2 seconds timeout
    struct timeval timeout;
    timeout.tv_sec = 2;
    timeout.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (char *)&timeout,
               sizeof(timeout));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, (char *)&timeout,
               sizeof(timeout));

    // Set non-blocking
    int flags = fcntl(sock, F_GETFL, 0);
    fcntl(sock, F_SETFL, flags | O_NONBLOCK);

    struct timeval start, end;
    gettimeofday(&start, NULL);

    int result =
        connect(sock, (struct sockaddr *)&remoteAddr, sizeof(remoteAddr));

    if (result < 0 && errno == EINPROGRESS) {
      fd_set waitSet;
      FD_ZERO(&waitSet);
      FD_SET(sock, &waitSet);

      // Wait for connect
      result = select(sock + 1, NULL, &waitSet, NULL, &timeout);
      if (result > 0) {
        // Check if there was an error during connection
        int so_error;
        socklen_t len = sizeof(so_error);
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &so_error, &len);
        if (so_error == 0) {
          result = 0; // Success
        } else {
          result = -1;
        }
      } else {
        result = -1; // Timeout or error
      }
    }

    gettimeofday(&end, NULL);
    close(sock);

    long mtime = ((end.tv_sec - start.tv_sec) * 1000.0) +
                 ((end.tv_usec - start.tv_usec) / 1000.0);

    dispatch_async(dispatch_get_main_queue(), ^{
      if (result == 0) {
        if (completion)
          completion(mtime, nil);
      } else {
        if (completion)
          completion(-1, [NSError errorWithDomain:@"ECConnectionTester"
                                             code:4
                                         userInfo:@{
                                           NSLocalizedDescriptionKey :
                                               @"Connect Timeout"
                                         }]);
      }
    });
  }];
}

@end
