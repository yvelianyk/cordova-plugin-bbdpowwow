//
//  PWGDWebSocket.m
//  PowwowIOSClient
//
//  Created by Vadym Maslov on 15/12/14.
//
//

#import <GD/GDNETiOS.h>

#import "PWGDWebSocket.h"
#import <resolv.h>

#if TARGET_OS_IPHONE
#define HAS_ICU
#endif

#ifdef HAS_ICU
#import <unicode/utf8.h>
#endif

#if TARGET_OS_IPHONE
#import <Endian.h>
#else
#import <CoreServices/CoreServices.h>
#endif

#import <CommonCrypto/CommonDigest.h>
#import <Security/SecRandom.h>


#if OS_OBJECT_USE_OBJC_RETAIN_RELEASE
#define PWGD_dispatch_retain(x)
#define PWGD_dispatch_release(x)
#define maybe_bridge(x) ((__bridge void *) x)
#else
#define PWGD_dispatch_retain(x) dispatch_retain(x)
#define PWGD_dispatch_release(x) dispatch_release(x)
#define maybe_bridge(x) (x)
#endif

#if !__has_feature(objc_arc)
#error SocketRocket must be compiled with ARC enabled
#endif


typedef enum  {
    PWGDOpCodeTextFrame         = 0x1,
    PWGDOpCodeBinaryFrame       = 0x2,
    // 3-7 reserved.
    PWGDOpCodeConnectionClose   = 0x8,
    PWGDOpCodePing              = 0x9,
    PWGDOpCodePong              = 0xA,
    // B-F reserved.
} PWGDOpCode;

typedef struct {
    BOOL fin;
    //  BOOL rsv1;
    //  BOOL rsv2;
    //  BOOL rsv3;
    uint8_t opcode;
    BOOL masked;
    uint64_t payload_length;
} frame_header;

static NSString *const PWGDWebSocketAppendToSecKeyString = @"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

static inline int32_t validate_dispatch_data_partial_string(NSData *data);
static inline void PWGDFastLog(NSString *format, ...);

@interface NSData (PWGDWebSocket)

- (NSString *)stringBySHA1ThenBase64Encoding;

@end


@interface NSString (PWGDWebSocket)

- (NSString *)stringBySHA1ThenBase64Encoding;

@end


@interface NSURL (PWGDWebSocket)

// The origin isn't really applicable for a native application.
// So instead, just map ws -> http and wss -> https.
- (NSString *)PWGD_origin;

@end


@interface _PWGDRunLoopThread : NSThread

@property (nonatomic, readonly) NSRunLoop *runLoop;

@end

static NSString *newSHA1String(const char *bytes, size_t length) {
    uint8_t md[CC_SHA1_DIGEST_LENGTH];
    
    assert(length >= 0);
    assert(length <= UINT32_MAX);
    CC_SHA1(bytes, (CC_LONG)length, md);
    
    NSData *data = [NSData dataWithBytes:md length:CC_SHA1_DIGEST_LENGTH];
    
    return [data base64EncodedStringWithOptions:0];
}

@implementation NSData (PWGDWebSocket)

- (NSString *)stringBySHA1ThenBase64Encoding;
{
    return newSHA1String(self.bytes, self.length);
}

@end


@implementation NSString (PWGDWebSocket)

- (NSString *)stringBySHA1ThenBase64Encoding;
{
    return newSHA1String(self.UTF8String, self.length);
}

@end

NSString *const PWGDWebSocketErrorDomain = @"PWGDWebSocketErrorDomain";
NSString *const PWSRHTTPResponseErrorKey = @"HTTPResponseStatusCode";

// Returns number of bytes consumed. Returning 0 means you didn't match.
// Sends bytes to callback handler;
typedef size_t (^stream_scanner)(NSData *collected_data);

typedef void (^data_callback)(PWGDWebSocket *webSocket,  NSData *data);

@interface PWGDIOConsumer : NSObject {
    stream_scanner _scanner;
    data_callback _handler;
    size_t _bytesNeeded;
    BOOL _readToCurrentFrame;
    BOOL _unmaskBytes;
}
@property (nonatomic, copy, readonly) stream_scanner consumer;
@property (nonatomic, copy, readonly) data_callback handler;
@property (nonatomic, assign) size_t bytesNeeded;
@property (nonatomic, assign, readonly) BOOL readToCurrentFrame;
@property (nonatomic, assign, readonly) BOOL unmaskBytes;

@end

// This class is not thread-safe, and is expected to always be run on the same queue.
@interface PWGDIOConsumerPool : NSObject

- (id)initWithBufferCapacity:(NSUInteger)poolSize;

- (PWGDIOConsumer *)consumerWithScanner:(stream_scanner)scanner handler:(data_callback)handler bytesNeeded:(size_t)bytesNeeded readToCurrentFrame:(BOOL)readToCurrentFrame unmaskBytes:(BOOL)unmaskBytes;
- (void)returnConsumer:(PWGDIOConsumer *)consumer;

@end

@interface PWGDWebSocket ()  <GDSocketDelegate>

- (void)_writeData:(NSData *)data;
- (void)_closeWithProtocolError:(NSString *)message;
- (void)_failWithError:(NSError *)error;

- (void)_disconnect;

- (void)_readFrameNew;
- (void)_readFrameContinue;

- (void)_pumpScanner;
- (void)_pumpWriting;

- (void)_addConsumerWithScanner:(stream_scanner)consumer callback:(data_callback)callback;
- (void)_addConsumerWithDataLength:(size_t)dataLength callback:(data_callback)callback readToCurrentFrame:(BOOL)readToCurrentFrame unmaskBytes:(BOOL)unmaskBytes;
- (void)_addConsumerWithScanner:(stream_scanner)consumer callback:(data_callback)callback dataLength:(size_t)dataLength;
- (void)_readUntilBytes:(const void *)bytes length:(size_t)length callback:(data_callback)dataHandler;
- (void)_readUntilHeaderCompleteWithCallback:(data_callback)dataHandler;

- (void)_sendFrameWithOpcode:(PWGDOpCode)opcode data:(id)data;

- (BOOL)_checkHandshake:(CFHTTPMessageRef)httpMessage;
- (void)_PWGD_commonInit;

- (void)_initializeStreams;
- (void)_connect;

@property (nonatomic, strong) GDSocket *gdSocket;
@property (nonatomic, strong) GDDirectByteBuffer* gdWriteStream;
@property (nonatomic, strong) GDDirectByteBuffer* gdReadStream;

@property (nonatomic) PWGDReadyState readyState;

