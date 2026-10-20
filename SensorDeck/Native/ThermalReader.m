// IOKit / IOHID / Mach 采样。符号全部 dlsym，失败只打日志，不 fatalError。

#import "ThermalReader.h"

#import <dlfcn.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <mach/processor_info.h>
#import <mach/vm_map.h>
#import <TargetConditionals.h>

SDNativeStatus const SDNativeStatusAvailable = @"available";
SDNativeStatus const SDNativeStatusUnavailable = @"unavailable";
SDNativeStatus const SDNativeStatusRestricted = @"restricted";

@implementation SDHIDSensor
@end

@implementation SDNativeReading
- (instancetype)init {
    self = [super init];
    if (self) {
        _batteryTemperatureStatus = SDNativeStatusUnavailable;
        _hidSensors = @[];
        _hidStatus = SDNativeStatusUnavailable;
        _voltageStatus = SDNativeStatusUnavailable;
        _currentStatus = SDNativeStatusUnavailable;
        _cpuStatus = SDNativeStatusUnavailable;
        _diagnosticLine = @"";
    }
    return self;
}
@end

#pragma mark - Function pointers (no IOKit headers)

typedef void *SDHIDClientRef;
typedef void *SDHIDServiceRef;
typedef void *SDHIDEventRef;
typedef double SDHIDFloat;
typedef uint32_t SDIOObject;
typedef int SDKernReturn;

typedef SDHIDClientRef (*SDHIDCreateFn)(CFAllocatorRef);
typedef int (*SDHIDSetMatchingFn)(SDHIDClientRef, CFDictionaryRef);
typedef CFArrayRef (*SDHIDCopyServicesFn)(SDHIDClientRef);
typedef SDHIDEventRef (*SDHIDCopyEventFn)(SDHIDServiceRef, int64_t, int32_t, int64_t);
typedef CFTypeRef (*SDHIDCopyPropertyFn)(SDHIDServiceRef, CFStringRef);
typedef SDHIDFloat (*SDHIDGetFloatFn)(SDHIDEventRef, uint32_t);

typedef CFTypeRef (*SDIOPSInfoFn)(void);
typedef CFArrayRef (*SDIOPSListFn)(CFTypeRef);
typedef CFDictionaryRef (*SDIOPSDescFn)(CFTypeRef, CFTypeRef);
typedef CFDictionaryRef (*SDIOPSAdapterFn)(void);

typedef CFMutableDictionaryRef (*SDIOServiceMatchingFn)(const char *);
typedef SDIOObject (*SDIOServiceGetMatchingServiceFn)(mach_port_t, CFDictionaryRef);
typedef CFTypeRef (*SDIORegistryCopyFn)(SDIOObject, CFStringRef, CFAllocatorRef, uint32_t);
typedef SDKernReturn (*SDIORegistryCreateCFPropertiesFn)(SDIOObject, CFMutableDictionaryRef *, CFAllocatorRef, uint32_t);
typedef SDKernReturn (*SDIOObjectReleaseFn)(SDIOObject);

enum {
    kSDIOHIDEventTypeTemperature = 15,
    kSDIOHIDEventTypePower = 25
};

static const uint32_t kSDIOHIDTemperatureField = ((uint32_t)kSDIOHIDEventTypeTemperature) << 16;
static const uint32_t kSDIOHIDPowerField = ((uint32_t)kSDIOHIDEventTypePower) << 16;

static void *SDSym(const char *name) {
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (!symbol) {
        void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
        if (handle) {
            symbol = dlsym(handle, name);
        }
    }
    return symbol;
}

#pragma mark - Status / unit helpers

static SDNativeStatus SDStatusFromAttempt(BOOL restricted, BOOL gotValue) {
    if (gotValue) {
        return SDNativeStatusAvailable;
    }
    return restricted ? SDNativeStatusRestricted : SDNativeStatusUnavailable;
}

static NSNumber *SDCelsiusFromBatteryRaw(double raw, NSString **outRule) {
    double celsius = raw;
    NSString *rule = @"as-is °C";
    if (raw > 200.0) {
        celsius = raw / 100.0;
        rule = @"raw / 100 (centi-°C)";
    }
    if (celsius < -40.0 || celsius > 120.0) {
        if (outRule) {
            *outRule = [NSString stringWithFormat:@"out of range raw=%g", raw];
        }
        return nil;
    }
    if (outRule) {
        *outRule = rule;
    }
    return @(celsius);
}

static NSNumber *SDNumberFromCF(CFTypeRef value) {
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return nil;
    }
    double raw = 0;
    if (!CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &raw)) {
        return nil;
    }
    return @(raw);
}

static NSNumber *SDVoltsFromRaw(double raw) {
    double volts = raw;
    if (raw > 20.0 && raw < 30000.0) {
        volts = raw / 1000.0;
    }
    if (volts < 2.5 || volts > 25.0) {
        return nil;
    }
    return @(volts);
}

