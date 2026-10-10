//
//  AdBlock.m
//  Dylib chặn quảng cáo cho app iOS sideload.
//
//  Cách hoạt động:
//   1. Đăng ký một NSURLProtocol (AdBlockURLProtocol) để chặn mọi request
//      mạng tới domain của các SDK quảng cáo.
//   2. Swizzle -[NSURLSessionConfiguration protocolClasses] để ép TẤT CẢ
//      session (kể cả session do SDK tự tạo với config riêng) đều đi qua
//      protocol này — SDK không thể né.
//   3. Request bị chặn sẽ fail với lỗi "mất mạng" (NSURLErrorNotConnectedToInternet)
//      -> SDK hiểu là không tải được ads, app vẫn chạy bình thường, không crash.
//
//  Build: ./build.sh   (cần máy Mac + Xcode, build 1 lần duy nhất)
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Bật để log mỗi domain bị chặn (xem bằng Console trên Mac khi cắm máy debug).
// Mở comment dòng dưới, build lại, rồi tắt đi khi build bản dùng thật.
// #define ADBLOCK_DEBUG 1

#pragma mark - Danh sách domain quảng cáo

// So khớp theo hậu tố, không phân biệt hoa thường.
// Ví dụ "doubleclick.net" sẽ chặn googleads.g.doubleclick.net, v.v.
static NSSet<NSString *> *ABBlockedDomains(void) {
    static NSSet<NSString *> *domains;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        domains = [NSSet setWithArray:@[
            // Google AdMob / Ad Manager
            @"doubleclick.net",
            @"googlesyndication.com",
            @"googleadservices.com",
            // AppLovin MAX
            @"applovin.com",
            // Unity Ads
            @"unityads.unity3d.com",
            @"cdp.cloud.unity3d.com",
            // ironSource / LevelPlay
            @"supersonicads.com",
            // Vungle / Liftoff Monetize
            @"vungle.com",
            // Mintegral
            @"mintegral.com",
            // Moloco
            @"moloco.com",
            // Fyber / DT Exchange
            @"fyber.com",
            // Yandex Mobile Ads
            @"yandexads.com",
            // Appodeal (mediation) + hạ tầng BidMachine
            @"appodeal.com",
            @"appodealx.com",
            // Chartboost
            @"chartboost.com",
            // Pangle (TikTok)
            @"pangle.io",
            // AdColony
            @"adcolony.com",
            // InMobi
            @"inmobi.com",
            // BidMachine
            @"bidmachine.io",
            // Attribution / tracking (giữ lại nếu muốn chặn cả tracking)
            @"app.adjust.com",
            @"appmetrica.yandex.ru",

            // Meta Audience Network dùng chung graph.facebook.com với Facebook Login.
            // Chỉ mở comment dòng dưới nếu app KHÔNG cần đăng nhập Facebook.
            // @"graph.facebook.com",
        ]];
    });
    return domains;
}

static BOOL ABHostIsBlocked(NSString *host) {
    if (host.length == 0) return NO;
    NSString *h = host.lowercaseString;
    for (NSString *domain in ABBlockedDomains()) {
        if ([h isEqualToString:domain] ||
            [h hasSuffix:[@"." stringByAppendingString:domain]]) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - NSURLProtocol chặn request

@interface AdBlockURLProtocol : NSURLProtocol
@end

@implementation AdBlockURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *scheme = request.URL.scheme.lowercaseString;
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        return NO;
    }
    if ([NSURLProtocol propertyForKey:@"com.adblock.handled" inRequest:request]) {
        return NO; // tránh vòng lặp (phòng thủ, thực tế không xảy ra)
    }
    BOOL blocked = ABHostIsBlocked(request.URL.host);
#ifdef ADBLOCK_DEBUG
    if (blocked) NSLog(@"[AdBlock] blocked %@", request.URL.host);
#endif
    return blocked;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    // Giả vờ mất mạng: SDK coi như "không có ads để load".
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain
                                         code:NSURLErrorNotConnectedToInternet
                                     userInfo:nil];
    [[self client] URLProtocol:self didFailWithError:error];
}

- (void)stopLoading {
    // Request chưa từng được gửi đi nên không có gì để dừng.
}

@end

#pragma mark - Ép mọi NSURLSessionConfiguration dùng protocol này

static IMP gOrigProtocolClassesIMP = NULL;

static NSArray *AB_protocolClasses(id self, SEL _cmd) {
    NSArray *(*orig)(id, SEL) = (void *)gOrigProtocolClassesIMP;
    NSArray *current = orig ? orig(self, _cmd) : nil;
    NSMutableArray *result = current ? [current mutableCopy] : [NSMutableArray array];
    Class cls = [AdBlockURLProtocol class];
    if (![result containsObject:cls]) {
        [result insertObject:cls atIndex:0];
    }
    return result;
}

__attribute__((constructor))
static void AdBlockInit(void) {
    // 1. Đăng ký toàn cục: session dùng config mặc định tự dính protocol này.
    [NSURLProtocol registerClass:[AdBlockURLProtocol class]];

    // 2. Swizzle getter protocolClasses: SDK nào tự tạo config riêng cũng không thoát.
    Method m = class_getInstanceMethod([NSURLSessionConfiguration class],
                                       @selector(protocolClasses));
    if (m) {
        gOrigProtocolClassesIMP = method_setImplementation(m, (IMP)AB_protocolClasses);
    }
}