@property (nonatomic) NSOperationQueue *delegateOperationQueue;
@property (nonatomic) dispatch_queue_t delegateDispatchQueue;

@end


@implementation PWGDWebSocket {
    NSInteger _webSocketVersion;
    
    NSOperationQueue *_delegateOperationQueue;
    dispatch_queue_t _delegateDispatchQueue;
    
    dispatch_queue_t _workQueue;
    NSMutableArray *_consumers;
    
    NSInputStream *_inputStream;
    NSOutputStream *_outputStream;
    
    NSMutableData *_readBuffer;
    NSUInteger _readBufferOffset;
    
    NSMutableData *_outputBuffer;
    NSUInteger _outputBufferOffset;
    
    uint8_t _currentFrameOpcode;
    size_t _currentFrameCount;
    size_t _readOpCount;
    uint32_t _currentStringScanPosition;
    NSMutableData *_currentFrameData;
    
    NSString *_closeReason;
    
    NSString *_secKey;
    
    BOOL _pinnedCertFound;
    
    uint8_t _currentReadMaskKey[4];
    size_t _currentReadMaskOffset;
    
    BOOL _consumerStopped;
    
    BOOL _closeWhenFinishedWriting;
    BOOL _failed;
    
    BOOL _secure;
    NSURLRequest *_urlRequest;
    
    CFHTTPMessageRef _receivedHTTPHeaders;
    
    BOOL _sentClose;
    BOOL _didFail;
    int _closeCode;
    
    BOOL _isPumping;
    
    NSMutableSet *_scheduledRunloops;
    
    // We use this to retain ourselves.
    __strong PWGDWebSocket *_selfRetain;
    
    NSArray *_requestedProtocols;
    PWGDIOConsumerPool *_consumerPool;
}

@synthesize delegate = _delegate;
@synthesize url = _url;
@synthesize readyState = _readyState;
@synthesize protocol = _protocol;

static __strong NSData *CRLFCRLF;

+ (void)initialize;
{
    CRLFCRLF = [[NSData alloc] initWithBytes:"\r\n\r\n" length:4];
}

- (id)initWithURLRequest:(NSURLRequest *)request protocols:(NSArray *)protocols;
{
    self = [super init];
    if (self) {
        assert(request.URL);
        _url        = request.URL;
        _urlRequest = request;
        _requestedProtocols = [protocols copy];
        [self _PWGD_commonInit];
    }
    
    return self;
}

- (id)initWithURLRequest:(NSURLRequest *)request;
{
    return [self initWithURLRequest:request protocols:nil];
}

- (id)initWithURL:(NSURL *)url;
{
    return [self initWithURL:url protocols:nil];
}

- (id)initWithURL:(NSURL *)url protocols:(NSArray *)protocols;
{
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url];
    return [self initWithURLRequest:request protocols:protocols];
}

- (void)_PWGD_commonInit;
{
    
    NSString *scheme = _url.scheme.lowercaseString;
    assert([scheme isEqualToString:@"ws"] || [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"wss"] || [scheme isEqualToString:@"https"]);
    
    if ([scheme isEqualToString:@"wss"] || [scheme isEqualToString:@"https"]) {
        _secure = YES;
    }
    
    _readyState         = PWGD_CONNECTING;
    _consumerStopped    = YES;
    _webSocketVersion   = 13;
    _workQueue          = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);
    // Going to set a specific on the queue so we can validate we're on the work queue
    dispatch_queue_set_specific(_workQueue, (__bridge void *)self, maybe_bridge(_workQueue), NULL);
    _delegateDispatchQueue  = dispatch_get_main_queue();
    PWGD_dispatch_retain(_delegateDispatchQueue);
    _readBuffer             = [[NSMutableData alloc] init];
    _outputBuffer           = [[NSMutableData alloc] init];
    _currentFrameData       = [[NSMutableData alloc] init];
    _consumers              = [[NSMutableArray alloc] init];
    _consumerPool           = [[PWGDIOConsumerPool alloc] init];
    _scheduledRunloops      = [[NSMutableSet alloc] init];
    [self _initializeStreams];
    
}

- (void)assertOnWorkQueue;
{
    assert(dispatch_get_specific((__bridge void *)self) == maybe_bridge(_workQueue));
}

- (void)dealloc
{
    _inputStream.delegate   = nil;
    _outputStream.delegate  = nil;
    
    [_inputStream close];
    [_outputStream close];
    
    PWGD_dispatch_release(_workQueue);
    _workQueue = NULL;
    
    if (_receivedHTTPHeaders) {
        CFRelease(_receivedHTTPHeaders);
        _receivedHTTPHeaders = NULL;
    }
    
    if (_delegateDispatchQueue) {
        PWGD_dispatch_release(_delegateDispatchQueue);
        _delegateDispatchQueue = NULL;
    }
}

#ifndef NDEBUG

- (void)setReadyState:(PWGDReadyState)aReadyState;
{
    [self willChangeValueForKey:@"readyState"];
    assert(aReadyState > _readyState);
    _readyState = aReadyState;
    [self didChangeValueForKey:@"readyState"];
}

#endif

- (void)open;
{
    assert(_url);
    NSAssert(_readyState == PWGD_CONNECTING, @"Cannot call -(void)open on PWGDWebSocket more than once");
    
    _selfRetain = self;
    
    [self _connect];
}

// Calls block on delegate queue
- (void)_performDelegateBlock:(dispatch_block_t)block;
{
    if (_delegateOperationQueue) {
        [_delegateOperationQueue addOperationWithBlock:block];
    } else {
        assert(_delegateDispatchQueue);
        dispatch_async(_delegateDispatchQueue, block);
    }
}

- (void)setDelegateDispatchQueue:(dispatch_queue_t)queue;
{
    if (queue) {
        PWGD_dispatch_retain(queue);
    }
    
    if (_delegateDispatchQueue) {
        PWGD_dispatch_release(_delegateDispatchQueue);
    }
    
    _delegateDispatchQueue = queue;
}

- (BOOL)_checkHandshake:(CFHTTPMessageRef)httpMessage;
{
    NSString *acceptHeader = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(httpMessage, CFSTR("Sec-WebSocket-Accept")));
    
    if (acceptHeader == nil) {
        return NO;
    }
    NSString *concattedString   = [_secKey stringByAppendingString:PWGDWebSocketAppendToSecKeyString];
    NSString *expectedAccept    = [concattedString stringBySHA1ThenBase64Encoding];
    
    return [acceptHeader isEqualToString:expectedAccept];
}