static NSNumber *SDAmpsFromRaw(double raw) {
    double amps = raw;
    if (fabs(raw) > 20.0) {
        amps = raw / 1000.0;
    }
    if (fabs(amps) > 10.0) {
        return nil;
    }
    return @(amps);
}

#pragma mark - HID client

static CFDictionaryRef SDHIDMatching(int page, int usage) {
    int pageValue = page;
    int usageValue = usage;
    CFStringRef keys[2] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    CFNumberRef pageNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pageValue);
    CFNumberRef usageNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usageValue);
    CFTypeRef values[2] = { pageNumber, usageNumber };
    CFDictionaryRef dict = CFDictionaryCreate(
        kCFAllocatorDefault,
        (const void **)keys,
        (const void **)values,
        2,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    CFRelease(pageNumber);
    CFRelease(usageNumber);
    return dict;
}

static NSString *SDHIDName(SDHIDCopyPropertyFn copyProperty, SDHIDServiceRef service, NSInteger index) {
    NSArray<NSString *> *keys = @[ @"Product", @"ProductName", @"IOName", @"HIDName" ];
    for (NSString *key in keys) {
        CFTypeRef value = copyProperty(service, (__bridge CFStringRef)key);
        if (!value) {
            continue;
        }
        NSString *text = nil;
        if (CFGetTypeID(value) == CFStringGetTypeID()) {
            text = [(__bridge NSString *)value copy];
        }
        CFRelease(value);
        if (text.length > 0) {
            return text;
        }
    }
    return [NSString stringWithFormat:@"HID %ld", (long)index];
}

static BOOL SDHIDResolve(
    SDHIDCreateFn *createFn,
    SDHIDSetMatchingFn *matchFn,
    SDHIDCopyServicesFn *servicesFn,
    SDHIDCopyEventFn *eventFn,
    SDHIDCopyPropertyFn *propertyFn,
    SDHIDGetFloatFn *floatFn,
    SDHIDClientRef *client,
    NSMutableString *diag,
    BOOL *restricted
) {
    *createFn = (SDHIDCreateFn)SDSym("IOHIDEventSystemClientCreate");
    *matchFn = (SDHIDSetMatchingFn)SDSym("IOHIDEventSystemClientSetMatching");
    *servicesFn = (SDHIDCopyServicesFn)SDSym("IOHIDEventSystemClientCopyServices");
    *eventFn = (SDHIDCopyEventFn)SDSym("IOHIDServiceClientCopyEvent");
    *propertyFn = (SDHIDCopyPropertyFn)SDSym("IOHIDServiceClientCopyProperty");
    *floatFn = (SDHIDGetFloatFn)SDSym("IOHIDEventGetFloatValue");
    if (!*createFn || !*matchFn || !*servicesFn || !*eventFn || !*floatFn || !*propertyFn) {
        *restricted = YES;
        [diag appendString:@"HID symbols missing; "];
        return NO;
    }
    static SDHIDClientRef cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cached = (*createFn)(kCFAllocatorDefault);
    });
    if (!cached) {
        *restricted = YES;
        [diag appendString:@"IOHIDEventSystemClientCreate returned nil; "];
        return NO;
    }
    *client = cached;
    return YES;
}

static NSArray<NSDictionary *> *SDHIDReadSamples(
    int page,
    int usage,
    int64_t eventType,
    uint32_t field,
    NSMutableString *diag,
    BOOL *restricted
) {
    SDHIDCreateFn createFn = NULL;
    SDHIDSetMatchingFn matchFn = NULL;
    SDHIDCopyServicesFn servicesFn = NULL;
    SDHIDCopyEventFn eventFn = NULL;
    SDHIDCopyPropertyFn propertyFn = NULL;
    SDHIDGetFloatFn floatFn = NULL;
    SDHIDClientRef client = NULL;
    if (!SDHIDResolve(&createFn, &matchFn, &servicesFn, &eventFn, &propertyFn, &floatFn, &client, diag, restricted)) {
        return @[];
    }

    CFDictionaryRef matching = SDHIDMatching(page, usage);
    matchFn(client, matching);
    CFRelease(matching);

    CFArrayRef services = servicesFn(client);
    if (!services) {
        return @[];
    }

    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    CFIndex count = CFArrayGetCount(services);
    for (CFIndex i = 0; i < count; i++) {
        SDHIDServiceRef service = (SDHIDServiceRef)CFArrayGetValueAtIndex(services, i);
        SDHIDEventRef event = eventFn(service, eventType, 0, 0);
        if (!event) {
            continue;
        }
        double value = floatFn(event, field);
        CFRelease(event);
        if (isnan(value)) {
            continue;
        }
        NSString *name = SDHIDName(propertyFn, service, rows.count);
        NSString *dedupe = [NSString stringWithFormat:@"%@:%g", name, value];
        if ([seen containsObject:dedupe]) {
            continue;
        }
        [seen addObject:dedupe];
        [rows addObject:@{ @"name": name, @"value": @(value) }];
    }
    CFRelease(services);
    return [rows copy];
}

