//
//  ZBConsoleViewController.m
//  Zebra
//
//  Created by Wilson Styres on 2/6/19.
//  Copyright © 2019 Wilson Styres. All rights reserved.
//

#import "ZBConsoleViewController.h"

#import <ZBAppDelegate.h>
#import <ZBDevice.h>
#import <ZBLog.h>
#import <ZBSettings.h>
#import <Extensions/UIFont+Zebra.h>
#import <Queue/ZBQueue.h>
#import <Tabs/ZBTabBarController.h>
#import <Tabs/Packages/Helpers/ZBPackage.h>
#import <Theme/ZBThemeManager.h>

@import FirebaseCrashlytics;
@import LNPopupController;

@interface ZBConsoleViewController () {
    NSMutableArray *applicationBundlePaths;
    NSMutableArray *installedPackageIdentifiers;
    ZBQueue *queue;
    ZBStage currentStage;
    BOOL respringRequired;
    BOOL updateIconCache;
    BOOL zebraRestartRequired;
    int autoFinishDelay;
}
@property (strong, nonatomic) IBOutlet UIButton *completeButton;
@property (strong, nonatomic) IBOutlet UIBarButtonItem *closeButton;
@property (strong, nonatomic) IBOutlet UITextView *consoleView;
@end

@implementation ZBConsoleViewController

#pragma mark - Initializers

- (id)init {
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Main" bundle: nil];
    self = [storyboard instantiateViewControllerWithIdentifier:@"consoleViewController"];
    
    if (self) {
        self.title = NSLocalizedString(@"Console", @"");
        self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
        self.navigationItem.hidesBackButton = YES;
        
        currentStage = -1;
        applicationBundlePaths = [NSMutableArray new];
        installedPackageIdentifiers = [NSMutableArray new];
        queue = [ZBQueue sharedQueue];
        respringRequired = NO;
        updateIconCache = NO;
        zebraRestartRequired = NO;
        autoFinishDelay = 3;
    }
    
    return self;
}

#pragma mark - View Controller Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    NSError *error = NULL;
    if ([ZBDevice isSlingshotBroken:&error]) {
        [ZBAppDelegate sendAlertFrom:self message:error.localizedDescription];
    }
    
    [self setupView];
    [self performSelectorInBackground:@selector(performTasks) withObject:NULL];
}

- (void)setupView {
    ZBAccentColor color = [ZBSettings accentColor];
    ZBInterfaceStyle style = [ZBSettings interfaceStyle];
    if (color == ZBAccentColorMonochrome) { // Flip the colors for readability
        self.completeButton.backgroundColor = [UIColor whiteColor];
        [self.completeButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    } else {
        self.completeButton.backgroundColor = [ZBThemeManager getAccentColor:color forInterfaceStyle:style] ?: [UIColor systemBlueColor];
    }
    
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *app = [self.navigationController.navigationBar.standardAppearance copy];
        app.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        app.titleTextAttributes = @{NSForegroundColorAttributeName:[UIColor whiteColor]};
        self.navigationController.navigationBar.standardAppearance = app;
        self.navigationController.navigationBar.scrollEdgeAppearance = app;
        self.navigationController.navigationBar.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    else {
        self.navigationController.navigationBar.titleTextAttributes = @{NSForegroundColorAttributeName:[UIColor whiteColor]};
    }
    self.navigationController.navigationBar.barStyle = UIBarStyleBlack;
    
    [[[[ZBAppDelegate tabBarController] popupContentView] popupInteractionGestureRecognizer] setDelegate:self];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    return NO;
}

#pragma mark - Performing Tasks

- (void)performTasks {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] setIdleTimerDisabled:YES];
    });
    
    NSArray <NSArray *> *commands = queue.commands;
    if (commands.count == 0) {
        [self writeToConsole:@"There are no actions to perform." atLevel:ZBLogLevelError];
        return;
    }
    
    for (NSArray *stageCommand in commands) {
        ZBStage stage = (ZBStage)stageCommand[0];
        [self setStage:stage];
        
        ZBCommand *command = stageCommand[1];
        switch (currentStage) {
            case ZBStageRemove:
                // Add all the removed package IDs to look for app bundles and substrate tweaks
                for (int i = 1; i < command.arguments.count; i++) {
                    NSString *packageID = command.arguments[i];
                    NSString *bundlePath = [ZBPackage applicationBundlePathForIdentifier:packageID];
                    if (bundlePath) {
                        updateIconCache = YES;
                        [applicationBundlePaths addObject:bundlePath];
                    }
                    
                    if (!respringRequired) respringRequired = [ZBPackage respringRequiredFor:packageID];
                }
                break;
            case ZBStageInstall:
            case ZBStageReinstall:
            case ZBStageUpgrade:
            case ZBStageDowngrade:
                for (int i = 1; i < command.arguments.count; i++) {
                    [installedPackageIdentifiers addObject:command.arguments[i]];
                }
                break;
            default:
                break;
        }
        
        [command setDelegate:self];
        [command execute];
    }
    
    for (NSString *packageID in installedPackageIdentifiers) {
        NSString *bundlePath = [ZBPackage applicationBundlePathForIdentifier:packageID];
        if (bundlePath && ![applicationBundlePaths containsObject:bundlePath]) {
            updateIconCache = YES;
            [applicationBundlePaths addObject:bundlePath];
        }
        
        if (!respringRequired) {
            respringRequired = [ZBPackage respringRequiredFor:packageID];
        }
    }
    
    [self removeAllDebs];
    [self finishTasks];
}