- (void)_HTTPHeadersDidFinish;
{
    NSInteger responseCode = CFHTTPMessageGetResponseStatusCode(_receivedHTTPHeaders);
    
    if (responseCode >= 400) {
        DLog(@"Request failed with response code %ld", (long)responseCode);
        [self _failWithError:[NSError errorWithDomain:PWGDWebSocketErrorDomain
                                                 code:2132
                                             userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"received bad response code from server %ld", (long)responseCode], PWSRHTTPResponseErrorKey:@(responseCode)}]];
        return;
    }
    
    if(![self _checkHandshake:_receivedHTTPHeaders]) {
        [self _failWithError:[NSError errorWithDomain:PWGDWebSocketErrorDomain
                                                 code:2133
                                             userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"Invalid Sec-WebSocket-Accept response"] forKey:NSLocalizedDescriptionKey]]];
        return;
    }
    
    NSString *negotiatedProtocol = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(_receivedHTTPHeaders, CFSTR("Sec-WebSocket-Protocol")));
    if (negotiatedProtocol) {
        // Make sure we requested the protocol
        if ([_requestedProtocols indexOfObject:negotiatedProtocol] == NSNotFound) {
            [self _failWithError:[NSError errorWithDomain:PWGDWebSocketErrorDomain
                                                     code:2133
                                                 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"Server specified Sec-WebSocket-Protocol that wasn't requested"] forKey:NSLocalizedDescriptionKey]]];
            return;
        }
        
        _protocol = negotiatedProtocol;
    }
    
    self.readyState = PWGD_OPEN;
    
    if (!_didFail) {
        [self _readFrameNew];
    }
    
    [self _performDelegateBlock:^{
        if ([self.delegate respondsToSelector:@selector(webSocketDidOpen:)]) {
            [self.delegate webSocketDidOpen:self];
        };
    }];
}


- (void)_readHTTPHeader;
{
    if (_receivedHTTPHeaders == NULL) {
        _receivedHTTPHeaders = CFHTTPMessageCreateEmpty(NULL, NO);
    }
    
    [self _readUntilHeaderCompleteWithCallback:^(PWGDWebSocket *self,  NSData *data) {
        CFHTTPMessageAppendBytes(_receivedHTTPHeaders, (const UInt8 *)data.bytes, data.length);
        
        if (CFHTTPMessageIsHeaderComplete(_receivedHTTPHeaders)) {
            DLog(@"Finished reading headers %@", CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(_receivedHTTPHeaders)));
            [self _HTTPHeadersDidFinish];
        } else {
            [self _readHTTPHeader];
        }
    }];
}

- (void)didConnect
{
    DLog(@"Connected");
    CFHTTPMessageRef request = CFHTTPMessageCreateRequest(NULL, CFSTR("GET"), (__bridge CFURLRef)_url, kCFHTTPVersion1_1);
    
    // Set host first so it defaults
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Host"), (__bridge CFStringRef)(_url.port ? [NSString stringWithFormat:@"%@:%@", _url.host, _url.port] : _url.host));
    NSMutableData *keyBytes = [[NSMutableData alloc] initWithLength:16];
    
    int result = SecRandomCopyBytes(kSecRandomDefault, keyBytes.length, keyBytes.mutableBytes);
    NSAssert(result == 0, @"Error generating random bytes: %d", errno);
    
    _secKey = [keyBytes base64EncodedStringWithOptions:0];
    
    assert([_secKey length] == 24);
    
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Upgrade"), CFSTR("websocket"));
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Connection"), CFSTR("Upgrade"));
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Sec-WebSocket-Key"), (__bridge CFStringRef)_secKey);
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Sec-WebSocket-Version"), (__bridge CFStringRef)[NSString stringWithFormat:@"%ld", (long)_webSocketVersion]);
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Origin"), (__bridge CFStringRef)_url.PWGD_origin);
    
    if (_requestedProtocols) {
        CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Sec-WebSocket-Protocol"), (__bridge CFStringRef)[_requestedProtocols componentsJoinedByString:@", "]);
    }
    
    [_urlRequest.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        CFHTTPMessageSetHeaderFieldValue(request, (__bridge CFStringRef)key, (__bridge CFStringRef)obj);
    }];
    
    NSData *message = CFBridgingRelease(CFHTTPMessageCopySerializedMessage(request));
    CFRelease(request);
    
    [self _writeData:message];
    [self _readHTTPHeader];
}

- (void)_initializeStreams;
{
    assert(_url.port.unsignedIntValue <= UINT32_MAX);
    uint32_t port = _url.port.unsignedIntValue;
    
    if (port == 0) {
        if (!_secure) {
            port = 80;
        } else {
            port = 443;
        }
    }
    NSString *host = _url.host;
    
    self.gdSocket           = [[GDSocket alloc]init:(const char*)[host UTF8String] onPort:port andUseSSL:_secure];
    self.gdSocket.delegate  = self;
    self.gdWriteStream      = self.gdSocket.writeStream;
    self.gdReadStream       = self.gdSocket.readStream;
}

#pragma mark -
#pragma mark GDSocket Delegate

- (void)onOpen:(id) socket
{
    [self stream:socket handleEvent:NSStreamEventOpenCompleted];
}

- (void)onRead:(id) socket
{
    [self stream:socket handleEvent:NSStreamEventHasBytesAvailable ];
}

- (void)onClose:(id) socket
{
    [self stream:socket handleEvent:NSStreamEventEndEncountered ];
}
- (void)onErr:(int)error inSocket:(id) socket
{
    [self stream:socket handleEvent:NSStreamEventErrorOccurred ];
}

- (void)_connect;
{
    [self.gdSocket connect];
    DLog(@"_connecting");
}

- (void)close;
{
    [self closeWithCode:PWGDStatusCodeNormal reason:nil];
}

