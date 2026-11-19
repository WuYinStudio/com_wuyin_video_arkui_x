/*
 * Copyright (c) 2023 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "EntryEntryAbilityViewController.h"

@interface EntryEntryAbilityViewController ()

@end

@implementation EntryEntryAbilityViewController
- (instancetype)initWithInstanceName:(NSString *)instanceName {
    self = [super initWithInstanceName:instanceName];
    if (self) {

    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // ArkUI-X 负责页面内容；UIKit 提供原生窗口语义色、状态栏和安全区。
    // 保留 UIRectEdgeNone，避免 ArkUI Surface 被导航栏/状态栏重复扣除安全区。
    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.extendedLayoutIncludesOpaqueBars = YES;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.view.tintColor = UIColor.systemBlueColor;
    self.view.insetsLayoutMarginsFromSafeArea = YES;
    self.navigationController.navigationBarHidden = YES;
    [self setNeedsStatusBarAppearanceUpdate];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    if (@available(iOS 13.0, *)) {
        return self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
            ? UIStatusBarStyleLightContent : UIStatusBarStyleDarkContent;
    }
    return UIStatusBarStyleDefault;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            self.view.backgroundColor = UIColor.systemBackgroundColor;
            [self setNeedsStatusBarAppearanceUpdate];
        }
    }
}
@end
