//
//  PWEventHandler.m
//  powwow
//
//  Created by Vadym Maslov on 3/22/17.
//  Copyright © 2017 powwowmobile. All rights reserved.
//

#import "PWEventHandler.h"
#import "PWWebAppModel.h"
#import "PWDownloadManager.h"
#import "PWWebSocketProxy.h"

@interface PWEventHandler ()

@property (nonatomic, strong) PWWebAppModel *webApp;
@property (nonatomic, strong) PWWebSocketProxy *proxy;

@end

@implementation PWEventHandler

- (PWWebAppModel *)webApp
{
    if (!_webApp) { _webApp = [PWWebAppModel new];}
    return _webApp;
}

- (void)didRecieveStartWSProxy:(NSDictionary *)event
{
    NSString *wsURL = event[@"url"];
    self.proxy = [[PWWebSocketProxy alloc] initWithURL:wsURL andCompletion:^(NSString *proxy) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                    messageAsString:proxy];
        [self sendPluginResult:result callbackId:event[kCallbackID]];
    }];
    [self.proxy connect];
}

- (void)didRecieveGetAppSettings:(NSDictionary *)event
{
    BOOL shouldShowSettings = [event[@"showSettings"] boolValue];
    if (shouldShowSettings != 0) {
        NSURL *url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
        [[UIApplication sharedApplication] openURL:url];
        
        [[NSUserDefaults standardUserDefaults] addObserver:self
                                                forKeyPath:kCbUrl
                                                   options:NSKeyValueObservingOptionOld
                                                   context:(__bridge_retained void *)(event[kCallbackID])];
    } else{
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                messageAsDictionary:@{ kCbUrl : self.webApp.cbURL.length ? self.webApp.cbURL : @"" }];
        [self sendPluginResult:result callbackId:event[kCallbackID]];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context
{
    NSString *oldCbUrl = [PWUtils objectOrNilForKey:NSKeyValueChangeOldKey fromDictionary:change];
    if ([keyPath isEqualToString:kCbUrl] && ![self.webApp.cbURL isEqualToString:oldCbUrl]) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                messageAsDictionary:@{kCbUrl:self.webApp.cbURL}];
        NSString *callbackId = (__bridge_transfer NSString *)context;
        [self sendPluginResult:result  callbackId:callbackId];
        [object removeObserver:self forKeyPath:keyPath];
    }
}

- (void)sendPluginResult:(CDVPluginResult*)result callbackId:(NSString*)callbackId
{
    [self.vc.commandDelegate sendPluginResult:result
                                   callbackId:callbackId];
}

- (void)didRecieveDownloadMessage:(NSDictionary *)event
{
    __weak typeof(self) weakSelf = self;
    [PWUtils clearDocumentsDirectoryAtPath:[NSString stringWithFormat:@"/"]];
    [PWDownloadManager downloadWebAppFrom:event[kUrl]
                                 progress:^(CGFloat progress) {
                                     [weakSelf.vc.hud showProgressWithProgressBar:[NSNumber numberWithFloat: progress]];
                                 }
                                  success:^(NSURL *success, NSURLResponse *response) {
                                      [PWUtils unpackWebApp:success.path callback:^(BOOL success) {
                                          [weakSelf.vc.hud hideProgress];
                                          CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                                                  messageAsDictionary:nil];
                                          [weakSelf sendPluginResult:result
                                                          callbackId:event[kCallbackID]];
                                      }];
                                  } failure:^(NSError *error, NSURLResponse *response) {
                                      [weakSelf.vc.hud hideProgress];
                                      CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                                              messageAsDictionary:nil];
                                      [weakSelf sendPluginResult:result
                                                      callbackId:event[kCallbackID]];
                                  }];
}

+ (PWEventHandler *)sharedInstance
{
    static PWEventHandler *sPWEventHandler = nil;
    static dispatch_once_t predicate;
    dispatch_once( &predicate, ^{
        sPWEventHandler = [[self alloc] init];
    });
    return sPWEventHandler;
}

@end