- (void)closeWithCode:(NSInteger)code reason:(NSString *)reason;
{
    assert(code);
    dispatch_async(_workQueue, ^{
        if (self.readyState == PWGD_CLOSING || self.readyState == PWGD_CLOSED) {
            return;
        }
        
        BOOL wasConnecting = self.readyState == PWGD_CONNECTING;
        self.readyState = PWGD_CLOSING;
        PWGDFastLog(@"Closing with code %d reason %@", code, reason);
        if (wasConnecting) {
            [self _disconnect];
            return;
        }
        
        size_t maxMsgSize               = [reason maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        NSMutableData *mutablePayload   = [[NSMutableData alloc] initWithLength:sizeof(uint16_t) + maxMsgSize];
        NSData *payload                 = mutablePayload;
        
        ((uint16_t *)mutablePayload.mutableBytes)[0] = EndianU16_BtoN(code);
        
        if (reason) {
            NSRange remainingRange  = {0};
            NSUInteger usedLength   = 0;
            BOOL success            = [reason getBytes:(char *)mutablePayload.mutableBytes + sizeof(uint16_t)
                                             maxLength:payload.length - sizeof(uint16_t)
                                            usedLength:&usedLength
                                              encoding:NSUTF8StringEncoding
                                               options:NSStringEncodingConversionExternalRepresentation
                                                 range:NSMakeRange(0, reason.length)
                                        remainingRange:&remainingRange];
            
            assert(success);
            assert(remainingRange.length == 0);
            
            if (usedLength != maxMsgSize) {
                payload = [payload subdataWithRange:NSMakeRange(0, usedLength + sizeof(uint16_t))];
            }
        }
        [self _sendFrameWithOpcode:PWGDOpCodeConnectionClose data:payload];
    });
}

- (void)_closeWithProtocolError:(NSString *)message;
{
    // Need to shunt this on the _callbackQueue first to see if they received any messages
    [self _performDelegateBlock:^{
        [self closeWithCode:PWGDStatusCodeProtocolError reason:message];
        dispatch_async(_workQueue, ^{
            [self _disconnect];
        });
    }];
}

- (void)_failWithError:(NSError *)error;
{
    dispatch_async(_workQueue, ^{
        if (self.readyState != PWGD_CLOSED) {
            _failed = YES;
            [self _performDelegateBlock:^{
                if ([self.delegate respondsToSelector:@selector(webSocket:didFailWithError:)]) {
                    [self.delegate webSocket:self didFailWithError:error];
                }
            }];
            
            self.readyState = PWGD_CLOSED;
            _selfRetain     = nil;
            
            DLog(@"Failing with error %@", error.localizedDescription);
            [self _disconnect];
        }
    });
}

- (void)_writeData:(NSData *)data;
{
    [self assertOnWorkQueue];
    if (_closeWhenFinishedWriting) {
        return;
    }
    [self.gdWriteStream writeData:data];
    //   [_outputBuffer appendData:data];
    [self _pumpWriting];
}
- (void)send:(id)data;
{
    NSAssert(self.readyState != PWGD_CONNECTING, @"Invalid State: Cannot call send: until connection is open");
    // TODO: maybe not copy this for performance
    data = [data copy];
    dispatch_async(_workQueue, ^{
        if ([data isKindOfClass:[NSString class]]) {
            [self _sendFrameWithOpcode:PWGDOpCodeTextFrame data:[(NSString *)data dataUsingEncoding:NSUTF8StringEncoding]];
        } else if ([data isKindOfClass:[NSData class]]) {
            [self _sendFrameWithOpcode:PWGDOpCodeBinaryFrame data:data];
        } else if (data == nil) {
            [self _sendFrameWithOpcode:PWGDOpCodeTextFrame data:data];
        } else {
            assert(NO);
        }
    });
}

- (void)sendPing:(NSData *)data;
{
    NSAssert(self.readyState == PWGD_OPEN, @"Invalid State: Cannot call send: until connection is open");
    // TODO: maybe not copy this for performance
    data = [data copy] ?: [NSData data]; // It's okay for a ping to be empty
    dispatch_async(_workQueue, ^{
        [self _sendFrameWithOpcode:PWGDOpCodePing data:data];
    });
}

- (void)handlePing:(NSData *)pingData;
{
    // Need to pingpong this off _callbackQueue first to make sure messages happen in order
    [self _performDelegateBlock:^{
        dispatch_async(_workQueue, ^{
            [self _sendFrameWithOpcode:PWGDOpCodePong data:pingData];
        });
    }];
}

- (void)handlePong:(NSData *)pongData;
{
    PWGDFastLog(@"Received pong");
    [self _performDelegateBlock:^{
        if ([self.delegate respondsToSelector:@selector(webSocket:didReceivePong:)]) {
            [self.delegate webSocket:self didReceivePong:pongData];
        }
    }];
}

- (void)_handleMessage:(id)message
{
    PWGDFastLog(@"Received message");
    [self _performDelegateBlock:^{
        [self.delegate webSocket:self didReceiveMessage:message];
    }];
}

static inline BOOL closeCodeIsValid(int closeCode) {
    if (closeCode < 1000) {
        return NO;
    }
    
    if (closeCode >= 1000 && closeCode <= 1011) {
        if (closeCode == 1004 ||
            closeCode == 1005 ||
            closeCode == 1006) {
            return NO;
        }
        return YES;
    }
    
    if (closeCode >= 3000 && closeCode <= 3999) {
        return YES;
    }
    
    if (closeCode >= 4000 && closeCode <= 4999) {
        return YES;
    }
    
    return NO;
}

//  Note from RFC:
//
//  If there is a body, the first two
//  bytes of the body MUST be a 2-byte unsigned integer (in network byte
//  order) representing a status code with value /code/ defined in
//  Section 7.4.  Following the 2-byte integer the body MAY contain UTF-8
//  encoded data with value /reason/, the interpretation of which is not
//  defined by this specification.

- (void)handleCloseWithData:(NSData *)data;
{
    size_t dataSize = data.length;
    __block uint16_t closeCode = 0;
    
    PWGDFastLog(@"Received close frame");
    
    if (dataSize == 1) {
        // TODO handle error
        [self _closeWithProtocolError:@"Payload for close must be larger than 2 bytes"];
        return;
    } else if (dataSize >= 2) {
        [data getBytes:&closeCode length:sizeof(closeCode)];
        _closeCode = EndianU16_BtoN(closeCode);
        if (!closeCodeIsValid(_closeCode)) {
            [self _closeWithProtocolError:[NSString stringWithFormat:@"Cannot have close code of %d", _closeCode]];
            return;
        }
        if (dataSize > 2) {
            _closeReason = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(2, dataSize - 2)] encoding:NSUTF8StringEncoding];
            if (!_closeReason) {
                [self _closeWithProtocolError:@"Close reason MUST be valid UTF-8"];
                return;
            }
        }
    } else {
        _closeCode = PWGDStatusNoStatusReceived;
    }
    
    [self assertOnWorkQueue];
    
    if (self.readyState == PWGD_OPEN) {
        [self closeWithCode:1000 reason:nil];
    }
    dispatch_async(_workQueue, ^{
        [self _disconnect];
    });
}

