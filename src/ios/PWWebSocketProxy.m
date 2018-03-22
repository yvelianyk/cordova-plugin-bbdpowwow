
//
//  PWWebSocketProxy.m
//  LibPowwow
//
//  Created by Orest Savchak on 4/20/16.
//  Copyright © 2016 Olexandr Poburynnyi. All rights reserved.
//

#import "PWWebSocketProxy.h"
#import <PocketSocket/PSWebSocketServer.h>
#import "PWGDWebSocket.h"

@interface PWWebSocketProxy ()<PSWebSocketServerDelegate, PWGDWebSocketDelegate>

@property (nonatomic) PWProxySuccess completion;
@property (nonatomic, strong) PSWebSocketServer *server;
@property (nonatomic, strong) NSString *remote;
@property (nonatomic, strong) PSWebSocket *proxySocket;
@property (nonatomic, strong) PWGDWebSocket *client;
@property (nonatomic, strong) NSMutableArray *msgQueue;


@end

NSString * const localhost = @"localhost";
int const port = 9002;

@implementation PWWebSocketProxy

+ (BOOL)isProxying:(NSString *)url {
    return [url containsString:localhost];
}

- (instancetype)init {
    if (self = [super init]) {
        self.server = [PSWebSocketServer serverWithHost:nil port:port];
        self.server.delegate = self;
    }
    
    return self;
}

- (instancetype)initWithURL:(NSString *)url andCompletion:(PWProxySuccess)completion {
    if (self = [self init]) {
        self.completion = completion;
        self.remote = url;
    }
    
    return self;
}

- (void)connect {
    [self.server start];
}

- (void)disconnect {
    [self.server stop];
}

#pragma mark - PSWebSocketServerDelegate

- (void)serverDidStart:(PSWebSocketServer *)server {
    self.connected = YES;
    self.completion([NSString stringWithFormat:@"ws://%@:%i", localhost, port]);
}

- (void)serverDidStop:(PSWebSocketServer *)server {
    self.connected = NO;
    self.proxySocket = nil;
    [self.client close];
}

- (BOOL)server:(PSWebSocketServer *)server acceptWebSocketWithRequest:(NSURLRequest *)request {
    NSLog(@"Server should accept request: %@", request);
    return YES;
}

- (void)server:(PSWebSocketServer *)server webSocket:(PSWebSocket *)webSocket didReceiveMessage:(id)message {
    NSLog(@"Server websocket did receive message: %@", message);
    if (self.client.readyState == PWGD_OPEN) {
        [self.client send:message];
    } else {
        [self.msgQueue addObject:message];
    }
}

- (void)server:(PSWebSocketServer *)server webSocketDidOpen:(PSWebSocket *)webSocket {
    NSLog(@"Server websocket did open");
    if (self.client) {
        self.msgQueue = nil;
        self.client.delegate = nil;
        [self.client close];
        self.client = nil;
    }
    if (self.proxySocket) {
        self.proxySocket.delegate = nil;
        [self.proxySocket close];
        self.proxySocket = nil;
    }
    self.msgQueue = [NSMutableArray new];
    self.proxySocket = webSocket;
    self.client = [[PWGDWebSocket alloc] initWithURL:[NSURL URLWithString:self.remote]];
    self.client.delegate = self;
    [self.client open];
}

- (void)server:(PSWebSocketServer *)server webSocket:(PSWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean {
    NSLog(@"Server did close");
    self.proxySocket = nil;
    [self.client closeWithCode:code reason:reason];
}

- (void)server:(PSWebSocketServer *)server webSocket:(PSWebSocket *)webSocket didFailWithError:(NSError *)error {
    NSLog(@"Server did fail with socket");
    self.proxySocket = nil;
    [self.client close];
}

- (void)server:(PSWebSocketServer *)server didFailWithError:(NSError *)error {
    NSLog(@"Server did fail");
    self.connected = NO;
    [self.client close];
}

#pragma mark - SRWebSocketDelegate

- (void)webSocketDidOpen:(id)webSocket {
    NSLog(@"Proxy did open");
    if (self.msgQueue.count) {
        [self.msgQueue enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            [self.client send:obj];
        }];
    }
}

- (void)webSocket:(id)webSocket didReceiveMessage:(id)message {
    NSLog(@"Proxy did receive message:\n %@", message);
    [self.proxySocket send:message];
}

- (void)webSocket:(id)webSocket didFailWithError:(NSError *)error {
    NSLog(@"Proxy did fail with error: \n %@", error);
    [self.proxySocket close];
}

- (void)webSocket:(id)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean {
    NSLog(@"Proxy did close with reason: \n %@, and code %ld", reason, (long) code);
    [self.proxySocket closeWithCode:code reason:reason];
}

- (void)webSocket:(id)webSocket didReceivePong:(NSData *)pongPayload {
    //
}

@end