#pragma mark - Name ranking
// gas gauge battery is Apple's HID product name for the fuel-gauge pack thermistor.
// Confirmed: HidSensors on iPhone lists it first; exelban/stats maps it to "Battery".
// PMU tbat is an older alias. PMU tcal / Charger TQ* are not the pack.

static NSInteger SDRankBatteryTemp(NSString *name) {
    NSString *n = name.lowercaseString;
    if ([n isEqualToString:@"gas gauge battery"]) {
        return 0;
    }
    if ([n containsString:@"gas gauge"]) {
        return 1;
    }
    if ([n isEqualToString:@"pmu tbat"] || [n isEqualToString:@"tbat"]) {
        return 2;
    }
    if ([n containsString:@"tbat"] && ![n containsString:@"tcal"]) {
        return 3;
    }
    return NSNotFound;
}

static BOOL SDNameIsALS(NSString *name) {
    return [name.lowercaseString containsString:@"als"];
}

static BOOL SDNameIsWatt(NSString *name) {
    NSString *n = name.lowercaseString;
    if (SDNameIsALS(name)) {
        return NO;
    }
    return [n containsString:@"wq"] || [n containsString:@"wp"] || [n containsString:@"watt"];
}

static BOOL SDNameIsVoltage(NSString *name) {
    NSString *n = name.lowercaseString;
    if (SDNameIsALS(name) || SDNameIsWatt(name)) {
        return NO;
    }
    return [n containsString:@"vq"] || [n containsString:@"vp"] || [n containsString:@"vb"]
        || [n containsString:@"vbus"] || [n containsString:@"vbat"]
        || [n containsString:@"charger v"];
}

static BOOL SDNameIsCurrent(NSString *name) {
    NSString *n = name.lowercaseString;
    if (SDNameIsALS(name) || SDNameIsWatt(name)) {
        return NO;
    }
    return [n containsString:@"iq"] || [n containsString:@"ip"] || [n containsString:@"ibat"]
        || [n containsString:@"ich"] || [n containsString:@"charger i"];
}

