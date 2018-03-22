//
//  PWHttpHelper.m
//  temp
//
//  Created by Vadim Maslov on 25.06.14.
//  Copyright (c) 2014 Vadim Maslov. All rights reserved.
//
#define REQUEST_TIMEOUT 30.0

#import "PWHttpHelper.h"
#define kURL_SESSION_ID @"URL_SESSION_ID"

@interface PWHttpHelperCallbackWrapper : NSObject <NSURLSessionDelegate>

@property (nonatomic, copy) PWProgress progress;
@property (nonatomic, copy) PWSuccess success;
@property (nonatomic, copy) PWFailure failure;
@property (nonatomic, strong) NSString *name;

@property (nonatomic, strong) NSMutableData* dataBuffer;
@property (nonatomic) float downloadSize;

@end

@implementation PWHttpHelperCallbackWrapper

- (id)init
{
    self = [super init];
    if (self)
    {
        self.dataBuffer = [[NSMutableData alloc] init];
    }
    return self;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    if (error) {
        self.failure(error, task.response);
        [self clearCallbacks];
    }
    
    NSString *localPath = [[NSString alloc] initWithString: [[PWUtils applicationDocumentsDirectory] stringByAppendingPathComponent:self.name]];
    
    NSString *eTagKey           = @"sourceHTTPETag";
    NSString *savedEtag         = [[NSUserDefaults standardUserDefaults] stringForKey:eTagKey];
    
    NSString *downloadedEtag    = [(NSHTTPURLResponse *)task.response allHeaderFields][@"Etag"];
    
    if ([savedEtag isEqualToString:downloadedEtag]) {
        [self finish:[NSURL fileURLWithPath:localPath] withResponse:task.response];
        return;
    }
    
    BOOL writeToFile = [self.dataBuffer writeToFile:localPath atomically:YES];
    NSLog(writeToFile ? @"Yes" : @"No");
    
    [self finish:[NSURL fileURLWithPath:localPath] withResponse:task.response];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{
    [self.dataBuffer appendData:data];
    self.progress(self.dataBuffer.length/self.downloadSize);
}

- (void)finish:(NSURL *)url withResponse:(NSURLResponse *)response
{
    [self.dataBuffer setLength:0];
    self.success(url, response);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTas didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler
{
    completionHandler(NSURLSessionResponseAllow);
    
    _downloadSize=[response expectedContentLength];
}

- (void)clearCallbacks
{
    self.success    = nil;
    self.progress   = nil;
    self.failure    = nil;
}

@end

@implementation PWHttpHelper

+(void)sendAsynchronousRequest:(NSMutableURLRequest*)request callback:(PWResponseCallback)callback
{
    __block NSError * error  = nil;
    __block BOOL succeeded   = NO;
    
    // Setting a timeout
    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *connectionError) {
        if (!connectionError && [data length] > 0) {
            // Parse response
            
            id responseJson = [NSJSONSerialization JSONObjectWithData:data
                                                              options:NSJSONReadingMutableLeaves
                                                                error:&error];
            if (!responseJson) {
                NSString *responseString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if ([responseString length]) {
                    responseJson = @{@"response": responseString};
                }
                error  = nil;
            }
            
            if ([(NSHTTPURLResponse*)response statusCode] == 200) {
                succeeded = YES;
            }
            DLog(@"responseJson:%@",responseJson);
            
            dispatch_async(dispatch_get_main_queue(), ^{  callback(responseJson, error, succeeded);});
        } else dispatch_async(dispatch_get_main_queue(), ^{ callback (nil, connectionError, [(NSHTTPURLResponse*)response statusCode] == 200 ? YES : NO ); });
    }] resume];

}

+(void)sendAsynchronousRequestWithUrlRequest:(NSMutableURLRequest*)request progress:(PWProgress)progress success:(PWSuccess)success failure:(PWFailure)failure
{
    [self sendAsynchronousRequestWithUrlRequest:request
                                progress:progress
                                 success:success
                                 failure:failure
                                withName:[[request URL] lastPathComponent]];
}

+ (void)sendAsynchronousRequestWithUrlRequest:(NSMutableURLRequest*)request progress:(PWProgress)progress success:(PWSuccess)success failure:(PWFailure)failure withName:(NSString *)name
{
    NSURLSessionConfiguration *sessionConfig    = [NSURLSessionConfiguration defaultSessionConfiguration];
    
    PWHttpHelperCallbackWrapper *callback       = [PWHttpHelperCallbackWrapper new];
    callback.progress   = progress;
    callback.success    = success;
    callback.failure    = failure;
    callback.name       = name;
    
    NSURLSession *session = [NSURLSession sessionWithConfiguration:sessionConfig
                                                          delegate:callback
                                                     delegateQueue:nil];
    
    NSURLSessionDataTask *getData = [session dataTaskWithRequest:request];

    [getData resume];
}

+ (NSMutableURLRequest *) uploadDataRequestWithURL:(NSURL *)url andData:(NSData *) data andName:(NSString *)imageName andContentType:(NSString *)type
{
    // Create a POST request
    NSMutableURLRequest *myMedRequest = [NSMutableURLRequest requestWithURL:url];
    [myMedRequest setHTTPMethod:@"POST"];
//    [myMedRequest setValue:[PWSettings sharedInstance].token forHTTPHeaderField:@"Authorization"];
    
    // Add HTTP header info
    // Note: POST boundaries are described here: http://www.vivtek.com/rfc1867.html
    // and here http://www.w3.org/TR/html4/interact/forms.html
    NSString *POSTBoundary = @"----0xKhTmLbOuNdArY";
    [myMedRequest addValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", POSTBoundary] forHTTPHeaderField:@"Content-Type"];
    
    // Add HTTP Body
    NSMutableData *POSTBody = [NSMutableData data];
    
    if (data) {
        [POSTBody appendData:[[NSString stringWithFormat:@"--%@\r\n", POSTBoundary] dataUsingEncoding:NSUTF8StringEncoding]];
        [POSTBody appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"files[]\"; filename=%@\r\n", imageName] dataUsingEncoding:NSUTF8StringEncoding]];
        [POSTBody appendData:[[NSString stringWithFormat: @"Content-Type: %@\r\n\r\n", type] dataUsingEncoding:NSUTF8StringEncoding]];
        [POSTBody appendData:data];
        [POSTBody appendData:[[NSString stringWithFormat:@"\r\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    }
    
    // Add the closing -- to the POST Form
    [POSTBody appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", POSTBoundary] dataUsingEncoding:NSUTF8StringEncoding]];
    // Add the body to the myMedRequest & return
    [myMedRequest setHTTPBody:POSTBody];
    return myMedRequest;
}

+ (NSString *)getServerURL
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults objectForKey:@"ServerURL"];
}

+ (NSString *)getConnectionBrokerURL
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults objectForKey:@"CBURL"];
}

@end