- (void)_disconnect;
{
    [self assertOnWorkQueue];
    PWGDFastLog(@"Trying to disconnect");
    _closeWhenFinishedWriting = YES;
    [self _pumpWriting];
    [self.gdSocket disconnect];
}

- (void)_handleFrameWithData:(NSData *)frameData opCode:(NSInteger)opcode;
{
    // Check that the current data is valid UTF8
    
    BOOL isControlFrame = (opcode == PWGDOpCodePing || opcode == PWGDOpCodePong || opcode == PWGDOpCodeConnectionClose);
    if (!isControlFrame) {
        [self _readFrameNew];
    } else {
        dispatch_async(_workQueue, ^{
            [self _readFrameContinue];
        });
    }
    
    switch (opcode) {
        case PWGDOpCodeTextFrame: {
            NSString *str = [[NSString alloc] initWithData:frameData encoding:NSUTF8StringEncoding];
            if (str == nil && frameData) {
                [self closeWithCode:PWGDStatusCodeInvalidUTF8 reason:@"Text frames must be valid UTF-8"];
                dispatch_async(_workQueue, ^{
                    [self _disconnect];
                });
                
                return;
            }
            [self _handleMessage:str];
            break;
        }
        case PWGDOpCodeBinaryFrame:
            [self _handleMessage:[frameData copy]];
            break;
        case PWGDOpCodeConnectionClose:
            [self handleCloseWithData:frameData];
            break;
        case PWGDOpCodePing:
            [self handlePing:frameData];
            break;
        case PWGDOpCodePong:
            [self handlePong:frameData];
            break;
        default:
            [self _closeWithProtocolError:[NSString stringWithFormat:@"Unknown opcode %ld", (long)opcode]];
            // TODO: Handle invalid opcode
            break;
    }
}

- (void)_handleFrameHeader:(frame_header)frame_header curData:(NSData *)curData;
{
    assert(frame_header.opcode != 0);
    
    if (self.readyState != PWGD_OPEN) {
        return;
    }
    
    BOOL isControlFrame = (frame_header.opcode == PWGDOpCodePing || frame_header.opcode == PWGDOpCodePong || frame_header.opcode == PWGDOpCodeConnectionClose);
    
    if (isControlFrame && !frame_header.fin) {
        [self _closeWithProtocolError:@"Fragmented control frames not allowed"];
        return;
    }
    
    if (isControlFrame && frame_header.payload_length >= 126) {
        [self _closeWithProtocolError:@"Control frames cannot have payloads larger than 126 bytes"];
        return;
    }
    
    if (!isControlFrame) {
        _currentFrameOpcode = frame_header.opcode;
        _currentFrameCount += 1;
    }
    
    if (frame_header.payload_length == 0) {
        if (isControlFrame) {
            [self _handleFrameWithData:curData opCode:frame_header.opcode];
        } else {
            if (frame_header.fin) {
                [self _handleFrameWithData:_currentFrameData opCode:frame_header.opcode];
            } else {
                // TODO add assert that opcode is not a control;
                [self _readFrameContinue];
            }
        }
    } else {
        assert(frame_header.payload_length <= SIZE_T_MAX);
        [self _addConsumerWithDataLength:(size_t)frame_header.payload_length callback:^(PWGDWebSocket *self, NSData *newData) {
            if (isControlFrame) {
                [self _handleFrameWithData:newData opCode:frame_header.opcode];
            } else {
                if (frame_header.fin) {
                    [self _handleFrameWithData:self->_currentFrameData opCode:frame_header.opcode];
                } else {
                    // TODO add assert that opcode is not a control;
                    [self _readFrameContinue];
                }
            }
        } readToCurrentFrame:!isControlFrame unmaskBytes:frame_header.masked];
    }
}

/* From RFC:
 
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 +-+-+-+-+-------+-+-------------+-------------------------------+
 |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
 |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
 |N|V|V|V|       |S|             |   (if payload len==126/127)   |
 | |1|2|3|       |K|             |                               |
 +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
 |     Extended payload length continued, if payload len == 127  |
 + - - - - - - - - - - - - - - - +-------------------------------+
 |                               |Masking-key, if MASK set to 1  |
 +-------------------------------+-------------------------------+
 | Masking-key (continued)       |          Payload Data         |
 +-------------------------------- - - - - - - - - - - - - - - - +
 :                     Payload Data continued ...                :
 + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
 |                     Payload Data continued ...                |
 +---------------------------------------------------------------+
 */

static const uint8_t PWGDFinMask          = 0x80;
static const uint8_t PWGDOpCodeMask       = 0x0F;
static const uint8_t PWGDRsvMask          = 0x70;
static const uint8_t PWGDMaskMask         = 0x80;
static const uint8_t PWGDPayloadLenMask   = 0x7F;


- (void)_readFrameContinue;
{
    assert((_currentFrameCount == 0 && _currentFrameOpcode == 0) || (_currentFrameCount > 0 && _currentFrameOpcode > 0));
    
    [self _addConsumerWithDataLength:2 callback:^(PWGDWebSocket *self, NSData *data) {
        __block frame_header header = {0};
        
        const uint8_t *headerBuffer = data.bytes;
        assert(data.length >= 2);
        
        if (headerBuffer[0] & PWGDRsvMask) {
            [self _closeWithProtocolError:@"Server used RSV bits"];
            return;
        }
        
        uint8_t receivedOpcode  = (PWGDOpCodeMask & headerBuffer[0]);
        BOOL isControlFrame     = (receivedOpcode == PWGDOpCodePing || receivedOpcode == PWGDOpCodePong || receivedOpcode == PWGDOpCodeConnectionClose);
        
        if (!isControlFrame && receivedOpcode != 0 && self->_currentFrameCount > 0) {
            [self _closeWithProtocolError:@"all data frames after the initial data frame must have opcode 0"];
            return;
        }
        
        if (receivedOpcode == 0 && self->_currentFrameCount == 0) {
            [self _closeWithProtocolError:@"cannot continue a message"];
            return;
        }
        
        header.opcode           = receivedOpcode == 0 ? self->_currentFrameOpcode : receivedOpcode;
        header.fin              = !!(PWGDFinMask & headerBuffer[0]);
        header.masked           = !!(PWGDMaskMask & headerBuffer[1]);
        header.payload_length   = PWGDPayloadLenMask & headerBuffer[1];
        headerBuffer            = NULL;
        
        if (header.masked) {
            [self _closeWithProtocolError:@"Client must receive unmasked data"];
        }
        
        size_t extra_bytes_needed = header.masked ? sizeof(_currentReadMaskKey) : 0;
        
        if (header.payload_length == 126) {
            extra_bytes_needed += sizeof(uint16_t);
        } else if (header.payload_length == 127) {
            extra_bytes_needed += sizeof(uint64_t);
        }
        
        if (extra_bytes_needed == 0) {
            [self _handleFrameHeader:header curData:self->_currentFrameData];
        } else {
            [self _addConsumerWithDataLength:extra_bytes_needed callback:^(PWGDWebSocket *self, NSData *data) {
                size_t mapped_size          = data.length;
                const void *mapped_buffer   = data.bytes;
                size_t offset               = 0;
                
                if (header.payload_length == 126) {
                    assert(mapped_size >= sizeof(uint16_t));
                    uint16_t newLen         = EndianU16_BtoN(*(uint16_t *)(mapped_buffer));
                    header.payload_length   = newLen;
                    offset                  += sizeof(uint16_t);
                } else if (header.payload_length == 127) {
                    assert(mapped_size >= sizeof(uint64_t));
                    header.payload_length   = EndianU64_BtoN(*(uint64_t *)(mapped_buffer));
                    offset                  += sizeof(uint64_t);
                } else {
                    assert(header.payload_length < 126 && header.payload_length >= 0);
                }
                
                if (header.masked) {
                    assert(mapped_size >= sizeof(_currentReadMaskOffset) + offset);
                    memcpy(self->_currentReadMaskKey, ((uint8_t *)mapped_buffer) + offset, sizeof(self->_currentReadMaskKey));
                }
                
                [self _handleFrameHeader:header curData:self->_currentFrameData];
            } readToCurrentFrame:NO unmaskBytes:NO];
        }
    } readToCurrentFrame:NO unmaskBytes:NO];
}