// 从 "Charger VQ1u" / "Charger IQ0B" / "PMU VP0u" 里取出电轨标识 "Q1" / "Q0" / "P0"。
// V/I/W 只是量纲前缀，后面的 Q<n> / P<n> 才标识是哪一条电轨。
// 这台机器上 Q0 是电池侧（~4V），Q1 是输入侧（~9.8V），
// 只有同一条轨上的 V 和 I 相乘才对应真实电路。
static NSString *SDRailID(NSString *name) {
    if (![name isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *upper = name.uppercaseString;
    for (NSUInteger i = 0; i + 2 < upper.length; i++) {
        unichar dimension = [upper characterAtIndex:i];
        if (dimension != 'V' && dimension != 'I' && dimension != 'W') {
            continue;
        }
        unichar group = [upper characterAtIndex:i + 1];
        unichar index = [upper characterAtIndex:i + 2];
        if ((group == 'Q' || group == 'P') && index >= '0' && index <= '9') {
            return [NSString stringWithFormat:@"%C%C", group, index];
        }
    }
    return nil;
}

// Modern iPhone HID names look like "Charger VQ0u" / "Charger IQ0u" / "PMU VP0u",
// not the older "vbat" / "vbus" strings.
static NSDictionary *SDPickChargerVoltage(NSArray<NSDictionary *> *rows) {
    NSDictionary *best = nil;
    double bestScore = -1;
    for (NSDictionary *row in rows) {
        NSString *name = row[@"name"];
        if (![name isKindOfClass:[NSString class]] || !SDNameIsVoltage(name)) {
            continue;
        }
        NSNumber *voltsNumber = SDVoltsFromRaw([row[@"value"] doubleValue]);
        if (!voltsNumber) {
            continue;
        }
        double volts = voltsNumber.doubleValue;
        NSString *n = name.lowercaseString;
        double score = 1;
        if ([n containsString:@"vbus"] || [n containsString:@"vq0u"]) {
            score += 50;
        }
        if ([n containsString:@"charger"] && volts >= 4.3 && volts <= 5.6) {
            score += 40;
        }
        if ((volts >= 8.7 && volts <= 10.2) || (volts >= 14.5 && volts <= 16.2) || (volts >= 19.0 && volts <= 21.5)) {
            score += 35;
        }
        if ([n containsString:@"charger"]) {
            score += 10;
        }
        if ([n containsString:@"vbat"] || [n containsString:@"vp0"]) {
            score += 12;
        }
        if (score > bestScore) {
            bestScore = score;
            best = row;
        }
    }
    return best;
}

static NSDictionary *SDPickPackVoltage(NSArray<NSDictionary *> *rows) {
    NSDictionary *best = nil;
    double bestScore = -1;
    for (NSDictionary *row in rows) {
        NSString *name = row[@"name"];
        if (![name isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *n = name.lowercaseString;
        if (SDNameIsALS(name) || SDNameIsWatt(name)) {
            continue;
        }
        NSNumber *voltsNumber = SDVoltsFromRaw([row[@"value"] doubleValue]);
        if (!voltsNumber) {
            continue;
        }
        double volts = voltsNumber.doubleValue;
        if (volts < 3.0 || volts > 4.55) {
            continue;
        }
        double score = 1;
        if ([n containsString:@"vbat"] || [n containsString:@"vp0"] || [n containsString:@"pmu vp"]) {
            score += 40;
        }
        if ([n containsString:@"pmu"]) {
            score += 10;
        }
        if (score > bestScore) {
            bestScore = score;
            best = row;
        }
    }
    return best;
}

static NSDictionary *SDPickChargerCurrent(NSArray<NSDictionary *> *rows) {
    NSDictionary *best = nil;
    double bestScore = -1;
    for (NSDictionary *row in rows) {
        NSString *name = row[@"name"];
        if (![name isKindOfClass:[NSString class]] || !SDNameIsCurrent(name)) {
            continue;
        }
        NSNumber *ampsNumber = SDAmpsFromRaw([row[@"value"] doubleValue]);
        if (!ampsNumber) {
            continue;
        }
        double amps = fabs(ampsNumber.doubleValue);
        if (amps > 6.5) {
            continue;
        }
        // 名字加分只给"确实在动"的那一路。
        // 这台机器上 "Charger IQ0u" 常年读 0，真正带电流的是 "Charger IQ0B"；
        // 无条件给 iq0u 加 20 分会让死的那路赢，A/W 就永远是 0.00。
        //
        // 反过来也不能直接把小电流整行丢掉：涓流充电真的会掉到 20mA 以下，
        // 丢掉会让 A 和 W 一起闪没（power = V × I）。所以是"不加分"而不是"跳过"，
        // 活跃的那一路即使这一秒读到 0.005 仍然靠自己的量级赢过其他归零的行。
        double nameScore = 0;
        if (amps >= 0.02) {
            NSString *n = name.lowercaseString;
            if ([n containsString:@"iq0u"]) {
                nameScore += 20;
            }
            if ([n containsString:@"charger"]) {
                nameScore += 10;
            }
            if ([n containsString:@"ibat"]) {
                nameScore += 15;
            }
        }
        double score = nameScore + amps;
        if (score > bestScore) {
            bestScore = score;
            best = row;
        }
    }
    return best;
}

static NSDictionary *SDPickWattSensor(NSArray<NSDictionary *> *rows) {
    NSDictionary *best = nil;
    double bestScore = -1;
    for (NSDictionary *row in rows) {
        NSString *name = row[@"name"];
        if (![name isKindOfClass:[NSString class]] || !SDNameIsWatt(name)) {
            continue;
        }
        double watts = [row[@"value"] doubleValue];
        if (watts < 0.05 || watts > 45.0) {
            continue;
        }
        NSString *n = name.lowercaseString;
        double score = 1;
        if ([n containsString:@"wq0u"]) {
            score += 20;
        }
        if ([n containsString:@"charger"]) {
            score += 10;
        }
        if (score > bestScore) {
            bestScore = score;
            best = row;
        }
    }
    return best;
}

// 传感器集合会随充电方式变（有线 / MagSafe / Qi 暴露的轨不一样，数量也会 27↔28 跳），
// 所以不是"只打一次"，而是"名字集合变了就再打一次"。值一直在变，只看名字，否则 1Hz 刷屏。
static void SDLogHIDOnce(NSString *kind, NSArray<NSDictionary *> *rows) {
    static NSMutableDictionary<NSString *, NSString *> *signatures;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        signatures = [NSMutableDictionary dictionary];
    });
    if (rows.count == 0) {
        return;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        NSString *name = row[@"name"];
        if ([name isKindOfClass:[NSString class]]) {
            [names addObject:name];
        }
    }
    NSString *signature = [[names sortedArrayUsingSelector:@selector(compare:)]
        componentsJoinedByString:@"|"];
    if ([signatures[kind] isEqualToString:signature]) {
        return;
    }
    signatures[kind] = signature;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSUInteger limit = MIN((NSUInteger)24, rows.count);
    for (NSUInteger i = 0; i < limit; i++) {
        NSDictionary *row = rows[i];
        [parts addObject:[NSString stringWithFormat:@"%@=%g", row[@"name"], [row[@"value"] doubleValue]]];
    }
    NSLog(@"[SensorDeck] HID %@ (%lu): %@",
          kind, (unsigned long)rows.count, [parts componentsJoinedByString:@", "]);
}

#pragma mark - IORegistry power service

static mach_port_t SDMainPort(void) {
    mach_port_t *mainPort = (mach_port_t *)SDSym("kIOMainPortDefault");
    if (!mainPort) {
        mainPort = (mach_port_t *)SDSym("kIOMasterPortDefault");
    }
    return mainPort ? *mainPort : 0;
}

static SDIOObject SDOpenPowerService(NSMutableString *diag, BOOL *restricted) {
    SDIOServiceMatchingFn matchingFn = (SDIOServiceMatchingFn)SDSym("IOServiceMatching");
    SDIOServiceGetMatchingServiceFn getFn = (SDIOServiceGetMatchingServiceFn)SDSym("IOServiceGetMatchingService");
    if (!matchingFn || !getFn) {
        *restricted = YES;
        [diag appendString:@"IOService matching symbols missing; "];
        return 0;
    }
    mach_port_t port = SDMainPort();
    NSArray<NSString *> *names = @[ @"AppleSmartBattery", @"IOPMPowerSource" ];
    for (NSString *name in names) {
        CFMutableDictionaryRef matching = matchingFn(name.UTF8String);
        if (!matching) {
            continue;
        }
        SDIOObject service = getFn(port, matching);
        if (service != 0) {
            [diag appendFormat:@"power service=%@; ", name];
            return service;
        }
    }
    [diag appendString:@"AppleSmartBattery/IOPMPowerSource missing; "];
    return 0;
}

static void SDDumpPowerKeysOnce(SDIOObject service) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SDIORegistryCreateCFPropertiesFn propsFn =
            (SDIORegistryCreateCFPropertiesFn)SDSym("IORegistryEntryCreateCFProperties");
        if (!propsFn || service == 0) {
            NSLog(@"[SensorDeck] power key dump skipped");
            return;
        }
        CFMutableDictionaryRef props = NULL;
        if (propsFn(service, &props, kCFAllocatorDefault, 0) != 0 || !props) {
            NSLog(@"[SensorDeck] IORegistryEntryCreateCFProperties failed");
            return;
        }
        NSDictionary *dict = (__bridge NSDictionary *)props;
        NSArray *keys = [[dict allKeys] sortedArrayUsingSelector:@selector(compare:)];
        NSLog(@"[SensorDeck] power keys (%lu): %@", (unsigned long)keys.count, keys);
        NSArray *interesting = @[
            @"Temperature", @"Voltage", @"Amperage", @"InstantAmperage",
            @"AdapterDetails", @"Current", @"IsCharging", @"AppleRawCurrentCapacity"
        ];
        for (NSString *key in interesting) {
            id value = dict[key];
            if (value) {
                NSLog(@"[SensorDeck] power.%@ = %@", key, value);
            }
        }
        CFRelease(props);
    });
}

