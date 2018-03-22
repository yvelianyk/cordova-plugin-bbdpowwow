//
//  ViewController.m
//  powwow
//
//  Created by Vadim Maslov on 3/1/17.
//  Copyright © 2017 powwowmobile. All rights reserved.
//

#import "ViewController.h"
#import "PWWebAppModel.h"
#import "PWEventManager.h"
#import "PWDownloadManager.h"
#import "PWEventHandler.h"
#import <WebKit/WebKit.h>
#import <GD/GDiOS.h>
#import "AppDelegate.h"


@interface ViewController ()

@property (nonatomic, strong) PWWebAppModel *webApp;

-(void)loadMainPage;

@end

@implementation ViewController

- (void)awakeFromNib
{
    [super awakeFromNib];
    [self setup];
}

- (PWAlertHud *)hud
{
    if (!_hud) { _hud = [[PWAlertHud alloc] initForView:self.webView];}
    return _hud;
}

- (PWWebAppModel *)webApp
{
    if (!_webApp) {_webApp = [PWWebAppModel new];}
    return _webApp;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    if (@available(iOS 11.0, *)) {
        // Fixes the new viewport behavior on iOS 11
        [[self.webView scrollView] setContentInsetAdjustmentBehavior: UIScrollViewContentInsetAdjustmentNever];
    } else {
        // Fallback on earlier versions
    }
}

- (void)start
{
    [self.hud showProgressWithLabel:kLoading];
    BOOL firstLaunch = [PWUtils isFirstLaunch];
    if (firstLaunch && [self.webApp openFromZIP]) {
        [PWUtils clearDocumentsDirectoryAtPath:[NSString stringWithFormat:@"/"]];
        [self extractDefaultWebApp];
    } else {
        [self loadMainPage];
    }

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(loadMainPage) name:kReloadNotification object:nil];

    UITapGestureRecognizer *diagTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTapGesture)];
    diagTapGestureRecognizer.numberOfTapsRequired = 4;  // Quadruple tap with 2 fingers
    diagTapGestureRecognizer.numberOfTouchesRequired = 2;
    diagTapGestureRecognizer.delegate = self;
    [self.view addGestureRecognizer:diagTapGestureRecognizer];

    if (@available(iOS 11.0, *)) {
        // Fixes the new viewport behavior on iOS 11
        [[self.webView scrollView] setContentInsetAdjustmentBehavior: UIScrollViewContentInsetAdjustmentNever];
    } else {
        // Fallback on earlier versions
    }

    NSDictionary *policyDict = [[GDiOS sharedInstance] getApplicationPolicy];
    if (policyDict != nil) {
        NSDictionary *urlDict = [policyDict objectForKey:@"urlsetting"];
        if (urlDict != nil) {
            NSString *newUrl = [urlDict objectForKey:@"webappurl"];
            if (newUrl != nil) {
                AppDelegate *appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
                [appDelegate setNewUrl:newUrl];
            }
        }
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    
    return YES;
}

- (void)extractDefaultWebApp
{
    __weak typeof(self) weakSelf = self;
    NSURL *webAppURL = [[NSBundle mainBundle] URLForResource: kClient withExtension: kZip];
    [PWUtils unpackWebApp:webAppURL.path callback:^(BOOL success) {
        [weakSelf loadMainPage];
    }];
}

- (void)setup
{
    self.wwwFolderName  = [NSString stringWithFormat:@"default.%@",kWwwFolderName];
    self.startPage      = [NSString stringWithFormat:@"default.%@",kStartPage];
    [PWEventHandler sharedInstance].vc = self;
    [[PWEventActionExecutor eventExecutor] registerObject:self
                                                forEvents:@[
                                                            [PWSelectorHolder holderWithSelector:@selector(didRecieveDownloadMessage:) forEvent:kDownloadWebApp],
                                                            [PWSelectorHolder holderWithSelector:@selector(didRecieveGetAppSettings:) forEvent:kGetAppSettings],
                                                            [PWSelectorHolder holderWithSelector:@selector(didRecieveStartWSProxy:) forEvent:@"setWSURL"]
                                                            ]];
}

- (void)didRecieveStartWSProxy:(NSDictionary *)event
{
    [[PWEventHandler sharedInstance] didRecieveStartWSProxy:event];
}

- (void)didRecieveGetAppSettings:(NSDictionary *)event
{
    [[PWEventHandler sharedInstance] didRecieveGetAppSettings:event];
}

- (void)didRecieveDownloadMessage:(NSDictionary *)event
{
    [[PWEventHandler sharedInstance] didRecieveDownloadMessage:event];
}

- (void)loadMainPage
{
    [[NSURLCache sharedURLCache] removeAllCachedResponses];
    __weak typeof(self) weakSelf    = self;
    NSURL *url                      = [self URLForSourcesWithParams:nil];
    NSURLRequest *appReq            = [NSURLRequest requestWithURL:url
                                                       cachePolicy: NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval: 20.0];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf.hud hideProgress];
        if ([self.webApp openFromZIP]) {
            NSURL *sourceFolder = [NSURL fileURLWithPath:[[PWUtils applicationDocumentsDirectory] stringByAppendingPathComponent:kWwwFolderName]];
            [(WKWebView*)weakSelf.webView loadRequest:appReq];
            
        }else{
            [(WKWebView*)weakSelf.webView loadRequest:appReq];
        }
    });
}

- (NSURL *)URLForSourcesWithParams:(NSString *)query
{
    NSString *startFilePath = [[PWUtils applicationDocumentsDirectory]
                               stringByAppendingPathComponent: [NSString stringWithFormat: @"%@/%@",kWwwFolderName,kStartPage]];
    
    return [self.webApp openFromZIP] ? [NSURL fileURLWithPath:startFilePath] : [NSURL URLWithString: self.webApp.webAppURL];
}


- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

@end
