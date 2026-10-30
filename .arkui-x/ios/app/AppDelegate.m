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

#define BUNDLE_DIRECTORY @"arkui-x"
#define BUNDLE_NAME @"com.wuyin.video"
#define MODULE_NAME @"entry"
#define ABILITY_NAME @"EntryAbility"

@interface AppDelegate ()

@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [StageApplication configModuleWithBundleDirectory:BUNDLE_DIRECTORY];
    [StageApplication launchApplication];

    NSString *instanceName = [NSString stringWithFormat:@"%@:%@:%@", BUNDLE_NAME, MODULE_NAME, ABILITY_NAME];
    EntryEntryAbilityViewController *mainView = [[EntryEntryAbilityViewController alloc] initWithInstanceName:instanceName];
    [self setRootViewController:mainView];
    return YES;
}

// wuyin://player?yhm=... 等外部唤起。ArkUI-X iOS SDK 未暴露稳定的
// “向运行中的 Ability 投递 Want” 的 Objective-C 接口，这里只记录日志；
// ArkTS 侧 EntryAbility 仍可从冷启动的 launchOptions 解析分享参数。
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    NSLog(@"WuYinVideo openURL: %@", url.absoluteString);
    return YES;
}

- (void)setRootViewController:(UIViewController *)viewController {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor blackColor];
    UINavigationController *navi = [[UINavigationController alloc] initWithRootViewController:viewController];
    // 播放器/首页自带导航栏与沉浸式布局，隐藏系统导航栏避免出现双标题栏。
    navi.navigationBarHidden = YES;
    self.window.rootViewController = navi;
    [self.window makeKeyAndVisible];
}

@end
