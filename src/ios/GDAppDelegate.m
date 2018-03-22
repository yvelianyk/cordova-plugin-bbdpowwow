//
//  GDAppDelegate.m
//  GDCordova
//
//  Created by Good Technology on 6/11/12.
//  Copyright (c) 2013 Good Technology. All rights reserved.
//

#import "GDAppDelegate.h"
#import "ViewController.h"

@interface GDAppDelegate()

@property(assign, nonatomic) BOOL hasAuthorized;

@end

@implementation GDAppDelegate

@synthesize gdLibrary;

-(void)setAppDelegate:(AppDelegate *)appDelegate
{
    self.gdLibrary = [GDiOS sharedInstance];
    self.gdLibrary.delegate = self;

    _appDelegate = appDelegate;
    [self didAuthorize];
}

-(void)didAuthorize
{
    if (self.hasAuthorized && self.appDelegate) {
        NSLog(@"%s", __FUNCTION__);
        UIWindow *appWindow              = self.appDelegate.window;
        appWindow.autoresizesSubviews    = YES;
        UIStoryboard *storyboard         = [UIStoryboard storyboardWithName:@"Main" bundle:nil];
        ViewController *viewController = [storyboard instantiateViewControllerWithIdentifier:@"mainVC"];;
        [appWindow setRootViewController:viewController];
        [appWindow makeKeyAndVisible];
        [viewController start];
    }
}

+(instancetype)sharedInstance
{
    static GDAppDelegate *gDiOSDelegate = nil;
    static dispatch_once_t onceToken = 0;
    dispatch_once(&onceToken, ^{
        gDiOSDelegate = [[GDAppDelegate alloc] init];
    });
    return gDiOSDelegate;
}

#pragma mark - Good Dynamics Delegate Methods

-(void)handleEvent:(GDAppEvent*)anEvent
{
    /* Called from _good when events occur, such as system startup. */
    
    switch (anEvent.type)
    {
        case GDAppEventAuthorized:
        {
            [self onAuthorized:anEvent];
            break;
        }
        case GDAppEventNotAuthorized:
        {
            [self onNotAuthorized:anEvent];
            break;
        }
        case GDAppEventRemoteSettingsUpdate:
        case GDAppEventPolicyUpdate:
        {
            //A change to application-related configuration or policy settings.
            //or A change to one or more application-specific policy settings has been received.
            NSLog(@"NEW SETTINGS HAVE ARRIVED");
            NSDictionary *policyDict = [[GDiOS sharedInstance] getApplicationPolicy];
            if (policyDict != nil) {
                NSDictionary *urlDict = [policyDict objectForKey:@"urlsetting"];
                if (urlDict != nil) {
                    NSString *newUrl = [urlDict objectForKey:@"webappurl"];
                    if (newUrl != nil) {
                        [self.appDelegate setNewUrl:newUrl];
                    }
                }
            }
            break;
        }
        case GDAppEventServicesUpdate:
        {
            //A change to services-related configuration.
            break;
        }
        case GDAppEventEntitlementsUpdate:
        {
            //A change to the entitlements data has been received.
            break;
        }
        default:
        {
            NSLog(@"event not handled: %@", anEvent.message);
            break;
        }
    }
}

-(void) onNotAuthorized:(GDAppEvent*)anEvent
{
    /* Handle the Good Libraries not authorized event. */
    
    switch (anEvent.code) {
        case GDErrorActivationFailed:
        case GDErrorProvisioningFailed:
        case GDErrorPushConnectionTimeout:
        case GDErrorSecurityError:
        case GDErrorAppDenied:
        case GDErrorAppVersionNotEntitled:
        case GDErrorBlocked:
        case GDErrorWiped:
        case GDErrorRemoteLockout:
        case GDErrorPasswordChangeRequired: {
            // an condition has occured denying authorization, an application may wish to log these events
            NSLog(@"onNotAuthorized %@", anEvent.message);
            break;
        }
        case GDErrorIdleLockout: {
            // idle lockout is benign & informational
            break;
        }
        default:
            NSAssert(false, @"Unhandled not authorized event");
            break;
    }
}

-(void) onAuthorized:(GDAppEvent*)anEvent
{
    /* Handle the Good Libraries authorized event. */
    
    switch (anEvent.code) {
        case GDErrorNone: {
            if (!self.hasAuthorized) {
                
                self.hasAuthorized = YES;
                [self didAuthorize];
            }
            break;
        }
        default:
            NSAssert(false, @"Authorized startup with an error");
            break;
    }
}

@end
