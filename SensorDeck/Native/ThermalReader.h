// Native sensor facade: App 只通过这里读温度、电压、电流、CPU。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NSString * SDNativeStatus NS_TYPED_ENUM;
FOUNDATION_EXPORT SDNativeStatus const SDNativeStatusAvailable;
FOUNDATION_EXPORT SDNativeStatus const SDNativeStatusUnavailable;
FOUNDATION_EXPORT SDNativeStatus const SDNativeStatusRestricted;

@interface SDHIDSensor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) double celsius;
@end

@interface SDNativeReading : NSObject
@property (nonatomic, nullable, copy) NSNumber *batteryCelsius;
@property (nonatomic, copy) SDNativeStatus batteryTemperatureStatus;
@property (nonatomic, nullable, copy) NSString *batteryTemperatureSource;
@property (nonatomic, copy) NSArray<SDHIDSensor *> *hidSensors;
@property (nonatomic, copy) SDNativeStatus hidStatus;
@property (nonatomic, nullable, copy) NSNumber *voltageVolts;
@property (nonatomic, nullable, copy) NSString *voltageSource;
@property (nonatomic, copy) SDNativeStatus voltageStatus;
@property (nonatomic, nullable, copy) NSNumber *currentAmps;
@property (nonatomic, nullable, copy) NSString *currentSource;
@property (nonatomic, copy) SDNativeStatus currentStatus;
@property (nonatomic, nullable, copy) NSNumber *powerWatts;
@property (nonatomic, nullable, copy) NSNumber *adapterWatts;
@property (nonatomic, nullable, copy) NSNumber *cpuUsage;
@property (nonatomic, copy) SDNativeStatus cpuStatus;
@property (nonatomic, copy) NSString *diagnosticLine;
@end

@interface ThermalReader : NSObject
+ (SDNativeReading *)readOnce;
@end

NS_ASSUME_NONNULL_END
