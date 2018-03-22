//
//  ViewController.h
//  powwow
//
//  Created by Vadim Maslov on 3/1/17.
//  Copyright © 2017 powwowmobile. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <Cordova/CDVViewController.h>
#import "PWAlertHud.h"

@interface ViewController : CDVViewController <UIActionSheetDelegate, UIGestureRecognizerDelegate>

@property (nonatomic, strong) PWAlertHud *hud;
- (void)start;

@end