- (void)finishTasks {
    [applicationBundlePaths removeAllObjects];
    
    NSMutableArray *wishlist = [[ZBSettings wishlist] mutableCopy];
    [wishlist removeObjectsInArray:installedPackageIdentifiers];
    
    [installedPackageIdentifiers removeAllObjects];
    
    [self setStage:ZBStageFinished];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
    });
}

#pragma mark - Button Actions

- (void)cancel {
    [self removeAllDebs];
    [self setStage:ZBStageFinished];
}

- (void)close {
    [[ZBAppDelegate tabBarController] dismissPopupBarAnimated:YES completion:nil];
}

- (IBAction)cancelOrClose:(id)sender {
    if (currentStage == ZBStageFinished) {
        [self close];
    } else {
        [self cancel];
    }
}


#pragma mark - Package Finishing Actions

- (void)updateIconCaches {
    [self writeToConsole:NSLocalizedString(@"Updating icon cache asynchronously...", @"") atLevel:ZBLogLevelInfo];
    
    if (![ZBDevice needsSimulation]) {
        [ZBDevice uicache:applicationBundlePaths];
    } else {
        [self writeToConsole:NSLocalizedString(@"uicache is not available on the simulator", @"") atLevel:ZBLogLevelWarning];
    }
}

- (void)closeZebra {
    [ZBDevice exitZebraAfter:3];
    if (![ZBDevice needsSimulation]) {
        if (applicationBundlePaths.count > 1) {
            [self updateIconCaches];
        } else {
            [ZBDevice uicache:@[@"/Applications/Zebra.app"]];
        }
    }
}

- (void)restartSpringBoard {
    if (![ZBDevice needsSimulation]) {
        [ZBDevice restartSpringBoard];
    } else {
        [self close];
    }
}

#pragma mark - Stage Management

- (void)setStage:(ZBStage)stage {
    currentStage = stage;
    
    switch (stage) {
        case ZBStageRemove:
            [self updateTitle:NSLocalizedString(@"Removing", @"")];
            [self writeToConsole:NSLocalizedString(@"Removing Packages...", @"") atLevel:ZBLogLevelInfo];
            break;
        case ZBStageInstall:
            [self updateTitle:NSLocalizedString(@"Installing", @"")];
            [self writeToConsole:NSLocalizedString(@"Installing Packages...", @"") atLevel:ZBLogLevelInfo];
            break;
        case ZBStageReinstall:
            [self updateTitle:NSLocalizedString(@"Reinstalling", @"")];
            [self writeToConsole:NSLocalizedString(@"Reinstalling Packages...", @"") atLevel:ZBLogLevelInfo];
            break;
        case ZBStageUpgrade:
            [self updateTitle:NSLocalizedString(@"Upgrading", @"")];
            [self writeToConsole:NSLocalizedString(@"Upgrading Packages...", @"") atLevel:ZBLogLevelInfo];
            break;
        case ZBStageFinished:
            [self updateTitle:NSLocalizedString(@"Complete", @"")];
            [self writeToConsole:NSLocalizedString(@"Finished!", @"") atLevel:ZBLogLevelInfo];
            [self updateCompleteButton];
            break;
        default:
            break;
    }
}