- (void)_readFrameNew;
{
    dispatch_async(_workQueue, ^{
        [_currentFrameData setLength:0];
        _currentFrameOpcode         = 0;
        _currentFrameCount          = 0;
        _readOpCount                = 0;
        _currentStringScanPosition  = 0;
        [self _readFrameContinue];
    });
}

- (void)_pumpWriting;
{
    [self assertOnWorkQueue];
    [self.gdSocket write];
}

- (void)_addConsumerWithScanner:(stream_scanner)consumer callback:(data_callback)callback;
{
    [self assertOnWorkQueue];
    [self _addConsumerWithScanner:consumer callback:callback dataLength:0];
}

- (void)_addConsumerWithDataLength:(size_t)dataLength callback:(data_callback)callback readToCurrentFrame:(BOOL)readToCurrentFrame unmaskBytes:(BOOL)unmaskBytes;
{
    [self assertOnWorkQueue];
    assert(dataLength);
    
    [_consumers addObject:[_consumerPool consumerWithScanner:nil handler:callback bytesNeeded:dataLength readToCurrentFrame:readToCurrentFrame unmaskBytes:unmaskBytes]];
    [self _pumpScanner];
}

- (void)_addConsumerWithScanner:(stream_scanner)consumer callback:(data_callback)callback dataLength:(size_t)dataLength;
{
    [self assertOnWorkQueue];
    [_consumers addObject:[_consumerPool consumerWithScanner:consumer handler:callback bytesNeeded:dataLength readToCurrentFrame:NO unmaskBytes:NO]];
    [self _pumpScanner];
}

static const char CRLFCRLFBytes[] = {'\r', '\n', '\r', '\n'};

- (void)_readUntilHeaderCompleteWithCallback:(data_callback)dataHandler;
{
    [self _readUntilBytes:CRLFCRLFBytes length:sizeof(CRLFCRLFBytes) callback:dataHandler];
}

- (void)_readUntilBytes:(const void *)bytes length:(size_t)length callback:(data_callback)dataHandler;
{
    // TODO optimize so this can continue from where we last searched
    stream_scanner consumer = ^size_t(NSData *data) {
        __block size_t found_size   = 0;
        __block size_t match_count  = 0;
        
        size_t size                 = data.length;
        const unsigned char *buffer = data.bytes;
        for (size_t i = 0; i < size; i++ ) {
            if (((const unsigned char *)buffer)[i] == ((const unsigned char *)bytes)[match_count]) {
                match_count += 1;
                if (match_count == length) {
                    found_size = i + 1;
                    break;
                }
            } else {
                match_count = 0;
            }
        }
        return found_size;
    };
    [self _addConsumerWithScanner:consumer callback:dataHandler];
}


// Returns true if did work
- (BOOL)_innerPumpScanner {
    
    BOOL didWork = NO;
    
    if (self.readyState >= PWGD_CLOSING) {
        return didWork;
    }
    
    if (!_consumers.count) {
        return didWork;
    }
    
    size_t curSize = _readBuffer.length - _readBufferOffset;
    if (!curSize) {
        return didWork;
    }
    
    PWGDIOConsumer *consumer = [_consumers objectAtIndex:0];
    
    size_t bytesNeeded  = consumer.bytesNeeded;
    size_t foundSize    = 0;
    
    if (consumer.consumer) {
        NSData *tempView    = [NSData dataWithBytesNoCopy:(char *)_readBuffer.bytes + _readBufferOffset length:_readBuffer.length - _readBufferOffset freeWhenDone:NO];
        foundSize           = consumer.consumer(tempView);
    } else {
        assert(consumer.bytesNeeded);
        if (curSize >= bytesNeeded) {
            foundSize = bytesNeeded;
        } else if (consumer.readToCurrentFrame) {
            foundSize = curSize;
        }
    }
    
    NSData *slice = nil;
    
    if (consumer.readToCurrentFrame || foundSize) {
        NSRange sliceRange = NSMakeRange(_readBufferOffset, foundSize);
        slice = [_readBuffer subdataWithRange:sliceRange];
        _readBufferOffset += foundSize;
        
        if (_readBufferOffset > 4096 && _readBufferOffset > (_readBuffer.length >> 1)) {
            _readBuffer = [[NSMutableData alloc] initWithBytes:(char *)_readBuffer.bytes + _readBufferOffset length:_readBuffer.length - _readBufferOffset];            _readBufferOffset = 0;
        }
        
        if (consumer.unmaskBytes) {
            NSMutableData *mutableSlice = [slice mutableCopy];
            NSUInteger len              = mutableSlice.length;
            uint8_t *bytes              = mutableSlice.mutableBytes;
            
            for (NSUInteger i = 0; i < len; i++) {
                bytes[i] = bytes[i] ^ _currentReadMaskKey[_currentReadMaskOffset % sizeof(_currentReadMaskKey)];
                _currentReadMaskOffset += 1;
            }
            slice = mutableSlice;
        }
        
        if (consumer.readToCurrentFrame) {
            [_currentFrameData appendData:slice];
            _readOpCount += 1;
            
            if (_currentFrameOpcode == PWGDOpCodeTextFrame) {
                // Validate UTF8 stuff.
                size_t currentDataSize = _currentFrameData.length;
                if (_currentFrameOpcode == PWGDOpCodeTextFrame && currentDataSize > 0) {
                    // TODO: Optimize the crap out of this.  Don't really have to copy all the data each time
                    size_t scanSize         = currentDataSize - _currentStringScanPosition;
                    NSData *scan_data       = [_currentFrameData subdataWithRange:NSMakeRange(_currentStringScanPosition, scanSize)];
                    int32_t valid_utf8_size = validate_dispatch_data_partial_string(scan_data);
                    
                    if (valid_utf8_size == -1) {
                        [self closeWithCode:PWGDStatusCodeInvalidUTF8 reason:@"Text frames must be valid UTF-8"];
                        dispatch_async(_workQueue, ^{
                            [self _disconnect];
                        });
                        return didWork;
                    } else {
                        _currentStringScanPosition += valid_utf8_size;
                    }
                }
            }
            
            consumer.bytesNeeded -= foundSize;
            
            if (consumer.bytesNeeded == 0) {
                [_consumers removeObjectAtIndex:0];
                consumer.handler(self, nil);
                [_consumerPool returnConsumer:consumer];
                didWork = YES;
            }
        } else if (foundSize) {
            [_consumers removeObjectAtIndex:0];
            consumer.handler(self, slice);
            [_consumerPool returnConsumer:consumer];
            didWork = YES;
        }
    }
    return didWork;
}

