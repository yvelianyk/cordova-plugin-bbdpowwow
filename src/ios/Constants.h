//
//  Constants.h
//  powwow
//
//  Created by Vadym Maslov on 3/6/17.
//  Copyright © 2017 powwowmobile. All rights reserved.
//

#ifndef Constants_h
#define Constants_h

#pragma mark -
#pragma mark Server Events

static NSString *const kDownloadWebApp  = @"updateAppSources";
static NSString *const kGetAppSettings  = @"getAppSettings";
static NSString *const kStartWSProxy    = @"setWSURL";


#pragma mark -
#pragma mark Constants

static NSString *const kUrl             = @"url";
static NSString *const kZip             = @"zip";
static NSString *const kClient          = @"client";
static NSString *const kLoading         = @"Loading...";
static NSString *const kCallbackID      = @"callbackID";
static NSString *const kWwwFolderName   = @"www";
static NSString *const kStartPage       = @"index.html";
static NSString *const kWebAppURL       = @"webAppURL";
static NSString *const kCbUrl           = @"cbUrl";
static NSString *const kBuildVersion    = @"buildVersion";
static NSString *const kPowwowAppID     = @"powwowAppID";
static NSString *const kUserAgentKey    = @"UserAgent";
static NSString *const kReloadNotification = @"RELOAD";

#endif /* Constants_h */