- (BOOL)isValidPackageID:(NSString *)packageID {
    return ![packageID hasPrefix:@"-"] && ![packageID isEqualToString:@"install"] && ![packageID isEqualToString:@"remove"];
}

- (void)removeAllDebs {
    ZBLog(@"[Zebra] Removing all debs");
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:[ZBAppDelegate debsLocation]];
    NSString *file;

    while (file = [enumerator nextObject]) {
        NSError *error = nil;
        BOOL result = [[NSFileManager defaultManager] removeItemAtPath:[[ZBAppDelegate debsLocation] stringByAppendingPathComponent:file] error:&error];

        if (!result && error) {
            NSLog(@"[Zebra] Error while removing %@: %@", file, error);
        }
    }
}

#pragma mark - UI Updates

- (void)updateTitle:(NSString *)title {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setTitle:[NSString stringWithFormat:@" %@ ", title]];
    });
}

- (void)writeToConsole:(NSString *)str atLevel:(ZBLogLevel)level {
    if (str == nil)
        return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        UIColor *color;
        UIFont *font;
        switch (level) {
            case ZBLogLevelDescript:
                color = [UIColor whiteColor];
                font = UIFont.monospaceFont;
                break;
            case ZBLogLevelInfo:
                color = [UIColor whiteColor];
                font = UIFont.boldMonospaceFont;
                break;
            case ZBLogLevelError:
                color = [UIColor redColor];
                font = UIFont.boldMonospaceFont;
                break;
            case ZBLogLevelWarning:
                color = [UIColor yellowColor];
                font = UIFont.monospaceFont;
                break;
        }

        NSDictionary *attrs = @{ NSForegroundColorAttributeName: color, NSFontAttributeName: font };
        
        //Adds a newline if there is not already one
        NSString *string = [str copy];
        if (![string hasSuffix:@"\n"]) {
            string = [str stringByAppendingString:@"\n"];
        }
        
        if (string == nil) {
            return;
        }
        
        [self.consoleView.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:string attributes:attrs]];

        if (self.consoleView.text.length) {
            NSRange bottom = NSMakeRange(self.consoleView.text.length - 1, 1);
            [self.consoleView scrollRangeToVisible:bottom];
        }
    });
}

- (void)updateCompleteButton {
    if ([ZBSettings wantsFinishAutomatically]) { // automatically finish after 3 secs
        dispatch_block_t finishBlock = nil;
        
        finishBlock = ^{
            if (self->respringRequired) {
                [self restartSpringBoard];
            } else if (self->zebraRestartRequired) {
                [self closeZebra];
            } else {
                [self close];
            }
        };

        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self->autoFinishDelay * NSEC_PER_SEC));
        dispatch_after(popTime, dispatch_get_main_queue(), finishBlock);
    } else { // manual finish
        dispatch_async(dispatch_get_main_queue(), ^{
            self.completeButton.hidden = NO;
            
            if (self->respringRequired) {
                [self.completeButton setTitle:NSLocalizedString(@"Restart SpringBoard", @"") forState:UIControlStateNormal];
                [self.completeButton addTarget:self action:@selector(restartSpringBoard) forControlEvents:UIControlEventTouchUpInside];
            }
            else if (self->zebraRestartRequired) {
                [self.completeButton setTitle:NSLocalizedString(@"Close Zebra", @"") forState:UIControlStateNormal];
                [self.completeButton addTarget:self action:@selector(closeZebra) forControlEvents:UIControlEventTouchUpInside];
            }
            else {
                [self.completeButton setTitle:NSLocalizedString(@"Done", @"") forState:UIControlStateNormal];
                [self.completeButton addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
            }
        });
    }
}

#pragma mark - Command Delegate

- (void)receivedData:(NSString *)data {
    [self writeToConsole:data atLevel:ZBLogLevelDescript];
}

- (void)receivedErrorData:(NSString *)data {
    if ([data containsString:@"stable CLI interface"]) return;
    if ([data containsString:@"postinst"]) return;

    [[FIRCrashlytics crashlytics] logWithFormat:@"DPKG/APT Error: %@", data];
    if ([data rangeOfString:@"warning"].location != NSNotFound || [data hasPrefix:@"W:"]) {
        [self writeToConsole:data atLevel:ZBLogLevelWarning];
    } else {
        [self writeToConsole:data atLevel:ZBLogLevelError];
    }
}

@end