-(void)_pumpScanner;
{
    [self assertOnWorkQueue];
    
    if (!_isPumping) {
        _isPumping = YES;
    } else {
        return;
    }
    
    while ([self _innerPumpScanner]) {
        
    }
    
    _isPumping = NO;
}

//#define NOMASK

static const size_t PWGDFrameHeaderOverhead = 32;

- (void)_sendFrameWithOpcode:(PWGDOpCode)opcode data:(id)data;
{
    [self assertOnWorkQueue];
    
    if (nil == data) {
        return;
    }
    
    NSAssert([data isKindOfClass:[NSData class]] || [data isKindOfClass:[NSString class]], @"NSString or NSData");
    
    size_t payloadLength = [data isKindOfClass:[NSString class]] ? [(NSString *)data lengthOfBytesUsingEncoding:NSUTF8StringEncoding] : [data length];
    NSMutableData *frame = [[NSMutableData alloc] initWithLength:payloadLength + PWGDFrameHeaderOverhead];
    if (!frame) {
        [self closeWithCode:PWGDStatusCodeMessageTooBig reason:@"Message too big"];
        return;
    }
    uint8_t *frame_buffer = (uint8_t *)[frame mutableBytes];
    
    // set fin
    frame_buffer[0] = PWGDFinMask | opcode;
    
    BOOL useMask = YES;
#ifdef NOMASK
    useMask = NO;
#endif
    
    if (useMask) {
        // set the mask and header
        frame_buffer[1] |= PWGDMaskMask;
    }
    
    size_t frame_buffer_size = 2;
    
    const uint8_t *unmasked_payload = NULL;
    if ([data isKindOfClass:[NSData class]]) {
        unmasked_payload = (uint8_t *)[data bytes];
    } else if ([data isKindOfClass:[NSString class]]) {
        unmasked_payload =  (const uint8_t *)[data UTF8String];
    } else {
        return;
    }
    
    if (payloadLength < 126) {
        frame_buffer[1] |= payloadLength;
    } else if (payloadLength <= UINT16_MAX) {
        frame_buffer[1] |= 126;
        *((uint16_t *)(frame_buffer + frame_buffer_size)) = EndianU16_BtoN((uint16_t)payloadLength);
        frame_buffer_size += sizeof(uint16_t);
    } else {
        frame_buffer[1] |= 127;
        *((uint64_t *)(frame_buffer + frame_buffer_size)) = EndianU64_BtoN((uint64_t)payloadLength);
        frame_buffer_size += sizeof(uint64_t);
    }
    
    if (!useMask) {
        for (size_t i = 0; i < payloadLength; i++) {
            frame_buffer[frame_buffer_size] = unmasked_payload[i];
            frame_buffer_size               += 1;
        }
    } else {
        uint8_t *mask_key = frame_buffer + frame_buffer_size;
        
        int result = SecRandomCopyBytes(kSecRandomDefault, sizeof(uint32_t), (uint8_t *)mask_key);
        NSAssert(result == 0, @"Error generating random bytes: %d", errno);
        
        frame_buffer_size += sizeof(uint32_t);
        
        // TODO: could probably optimize this with SIMD
        for (size_t i = 0; i < payloadLength; i++) {
            frame_buffer[frame_buffer_size] = unmasked_payload[i] ^ mask_key[i % sizeof(uint32_t)];
            frame_buffer_size               += 1;
        }
    }
    
    assert(frame_buffer_size <= [frame length]);
    frame.length = frame_buffer_size;
    
    [self _writeData:frame];
}

- (void)stream:(GDSocket *)aSocket handleEvent:(NSStreamEvent)eventCode;
{
    dispatch_async(_workQueue, ^{
        switch (eventCode) {
            case NSStreamEventOpenCompleted: {
                if (self.readyState >= PWGD_CLOSING) {
                    return;
                }
                assert(_readBuffer);
                
                if (self.readyState == PWGD_CONNECTING ) {
                    [self didConnect];
                }
                [self _pumpWriting];
                [self _pumpScanner];
                break;
            }
                
            case NSStreamEventErrorOccurred: {
                /// TODO specify error better!
                NSError *error = nil;
                [self _failWithError:error];
                _readBufferOffset = 0;
                [_readBuffer setLength:0];
                break;
                
            }
                
            case NSStreamEventHasBytesAvailable: {
                const int bufferSize = 2048;
                char buffer[bufferSize];
                while (self.gdReadStream.bytesUnread) {
                    NSInteger bytes_read = [self.gdReadStream read:buffer toMaxLength:bufferSize];
                    if (bytes_read > 0) {
                        [_readBuffer appendBytes:buffer length:bytes_read];
                    } else if (bytes_read < 0) {
                        [self _failWithError:_inputStream.streamError];
                    }
                    if (bytes_read != bufferSize) {
                        break;
                    }
                };
                [self _pumpScanner];
                break;
            }
                
            case NSStreamEventEndEncountered: {
                [self _pumpScanner];
                
                if (self.readyState != PWGD_CLOSED) {
                    self.readyState = PWGD_CLOSED;
                    _selfRetain     = nil;
                }
                
                if (!_sentClose && !_failed) {
                    _sentClose = YES;
                    // If we get closed in this state it's probably not clean because we should be sending this when we send messages
                    [self _performDelegateBlock:^{
                        if ([self.delegate respondsToSelector:@selector(webSocket:didCloseWithCode:reason:wasClean:)]) {
                            [self.delegate webSocket:self didCloseWithCode:PWGDStatusCodeGoingAway reason:@"Stream end encountered" wasClean:NO];
                        }
                    }];
                }
                break;
            }
            case NSStreamEventHasSpaceAvailable: {
                [self _pumpWriting];
                break;
            }
            default:
                break;
        }
    });
}