static NSNumber *SDCopyServiceNumber(SDIOObject service, NSString *key) {
    SDIORegistryCopyFn copyFn = (SDIORegistryCopyFn)SDSym("IORegistryEntryCreateCFProperty");
    if (!copyFn || service == 0) {
        return nil;
    }
    CFTypeRef value = copyFn(service, (__bridge CFStringRef)key, kCFAllocatorDefault, 0);
    if (!value) {
        return nil;
    }
    NSNumber *number = SDNumberFromCF(value);
    CFRelease(value);
    return number;
}

#pragma mark - IOPS

static NSDictionary *SDReadIOPSDescription(NSMutableString *diag, BOOL *restricted) {
    SDIOPSInfoFn infoFn = (SDIOPSInfoFn)SDSym("IOPSCopyPowerSourcesInfo");
    SDIOPSListFn listFn = (SDIOPSListFn)SDSym("IOPSCopyPowerSourcesList");
    SDIOPSDescFn descFn = (SDIOPSDescFn)SDSym("IOPSGetPowerSourceDescription");
    if (!infoFn || !listFn || !descFn) {
        *restricted = YES;
        [diag appendString:@"IOPS symbols missing; "];
        return nil;
    }
    CFTypeRef blob = infoFn();
    if (!blob) {
        *restricted = YES;
        [diag appendString:@"IOPSCopyPowerSourcesInfo nil; "];
        return nil;
    }
    NSDictionary *result = nil;
    CFArrayRef list = listFn(blob);
    if (list) {
        CFIndex count = CFArrayGetCount(list);
        for (CFIndex i = 0; i < count; i++) {
            CFDictionaryRef desc = descFn(blob, CFArrayGetValueAtIndex(list, i));
            if (!desc) {
                continue;
            }
            result = [(__bridge NSDictionary *)desc copy];
            if (result) {
                break;
            }
        }
        CFRelease(list);
    }
    CFRelease(blob);
    return result;
}

