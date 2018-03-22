//
//  PWGDWebSocket.h
//  PowwowIOSClient
//
//  Created by Vadym Maslov on 15/12/14.
//
//


#import <Foundation/Foundation.h>
#import <Security/SecCertificate.h>

typedef enum {
    PWGD_CONNECTING   = 0,
    PWGD_OPEN         = 1,
    PWGD_CLOSING      = 2,
    PWGD_CLOSED       = 3,
} PWGDReadyState;


typedef enum PWGDStatusCode : NSInteger {
    PWGDStatusCodeNormal            = 1000,
    PWGDStatusCodeGoingAway         = 1001,
    PWGDStatusCodeProtocolError     = 1002,
    PWGDStatusCodeUnhandledType     = 1003,
    // 1004 reserved.
    PWGDStatusNoStatusReceived      = 1005,
    // 1004-1006 reserved.
    PWGDStatusCodeInvalidUTF8       = 1007,
    PWGDStatusCodePolicyViolated    = 1008,
    PWGDStatusCodeMessageTooBig     = 1009,
} PWGDStatusCode;

@class PWGDWebSocket;

extern NSString *const PWGDWebSocketErrorDomain;
extern NSString *const PWGDHTTPResponseErrorKey;

#pragma mark - PWGDWebSocketDelegate

@protocol PWGDWebSocketDelegate;

#pragma mark - PWGDWebSocket

@interface PWGDWebSocket : NSObject

@property (nonatomic, weak) id <PWGDWebSocketDelegate> delegate;
@property (nonatomic, readonly) PWGDReadyState readyState;
@property (nonatomic, readonly, retain) NSURL *url;

// This returns the negotiated protocol.
// It will be nil until after the handshake completes.
@property (nonatomic, readonly, copy) NSString *protocol;

// Protocols should be an array of strings that turn into Sec-WebSocket-Protocol.
- (id)initWithURLRequest:(NSURLRequest *)request protocols:(NSArray *)protocols;
- (id)initWithURLRequest:(NSURLRequest *)request;

// Some helper constructors.
- (id)initWithURL:(NSURL *)url protocols:(NSArray *)protocols;
- (id)initWithURL:(NSURL *)url;

// Delegate queue will be dispatch_main_queue by default.
// You cannot set both OperationQueue and dispatch_queue.
- (void)setDelegateOperationQueue:(NSOperationQueue*) queue;
- (void)setDelegateDispatchQueue:(dispatch_queue_t) queue;

// PWGDWebSockets are intended for one-time-use only.  Open should be called once and only once.
- (void)open;
- (void)close;
- (void)closeWithCode:(NSInteger)code reason:(NSString *)reason;

// Send a UTF8 String or Data.
- (void)send:(id)data;

// Send Data (can be nil) in a ping message.
- (void)sendPing:(NSData *)data;

@end

#pragma mark - PWGDWebSocketDelegate

@protocol PWGDWebSocketDelegate <NSObject>

// message will either be an NSString if the server is using text
// or NSData if the server is using binary.
- (void)webSocket:(id)webSocket didReceiveMessage:(id)message;

@optional

- (void)webSocketDidOpen:(id)webSocket;
- (void)webSocket:(id)webSocket didFailWithError:(NSError *)error;
- (void)webSocket:(id)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean;
- (void)webSocket:(id)webSocket didReceivePong:(NSData *)pongPayload;

@end

