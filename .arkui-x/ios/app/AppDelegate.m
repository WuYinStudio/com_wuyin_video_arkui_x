//
//  AppDelegate.m
//  app
//
//  ArkUI-X iOS 壳工程入口：
//  1. configModuleWithBundleDirectory 指定 ArkTS 编译产物目录（arkui-x）；
//  2. launchApplication 启动 ArkTS 运行时；
//  3. 用 EntryEntryAbilityViewController 承载 EntryAbility 实例。
//
//  BUNDLE_NAME 必须与 AppScope/app.json5 的 bundleName 完全一致。
//

#import "AppDelegate.h"
#import "EntryEntryAbilityViewController.h"
#import <libarkui_ios/StageApplication.h>
#import <libarkui_ios/BridgePlugin.h>

#define BUNDLE_DIRECTORY @"arkui-x"
#define BUNDLE_NAME @"com.wuyin.video"
#define MODULE_NAME @"entry"
#define ABILITY_NAME @"EntryAbility"

@interface AppDelegate () <IMessageListener>
@property (nonatomic, strong) BridgePlugin *platformBridge;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [StageApplication configModuleWithBundleDirectory:BUNDLE_DIRECTORY];
    [StageApplication launchApplication];

    NSString *instanceName = [NSString stringWithFormat:@"%@:%@:%@", BUNDLE_NAME, MODULE_NAME, ABILITY_NAME];
    EntryEntryAbilityViewController *mainView = [[EntryEntryAbilityViewController alloc] initWithInstanceName:instanceName];
    [self setRootViewController:mainView];

    // ArkUI-X iOS 没有实现 @ohos.net.http；用平台桥接提供 NSURLSession 网络请求。
    self.platformBridge = [[BridgePlugin alloc] initBridgePlugin:@"WuyinPlatformBridge"
                                                      instanceId:[mainView getInstanceId]];
    self.platformBridge.messageListener = self;
    return YES;
}

- (id)onMessage:(id)data {
    NSDictionary *payload = nil;
    if ([data isKindOfClass:[NSDictionary class]]) {
        payload = (NSDictionary *)data;
    } else if ([data isKindOfClass:[NSString class]]) {
        NSData *jsonData = [(NSString *)data dataUsingEncoding:NSUTF8StringEncoding];
        payload = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
    }
    if (![payload isKindOfClass:[NSDictionary class]]) {
        return @"-1\ninvalid payload";
    }
    if (![payload[@"action"] isEqualToString:@"http"]) {
        return @"-1\nunsupported action";
    }

    NSString *urlString = payload[@"url"];
    NSString *method = payload[@"method"] ?: @"GET";
    NSString *body = payload[@"body"];
    NSURL *url = [NSURL URLWithString:urlString ?: @""];
    if (url == nil) {
        return @"-1\ninvalid url";
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method;
    request.timeoutInterval = 20.0;
    id headers = payload[@"headers"];
    if ([headers isKindOfClass:[NSString class]]) {
        NSData *headerData = [(NSString *)headers dataUsingEncoding:NSUTF8StringEncoding];
        headers = [NSJSONSerialization JSONObjectWithData:headerData options:0 error:nil];
    }
    if ([headers isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in headers) {
            [request setValue:[NSString stringWithFormat:@"%@", headers[key]] forHTTPHeaderField:key];
        }
    }
    if ([body isKindOfClass:[NSString class]] && body.length > 0) {
        request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    }

    __block NSData *responseData = nil;
    __block NSHTTPURLResponse *httpResponse = nil;
    __block NSError *responseError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            responseData = data;
            httpResponse = (NSHTTPURLResponse *)response;
            responseError = error;
            dispatch_semaphore_signal(semaphore);
          }];
    [task resume];
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)));

    if (responseData == nil) {
        NSString *message = responseError.localizedDescription ?: @"timeout";
        return [NSString stringWithFormat:@"-1\n%@", message];
    }
    NSString *text = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] ?: @"";
    return [NSString stringWithFormat:@"%ld\n%@", (long)httpResponse.statusCode, text];
}

// wuyin://player?yhm=... 等外部唤起。ArkUI-X iOS SDK 未暴露稳定的
// “向运行中的 Ability 投递 Want” 的 Objective-C 接口，这里只记录日志；
// ArkTS 侧 EntryAbility 仍可从冷启动的 launchOptions 解析分享参数。
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    NSLog(@"WuYinVideo openURL: %@", url.absoluteString);
    return YES;
}

- (void)setRootViewController:(UIViewController *)viewController {
    CGRect bounds = [UIScreen mainScreen].bounds;
    if (CGRectIsEmpty(bounds)) {
        bounds = CGRectMake(0, 0, 390, 844);
    }
    self.window = [[UIWindow alloc] initWithFrame:bounds];
    self.window.backgroundColor = [UIColor blackColor];
    // ArkUI-X 的 StageViewController 直接作为 root，避免被 UINavigationController
    // 以 0x0 布局导致 ArkUI surface 不显示。
    self.window.rootViewController = viewController;
    [self.window makeKeyAndVisible];
    viewController.view.frame = self.window.bounds;
    [self.window layoutIfNeeded];
}

@end
