//
//  AppDelegate.h
//  powwow
//
//  Created by Vadim Maslov on 3/1/17.
//  Copyright © 2017 powwowmobile. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>

@property (strong, nonatomic) UIWindow *window;

- (void)setNewUrl:(NSString *)newUrl;

@end