@end

@implementation PWGDIOConsumer

@synthesize bytesNeeded         = _bytesNeeded;
@synthesize consumer            = _scanner;
@synthesize handler             = _handler;
@synthesize readToCurrentFrame  = _readToCurrentFrame;
@synthesize unmaskBytes         = _unmaskBytes;

- (void)setupWithScanner:(stream_scanner)scanner handler:(data_callback)handler bytesNeeded:(size_t)bytesNeeded readToCurrentFrame:(BOOL)readToCurrentFrame unmaskBytes:(BOOL)unmaskBytes;
{
    _scanner            = [scanner copy];
    _handler            = [handler copy];
    _bytesNeeded        = bytesNeeded;
    _readToCurrentFrame = readToCurrentFrame;
    _unmaskBytes        = unmaskBytes;
    assert(_scanner || _bytesNeeded);
}

@end

@implementation PWGDIOConsumerPool {
    NSUInteger _poolSize;
    NSMutableArray *_bufferedConsumers;
}

- (id)initWithBufferCapacity:(NSUInteger)poolSize;
{
    self = [super init];
    if (self) {
        _poolSize           = poolSize;
        _bufferedConsumers  = [[NSMutableArray alloc] initWithCapacity:poolSize];
    }
    return self;
}

- (id)init
{
    return [self initWithBufferCapacity:8];
}

- (PWGDIOConsumer *)consumerWithScanner:(stream_scanner)scanner handler:(data_callback)handler bytesNeeded:(size_t)bytesNeeded readToCurrentFrame:(BOOL)readToCurrentFrame unmaskBytes:(BOOL)unmaskBytes;
{
    PWGDIOConsumer *consumer = nil;
    if (_bufferedConsumers.count) {
        consumer = [_bufferedConsumers lastObject];
        [_bufferedConsumers removeLastObject];
    } else {
        consumer = [[PWGDIOConsumer alloc] init];
    }
    
    [consumer setupWithScanner:scanner handler:handler bytesNeeded:bytesNeeded readToCurrentFrame:readToCurrentFrame unmaskBytes:unmaskBytes];
    
    return consumer;
}

- (void)returnConsumer:(PWGDIOConsumer *)consumer;
{
    if (_bufferedConsumers.count < _poolSize) {
        [_bufferedConsumers addObject:consumer];
    }
}

@end

@implementation NSURL (PWGDWebSocket)

- (NSString *)PWGD_origin;
{
    NSString *scheme = [self.scheme lowercaseString];
    
    if ([scheme isEqualToString:@"wss"]) {
        scheme = @"https";
    } else if ([scheme isEqualToString:@"ws"]) {
        scheme = @"http";
    }
    
    if (self.port) {
        return [NSString stringWithFormat:@"%@://%@:%@/", scheme, self.host, self.port];
    } else {
        return [NSString stringWithFormat:@"%@://%@/", scheme, self.host];
    }
}

@end

static inline void PWGDFastLog(NSString *format, ...)  {
#ifdef PWGD_ENABLE_LOG
    __block va_list arg_list;
    va_start (arg_list, format);
    NSString *formattedString = [[NSString alloc] initWithFormat:format arguments:arg_list];
    va_end(arg_list);
    NSLog(@"[PWGD] %@", formattedString);
#endif
}

#ifdef HAS_ICU

static inline int32_t validate_dispatch_data_partial_string(NSData *data) {
    
    if ([data length] > INT32_MAX) {
        // INT32_MAX is the limit so long as this Framework is using 32 bit ints everywhere.
        return -1;
    }
    
    int32_t size            = (int32_t)[data length];
    const void * contents   = [data bytes];
    const uint8_t *str      = (const uint8_t *)contents;
    UChar32 codepoint       = 1;
    int32_t offset          = 0;
    int32_t lastOffset      = 0;
    while(offset < size && codepoint > 0)  {
        lastOffset = offset;
        U8_NEXT(str, offset, size, codepoint);
    }
    
    if (codepoint == -1) {
        // Check to see if the last byte is valid or whether it was just continuing
        if (!U8_IS_LEAD(str[lastOffset]) || U8_COUNT_TRAIL_BYTES(str[lastOffset]) + lastOffset < (int32_t)size) {
            
            size = -1;
        } else {
            uint8_t leadByte = str[lastOffset];
            U8_MASK_LEAD_BYTE(leadByte, U8_COUNT_TRAIL_BYTES(leadByte));
            
            for (int i = lastOffset + 1; i < offset; i++) {
                if (U8_IS_SINGLE(str[i]) || U8_IS_LEAD(str[i]) || !U8_IS_TRAIL(str[i])) {
                    size = -1;
                }
            }
            
            if (size != -1) {
                size = lastOffset;
            }
        }
    }
    
    if (size != -1 && ![[NSString alloc] initWithBytesNoCopy:(char *)[data bytes] length:size encoding:NSUTF8StringEncoding freeWhenDone:NO]) {
        size = -1;
    }
    
    return size;
}

#else

// This is a hack, and probably not optimal
static inline int32_t validate_dispatch_data_partial_string(NSData *data) {
    static const int maxCodepointSize = 3;
    
    for (int i = 0; i < maxCodepointSize; i++) {
        NSString *str = [[NSString alloc] initWithBytesNoCopy:(char *)data.bytes length:data.length - i encoding:NSUTF8StringEncoding freeWhenDone:NO];
        if (str) {
            return data.length - i;
        }
    }
    
    return -1;
}

#endif
