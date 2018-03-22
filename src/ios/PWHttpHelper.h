//
//  PWHttpHelper.h
//  temp
//
//  Created by Vadim Maslov on 25.06.14.
//  Copyright (c) 2014 Vadim Maslov. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef void(^PWResponseCallback)(id response, NSError *error, BOOL succeeded);
typedef void(^PWProgress)(CGFloat progress);
typedef void(^PWSuccess)(NSURL *success, NSURLResponse *response);
typedef void(^PWFailure)(NSError *error, NSURLResponse *response);

@interface PWHttpHelper : NSObject

+ (NSString *)getServerURL;
+ (NSString *)getConnectionBrokerURL;

+ (void)sendAsynchronousRequest:(NSMutableURLRequest*)request callback:(PWResponseCallback)callback;
+ (void)sendAsynchronousRequestWithUrlRequest:(NSMutableURLRequest*)request progress:(PWProgress)progress success:(PWSuccess)success failure:(PWFailure)failure;
+ (void)sendAsynchronousRequestWithUrlRequest:(NSMutableURLRequest*)request progress:(PWProgress)progress success:(PWSuccess)success failure:(PWFailure)failure withName:(NSString *)name;

+ (NSMutableURLRequest *) uploadDataRequestWithURL:(NSURL *)url andData:(NSData *) data andName:(NSString *)imageName andContentType:(NSString *)type;

@end
