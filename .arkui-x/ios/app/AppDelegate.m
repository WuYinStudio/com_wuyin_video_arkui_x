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
    NSLog(@"WUYIN window=%@ view=%@", NSStringFromCGRect(self.window.bounds), NSStringFromCGRect(viewController.view.frame));
#if TARGET_OS_SIMULATOR
    UILabel *debugLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 80, MAX(200, bounds.size.width - 40), 120)];
    debugLabel.numberOfLines = 0;
    debugLabel.textColor = [UIColor greenColor];
    debugLabel.backgroundColor = [UIColor redColor];
    debugLabel.text = [NSString stringWithFormat:@"WUYIN DEBUG\nwindow=%@\nview=%@",
                       NSStringFromCGRect(self.window.bounds), NSStringFromCGRect(viewController.view.frame)];
    [viewController.view addSubview:debugLabel];
    [viewController.view bringSubviewToFront:debugLabel];
#endif
}

@end
