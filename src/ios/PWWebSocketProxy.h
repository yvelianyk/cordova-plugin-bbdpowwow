//
//  PWWebSocketProxy.h
//  LibPowwow
//
//  Created by Orest Savchak on 4/20/16.
//  Copyright © 2016 Olexandr Poburynnyi. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef void(^PWProxySuccess)(NSString *proxy);

@interface PWWebSocketProxy : NSObject

@property (nonatomic, getter=isConnected) BOOL connected;

+ (BOOL)isProxying:(NSString *)url;

- (instancetype)initWithURL:(NSString *)url andCompletion:(PWProxySuccess)completion;
- (void)connect;
- (void)disconnect;

@end