static NSNumber *SDReadAdapterWatts(NSMutableString *diag) {
    SDIOPSAdapterFn adapterFn = (SDIOPSAdapterFn)SDSym("IOPSCopyExternalPowerAdapterDetails");
    if (!adapterFn) {
        return nil;
    }
    CFDictionaryRef details = adapterFn();
    if (!details) {
        return nil;
    }
    NSNumber *watts = SDNumberFromCF(CFDictionaryGetValue(details, CFSTR("Watts")));
    if (watts) {
        [diag appendFormat:@"adapter Watts=%g; ", watts.doubleValue];
    }
    CFRelease(details);
    return watts;
}

#pragma mark - Thermal list

static NSArray<SDHIDSensor *> *SDReadHIDThermal(NSMutableString *diag, BOOL *restricted) {
    NSArray<NSDictionary *> *rows = nil;
    int pages[2] = { 0xff00, 0xff05 };
    for (int i = 0; i < 2; i++) {
        rows = SDHIDReadSamples(pages[i], 5, kSDIOHIDEventTypeTemperature, kSDIOHIDTemperatureField, diag, restricted);
        if (rows.count > 0) {
            [diag appendFormat:@"HID thermal: %lu sensors (matching 0x%x/5); ",
             (unsigned long)rows.count, pages[i]];
            break;
        }
    }
    if (rows.count == 0) {
        [diag appendString:@"HID thermal returned 0 sensors; "];
        return @[];
    }

    NSMutableArray<SDHIDSensor *> *sensors = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        double celsius = [row[@"value"] doubleValue];
        if (celsius < -40.0 || celsius > 120.0) {
            continue;
        }
        SDHIDSensor *sensor = [[SDHIDSensor alloc] init];
        sensor.name = row[@"name"];
        sensor.celsius = celsius;
        [sensors addObject:sensor];
    }
    return [sensors copy];
}

static NSNumber *SDBatteryCelsiusFromHID(NSArray<SDHIDSensor *> *hid, NSString **outSource) {
    SDHIDSensor *best = nil;
    NSInteger bestRank = NSIntegerMax;
    for (SDHIDSensor *sensor in hid) {
        NSInteger rank = SDRankBatteryTemp(sensor.name);
        if (rank != NSNotFound && rank < bestRank) {
            bestRank = rank;
            best = sensor;
        }
    }
    if (!best) {
        return nil;
    }
    if (outSource) {
        *outSource = best.name;
    }
    return @(best.celsius);
}

#pragma mark - CPU usage (Mach, not temperature)

static NSNumber *SDReadCPUUsage(NSMutableString *diag, BOOL *restricted) {
    natural_t cpuCount = 0;
    processor_info_array_t infoArray = NULL;
    mach_msg_type_number_t infoCount = 0;
    kern_return_t kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount);
    if (kr != KERN_SUCCESS || infoArray == NULL || cpuCount == 0) {
        *restricted = YES;
        [diag appendFormat:@"host_processor_info failed kr=%d; ", kr];
        return nil;
    }

    processor_cpu_load_info_t load = (processor_cpu_load_info_t)infoArray;
    static processor_cpu_load_info_t previous = NULL;
    static natural_t previousCount = 0;
    static BOOL hasPrevious = NO;

    NSNumber *result = nil;
    if (hasPrevious && previous && previousCount == cpuCount) {
        uint64_t usedDelta = 0;
        uint64_t totalDelta = 0;
        for (natural_t i = 0; i < cpuCount; i++) {
            uint64_t user = load[i].cpu_ticks[CPU_STATE_USER] - previous[i].cpu_ticks[CPU_STATE_USER];
            uint64_t system = load[i].cpu_ticks[CPU_STATE_SYSTEM] - previous[i].cpu_ticks[CPU_STATE_SYSTEM];
            uint64_t nice = load[i].cpu_ticks[CPU_STATE_NICE] - previous[i].cpu_ticks[CPU_STATE_NICE];
            uint64_t idle = load[i].cpu_ticks[CPU_STATE_IDLE] - previous[i].cpu_ticks[CPU_STATE_IDLE];
            usedDelta += user + system + nice;
            totalDelta += user + system + nice + idle;
        }
        if (totalDelta > 0) {
            double usage = (double)usedDelta / (double)totalDelta;
            if (usage < 0) {
                usage = 0;
            }
            if (usage > 1) {
                usage = 1;
            }
            result = @(usage);
        }
    }

    size_t bytes = sizeof(processor_cpu_load_info_data_t) * cpuCount;
    if (!previous || previousCount != cpuCount) {
        free(previous);
        previous = (processor_cpu_load_info_t)malloc(bytes);
        previousCount = cpuCount;
    }
    if (previous) {
        memcpy(previous, load, bytes);
        hasPrevious = YES;
    }

    vm_deallocate(mach_task_self(), (vm_address_t)infoArray, sizeof(integer_t) * infoCount);
    if (!result) {
        [diag appendString:@"CPU usage waiting for second sample; "];
    }
    return result;
}

#pragma mark - Public

@implementation ThermalReader

