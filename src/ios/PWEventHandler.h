//
//  PWEventHandler.h
//  powwow
//
//  Created by Vadym Maslov on 3/22/17.
//  Copyright © 2017 powwowmobile. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "ViewController.h"

@interface PWEventHandler : NSObject

@property (nonatomic, strong) ViewController *vc;

- (void)didRecieveGetAppSettings:(NSDictionary *)event;
- (void)didRecieveDownloadMessage:(NSDictionary *)event;
- (void)didRecieveStartWSProxy:(NSDictionary *)event;

+ (PWEventHandler *)sharedInstance;

@end
