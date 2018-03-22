//
//  GDAppDelegate.h
//  GDCordova
//
//  Created by Good Technology on 6/11/12.
//  Copyright (c) 2013 Good Technology. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AppDelegate.h"
#import <GD/GDios.h>

@interface GDAppDelegate : NSObject

@property (nonatomic, readonly) BOOL hasAuthorized;
@property (weak, nonatomic) AppDelegate *appDelegate;
@property (nonatomic, weak) GDiOS *gdLibrary;

+(GDAppDelegate *)sharedInstance;

@end