+ (SDNativeReading *)readOnce {
    SDNativeReading *reading = [[SDNativeReading alloc] init];
    NSMutableString *diag = [NSMutableString string];

#if TARGET_OS_SIMULATOR
    reading.diagnosticLine = @"simulator: native IOKit/HID skipped";
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSLog(@"[SensorDeck] %@", reading.diagnosticLine);
    });
    return reading;
#else
    BOOL powerRestricted = NO;
    SDIOObject powerService = SDOpenPowerService(diag, &powerRestricted);
    if (powerService != 0) {
        SDDumpPowerKeysOnce(powerService);
    }

    NSNumber *battery = nil;
    NSString *batterySource = nil;
    if (powerService != 0) {
        NSNumber *rawTemp = SDCopyServiceNumber(powerService, @"Temperature");
        if (!rawTemp) {
            rawTemp = SDCopyServiceNumber(powerService, @"AppleRawBatteryTemperature");
        }
        if (rawTemp) {
            NSString *rule = nil;
            battery = SDCelsiusFromBatteryRaw(rawTemp.doubleValue, &rule);
            if (battery) {
                batterySource = @"AppleSmartBattery";
                [diag appendFormat:@"battery °C=%.1f (raw=%g, %@) via AppleSmartBattery; ",
                 battery.doubleValue, rawTemp.doubleValue, rule];
            }
        }
    }

    BOOL iopsRestricted = NO;
    NSDictionary *iops = SDReadIOPSDescription(diag, &iopsRestricted);
    if (!battery && iops[@"Temperature"]) {
        NSString *rule = nil;
        battery = SDCelsiusFromBatteryRaw([iops[@"Temperature"] doubleValue], &rule);
        if (battery) {
            batterySource = @"IOPS";
            [diag appendFormat:@"battery °C=%.1f via IOPS; ", battery.doubleValue];
        }
    }

    BOOL hidRestricted = NO;
    NSArray<SDHIDSensor *> *hid = SDReadHIDThermal(diag, &hidRestricted);
    reading.hidSensors = hid;
    reading.hidStatus = SDStatusFromAttempt(hidRestricted, hid.count > 0);

    if (!battery) {
        NSString *hidSource = nil;
        battery = SDBatteryCelsiusFromHID(hid, &hidSource);
        if (battery) {
            batterySource = hidSource;
            [diag appendFormat:@"battery °C=%.1f via HID '%@'; ", battery.doubleValue, hidSource];
        }
    }
    reading.batteryCelsius = battery;
    reading.batteryTemperatureSource = batterySource;
    reading.batteryTemperatureStatus = SDStatusFromAttempt(powerRestricted && hidRestricted, battery != nil);

    BOOL electricalRestricted = powerRestricted;
    NSArray<NSDictionary *> *hidVolts = SDHIDReadSamples(
        0xff08, 3, kSDIOHIDEventTypePower, kSDIOHIDPowerField, diag, &electricalRestricted
    );
    NSArray<NSDictionary *> *hidAmps = SDHIDReadSamples(
        0xff08, 2, kSDIOHIDEventTypePower, kSDIOHIDPowerField, diag, &electricalRestricted
    );
    SDLogHIDOnce(@"voltage", hidVolts);
    SDLogHIDOnce(@"current", hidAmps);

    NSNumber *voltage = nil;
    NSString *voltageSource = nil;
    NSNumber *current = nil;
    NSString *currentSource = nil;

    NSNumber *registryVoltage = SDCopyServiceNumber(powerService, @"Voltage");
    if (registryVoltage) {
        voltage = SDVoltsFromRaw(registryVoltage.doubleValue);
        if (voltage) {
            voltageSource = @"AppleSmartBattery.Voltage";
        }
    }
    if (!voltage && iops[@"Voltage"]) {
        voltage = SDVoltsFromRaw([iops[@"Voltage"] doubleValue]);
        if (voltage) {
            voltageSource = @"IOPS.Voltage";
        }
    }

    NSNumber *registryCurrent = SDCopyServiceNumber(powerService, @"InstantAmperage");
    if (!registryCurrent) {
        registryCurrent = SDCopyServiceNumber(powerService, @"Amperage");
    }
    if (registryCurrent) {
        current = SDAmpsFromRaw(registryCurrent.doubleValue);
        if (current) {
            currentSource = @"AppleSmartBattery.InstantAmperage";
        }
    }
    if (!current && iops[@"Current"]) {
        current = SDAmpsFromRaw([iops[@"Current"] doubleValue]);
        if (current) {
            currentSource = @"IOPS.Current";
        }
    }

    NSDictionary *chargerV = SDPickChargerVoltage(hidVolts);
    NSDictionary *packV = SDPickPackVoltage(hidVolts);
    NSDictionary *chargerI = SDPickChargerCurrent(hidAmps);
    NSDictionary *wattRow = SDPickWattSensor(hidVolts);
    if (!wattRow) {
        wattRow = SDPickWattSensor(hidAmps);
    }

    if (!current && chargerI) {
        current = SDAmpsFromRaw([chargerI[@"value"] doubleValue]);
        currentSource = chargerI[@"name"];
    }

    // 先定电流，再在同一条电轨上找电压。
    // 不这么做的话，某一帧 VQ1u（输入侧 9.8V）缺席就会静默退回 PMU VP0u（电池组 4.1V），
    // 电压在两条轨之间来回跳，而 P=V*I 一会儿算输入功率一会儿是跨轨的无意义乘积。
    NSString *currentRail = currentSource ? SDRailID(currentSource) : nil;
    NSDictionary *railV = nil;
    double railVolts = -1;
    if (currentRail) {
        for (NSDictionary *row in hidVolts) {
            NSString *name = row[@"name"];
            if (![name isKindOfClass:[NSString class]] || !SDNameIsVoltage(name)) {
                continue;
            }
            NSString *rail = SDRailID(name);
            if (!rail || ![rail isEqualToString:currentRail]) {
                continue;
            }
            NSNumber *volts = SDVoltsFromRaw([row[@"value"] doubleValue]);
            if (volts && volts.doubleValue > railVolts) {
                railVolts = volts.doubleValue;
                railV = row;
            }
        }
    }

    BOOL voltagePairsWithCurrent = NO;
    if (!voltage && railV) {
        voltage = @(railVolts);
        voltageSource = railV[@"name"];
        voltagePairsWithCurrent = YES;
    }
    if (!voltage && chargerV) {
        voltage = SDVoltsFromRaw([chargerV[@"value"] doubleValue]);
        voltageSource = chargerV[@"name"];
    }
    if (!voltage && packV) {
        voltage = SDVoltsFromRaw([packV[@"value"] doubleValue]);
        voltageSource = packV[@"name"];
    }

    // 只有 V 和 I 在同一条电轨上才算功耗。跨轨相乘（例如输入侧电压 × 电池侧电流）
    // 得到的数看着很合理，但不对应任何真实电路，宁可显示 —。
    NSNumber *power = nil;
    if (voltage && current && voltagePairsWithCurrent) {
        power = @(voltage.doubleValue * current.doubleValue);
        [diag appendFormat:@"P=V*I on rail %@; ", currentRail];
    } else if (voltage && current) {
        [diag appendFormat:@"P skipped: V(%@) and I(%@) on different rails; ",
                           voltageSource, currentSource];
    }

    // WQ0u 不是瞬时功率：实测它每秒涨约 1.5 然后在 ~14 处回绕归零（锯齿波），
    // 是累积量或滚动寄存器。绝对不能拿它当瓦特显示，只留作诊断。
    if (wattRow) {
        [diag appendFormat:@"HID %@=%g (counter, not watts); ",
                           wattRow[@"name"], [wattRow[@"value"] doubleValue]];
    }
    if (packV && chargerV) {
        NSNumber *packVolts = SDVoltsFromRaw([packV[@"value"] doubleValue]);
        if (packVolts) {
            [diag appendFormat:@"pack %@=%.2f V; ", packV[@"name"], packVolts.doubleValue];
        }
    }

    reading.voltageVolts = voltage;
    reading.voltageSource = voltageSource;
    reading.voltageStatus = SDStatusFromAttempt(electricalRestricted, voltage != nil);
    reading.currentAmps = current;
    reading.currentSource = currentSource;
    reading.currentStatus = SDStatusFromAttempt(electricalRestricted, current != nil);
    reading.powerWatts = power;
    reading.adapterWatts = SDReadAdapterWatts(diag);

    if (voltage) {
        [diag appendFormat:@"V=%.2f (%@); ", voltage.doubleValue, voltageSource];
    } else {
        [diag appendString:@"voltage missing; "];
    }
    if (current) {
        [diag appendFormat:@"I=%.3f A (%@); ", current.doubleValue, currentSource];
    } else {
        [diag appendString:@"current missing; "];
    }
    if (power) {
        [diag appendFormat:@"P=%.2f W; ", power.doubleValue];
    }

    BOOL cpuRestricted = NO;
    NSNumber *cpu = SDReadCPUUsage(diag, &cpuRestricted);
    reading.cpuUsage = cpu;
    reading.cpuStatus = SDStatusFromAttempt(cpuRestricted, cpu != nil);

    if (powerService != 0) {
        SDIOObjectReleaseFn releaseFn = (SDIOObjectReleaseFn)SDSym("IOObjectRelease");
        if (releaseFn) {
            releaseFn(powerService);
        }
    }

    if (diag.length == 0) {
        [diag appendString:@"native read complete"];
    }
    reading.diagnosticLine = [diag copy];

    static NSString *lastLog;
    if (![lastLog isEqualToString:reading.diagnosticLine]) {
        lastLog = reading.diagnosticLine;
        NSLog(@"[SensorDeck] %@", reading.diagnosticLine);
    }
    return reading;
#endif
}

@end
