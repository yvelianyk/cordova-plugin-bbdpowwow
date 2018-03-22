//
//  AppDelegate.m
//  powwow
//
//  Created by Vadim Maslov on 3/1/17.
//  Copyright © 2017 powwowmobile. All rights reserved.
//

#import "AppDelegate.h"
#import "ViewController.h"
#import "GDAppDelegate.h"


@interface AppDelegate ()

@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Override point for customization after application launch.
    
    [self configureSettingsBundle];
    
    [GDAppDelegate sharedInstance].appDelegate = self;
    //Set the main window
    [self setWindow:[[GDiOS sharedInstance] getWindow]];
    [[GDiOS sharedInstance] authorize:[GDAppDelegate sharedInstance]];
    
    return YES;
}

-(void)configureSettingsBundle
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *savedWebAppUrl = [defaults stringForKey:kWebAppURL];

    NSString *mainBundleWebAppUrl       = [[NSBundle mainBundle] objectForInfoDictionaryKey: kWebAppURL];
    NSString *mainBundleBuildVersion    = [[NSBundle mainBundle] objectForInfoDictionaryKey: kBuildVersion];
    NSString *mainBundleAppID           = [[NSBundle mainBundle] objectForInfoDictionaryKey: kPowwowAppID];

    [defaults setValue:savedWebAppUrl.length ? savedWebAppUrl : mainBundleWebAppUrl forKey:kWebAppURL];

    [self updateUserAgentForWebView:[[UIWebView alloc]initWithFrame:CGRectZero]
                              appID:mainBundleAppID
                       buildVersion:mainBundleBuildVersion];
    
    NSString *version = [NSString stringWithFormat:@"%@.%@", mainBundleBuildVersion, mainBundleAppID];
    [defaults setValue:version forKey:kBuildVersion];

    [defaults synchronize];
}

- (void)updateUserAgentForWebView:(UIWebView *)webView appID:(NSString *)appID buildVersion:(NSString *)buildVersion
{
    NSString *userAgent    = [webView stringByEvaluatingJavaScriptFromString:@"navigator.userAgent"];
    NSString *newUserAgent = [NSString stringWithFormat:@"%@ PowwowMobile/%@.%@", userAgent, buildVersion, appID];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{ kUserAgentKey : newUserAgent }];
}

// this happens while we are running ( in the background, or from within our own app )
// only valid if 40x-Info.plist specifies a protocol to handle
- (BOOL)application:(UIApplication*)application openURL:(NSURL*)url sourceApplication:(NSString*)sourceApplication annotation:(id)annotation
{
    if (!url) {
        return NO;
    }

    if ([url.scheme isEqualToString:@"powwowpreview"]) {
        NSString *newUrl = [url.host stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        [self setNewUrl:newUrl];
    }

    // all plugins will get the notification, and their handlers will be called
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVPluginHandleOpenURLNotification object:url]];

    return YES;
}

- (void)setNewUrl:(NSString *)newUrl {
    if (newUrl != nil && [newUrl length] > 0) {
        NSLog(@"Re-homing to %@", newUrl);
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setValue:newUrl forKey:kWebAppURL];
        [[NSNotificationCenter defaultCenter] postNotificationName:kReloadNotification object:nil];
    }
}

- (void)applicationWillResignActive:(UIApplication *)application {
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
}


- (void)applicationDidEnterBackground:(UIApplication *)application {
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}


- (void)applicationWillEnterForeground:(UIApplication *)application {
    // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
}


- (void)applicationDidBecomeActive:(UIApplication *)application {
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}


- (void)applicationWillTerminate:(UIApplication *)application {
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
}

@end

@implementation NSURLRequest(DataController)

+ (BOOL)allowsAnyHTTPSCertificateForHost:(NSString *)host
{
    return YES;
}

@end
