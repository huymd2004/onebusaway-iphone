/**
 * Copyright (C) 2009 bdferris <bdferris@onebusaway.org>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *         http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "OBAApplicationDelegate.h"
@import SystemConfiguration;
@import GoogleAnalytics;
@import OBAKit;
@import SVProgressHUD;

#import "OBANavigationTargetAware.h"

#import "OBASearchController.h"
#import "OBAStopViewController.h"

#import "OneBusAway-Swift.h"

#import "OBAAnalytics.h"
#import "Apptentive.h"

#import "OBAApplicationUI.h"
#import "OBAClassicApplicationUI.h"
#import "OBADrawerUI.h"
#import "EXTScope.h"

static NSString *const kTrackingId = @"UA-2423527-17";
static NSString *const kApptentiveKey = @"3363af9a6661c98dec30fedea451a06dd7d7bc9f70ef38378a9d5a15ac7d4926";

@interface OBAApplicationDelegate () <OBABackgroundTaskExecutor, OBARegionHelperDelegate, RegionListDelegate>
@property(nonatomic,strong) UINavigationController *regionNavigationController;
@property(nonatomic,strong) RegionListViewController *regionListViewController;
@property(nonatomic,strong) id regionObserver;
@property(nonatomic,strong) id recentStopsObserver;
@property(nonatomic,strong) id<OBAApplicationUI> applicationUI;
@property(nonatomic,strong) OBADeepLinkRouter *deepLinkRouter;
@end

@implementation OBAApplicationDelegate

- (id)init {
    self = [super init];

    if (self) {
        self.regionObserver = [[NSNotificationCenter defaultCenter] addObserverForName:kOBAApplicationSettingsRegionRefreshNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            [OBAApplication sharedApplication].modelDao.automaticallySelectRegion = YES;
            [[OBAApplication sharedApplication].regionHelper updateNearestRegion];
            [[GAI sharedInstance].defaultTracker set:[GAIFields customDimensionForIndex:2] value:OBAStringFromBool(YES)];
        }];
        @weakify(self);
        self.recentStopsObserver = [[NSNotificationCenter defaultCenter] addObserverForName:OBAMostRecentStopsChangedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            @strongify(self);
            [self updateShortcutItemsForRecentStops];
        }];

        _deepLinkRouter = [self.class setupDeepLinkRouterWithModelDAO:[OBAApplication sharedApplication].modelDao appDelegate:self];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reachabilityChanged:) name:kReachabilityChangedNotification object:nil];

        NSDictionary *appDefaults = @{ OBAOptInToTrackingDefaultsKey: @(YES) };
        [[OBAApplication sharedApplication] startWithAppDefaults:appDefaults];

        [OBAApplication sharedApplication].regionHelper.delegate = self;
    }

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self.regionObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:self.recentStopsObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kReachabilityChangedNotification object:nil];
}

- (void)navigateToTarget:(OBANavigationTarget *)navigationTarget {
    [self performSelector:@selector(_navigateToTargetInternal:) withObject:navigationTarget afterDelay:0];
}

- (void)_constructUI {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor blackColor];

    self.applicationUI = [[OBAClassicApplicationUI alloc] init];
//    self.applicationUI = [[OBADrawerUI alloc] init];

    [OBATheme setAppearanceProxies];

    self.window.rootViewController = self.applicationUI.rootViewController;

    if ([OBAApplication sharedApplication].modelDao.automaticallySelectRegion && [OBAApplication sharedApplication].locationManager.locationServicesEnabled) {
        [[OBAApplication sharedApplication].regionHelper updateNearestRegion];
    }
    else {
        [[OBAApplication sharedApplication].regionHelper updateRegion];
    }

    [self.window makeKeyAndVisible];
}

#pragma mark - UIApplication Methods

- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithExpirationHandler:(void (^)(void))handler {
    return [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:handler];
}

- (UIBackgroundTaskIdentifier)endBackgroundTask:(UIBackgroundTaskIdentifier)task {
    [[UIApplication sharedApplication] endBackgroundTask:task];
    return UIBackgroundTaskInvalid;
}

#pragma mark UIApplicationDelegate Methods

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Register a background handler with the model service
    [OBAModelService addBackgroundExecutor:self];

    // Configure the Apptentive feedback system
    [Apptentive sharedConnection].APIKey = kApptentiveKey;

    // Set up Google Analytics. User must be able to opt out of tracking.
    [GAI sharedInstance].optOut = ![[NSUserDefaults standardUserDefaults] boolForKey:OBAOptInToTrackingDefaultsKey];
    [GAI sharedInstance].trackUncaughtExceptions = YES;
    [GAI sharedInstance].logger.logLevel = kGAILogLevelWarning;

    //don't report to Google Analytics when developing
#ifdef DEBUG
    [[GAI sharedInstance] setDryRun:YES];
#endif

    [[GAI sharedInstance].defaultTracker set:[GAIFields customDimensionForIndex:1] value:[OBAApplication sharedApplication].modelDao.currentRegion.regionName];

    [OBAAnalytics configureVoiceOverStatus];

    [self _constructUI];

    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    CLLocation *location = [OBAApplication sharedApplication].locationManager.currentLocation;

    if (location) {
        [OBAApplication sharedApplication].modelDao.mostRecentLocation = location;
    }
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [[OBAApplication sharedApplication] startReachabilityNotifier];

    [self.applicationUI applicationDidBecomeActive];

    [GAI sharedInstance].optOut = ![[NSUserDefaults standardUserDefaults] boolForKey:OBAOptInToTrackingDefaultsKey];

    NSString *label = [NSString stringWithFormat:@"API Region: %@", [OBAApplication sharedApplication].modelDao.currentRegion.regionName];

    [OBAAnalytics reportEventWithCategory:OBAAnalyticsCategoryAppSettings action:@"configured_region" label:label value:nil];

    [OBAAnalytics reportEventWithCategory:OBAAnalyticsCategoryAppSettings action:@"general" label:[NSString stringWithFormat:@"Set Region Automatically: %@", OBAStringFromBool([OBAApplication sharedApplication].modelDao.automaticallySelectRegion)] value:nil];

    [[Apptentive sharedConnection] engage:@"app_became_active" fromViewController:nil];
}

- (void)applicationWillResignActive:(UIApplication *)application {
    [[OBAApplication sharedApplication] stopReachabilityNotifier];
}

#pragma mark - Deep Linking

#define kDeepLinkTripPattern @"\\/regions\\/(\\d+).*\\/stops\\/(.*)\\/arrivals\\/?"

+ (OBADeepLinkRouter*)setupDeepLinkRouterWithModelDAO:(OBAModelDAO*)modelDAO appDelegate:(OBAApplicationDelegate*)appDelegate {
    OBADeepLinkRouter *deepLinkRouter = [[OBADeepLinkRouter alloc] init];

    [deepLinkRouter routePattern:kDeepLinkTripPattern toAction:^(NSArray<NSString *> *matchGroupResults, NSURLComponents *URLComponents) {
        OBAGuard(matchGroupResults.count == 2) else {
            return;
        }

        NSInteger regionIdentifier = [matchGroupResults[0] integerValue];
        NSString *stopID = matchGroupResults[1];
        NSDictionary *queryItems = [NSURLQueryItem oba_dictionaryFromQueryItems:URLComponents.queryItems];

        OBATripDeepLink *tripDeepLink = [[OBATripDeepLink alloc] init];
        tripDeepLink.regionIdentifier = regionIdentifier;
        tripDeepLink.stopID = stopID;
        tripDeepLink.tripID = queryItems[@"trip_id"];
        tripDeepLink.serviceDate = [queryItems[@"service_date"] longLongValue];
        tripDeepLink.stopSequence = [queryItems[@"stop_sequence"] integerValue];

        [SVProgressHUD show];

        [[OBAApplication sharedApplication].modelService requestArrivalAndDepartureWithTripDeepLink:tripDeepLink].then(^(OBAArrivalAndDepartureV2 *arrivalAndDeparture) {
            tripDeepLink.name = arrivalAndDeparture.bestAvailableNameWithHeadsign;

            // OK, it works, so write it into the model DAO.
            [[OBAApplication sharedApplication].modelDao addSharedTrip:tripDeepLink];

            OBANavigationTarget *target = [OBANavigationTarget navigationTarget:OBANavigationTargetTypeRecentStops];
            target.object = tripDeepLink;
            [appDelegate navigateToTarget:target];
        }).catch(^(NSError *error) {
            NSString *body = [NSString stringWithFormat:NSLocalizedString(@"Sorry, we can't show you that shared trip. If this continues, please let us know. Error: %@", @"Error message displayed to the user when something goes wrong with a just-tapped shared trip."), error.localizedDescription];
            [AlertPresenter showWarning:NSLocalizedString(@"Something Went Wrong",) body:body];
        }).always(^{
            [SVProgressHUD dismiss];
        });
    }];

    return deepLinkRouter;
}

- (BOOL)application:(UIApplication *)application continueUserActivity:(NSUserActivity *)userActivity restorationHandler:(void (^)(NSArray *))restorationHandler {

    NSURL *URL = userActivity.webpageURL;
    if (!URL) {
        return NO;
    }

    return [self.deepLinkRouter performActionForURL:URL];
}

#pragma mark - Shortcut Items

- (void)application:(UIApplication *)application performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem completionHandler:(void (^)(BOOL))completionHandler {

    [self.applicationUI performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem completionHandler:(void (^)(BOOL))completionHandler];
}

- (void)updateShortcutItemsForRecentStops {
    NSMutableArray *dynamicShortcuts = [NSMutableArray array];
    UIApplicationShortcutIcon *clockIcon = [UIApplicationShortcutIcon iconWithType:UIApplicationShortcutIconTypeTime];

    for (OBAStopAccessEventV2 *stopEvent in [OBAApplication sharedApplication].modelDao.mostRecentStops) {
        UIApplicationShortcutItem *shortcutItem =
                [[UIApplicationShortcutItem alloc] initWithType:kApplicationShortcutRecents
                                                 localizedTitle:stopEvent.title
                                              localizedSubtitle:nil
                                                           icon:clockIcon
                                                       userInfo:@{ @"stopIds": stopEvent.stopIds }];
        [dynamicShortcuts addObject:shortcutItem];
    }

    [UIApplication sharedApplication].shortcutItems = [dynamicShortcuts oba_pickFirst:4];
}

- (void)_navigateToTargetInternal:(OBANavigationTarget *)navigationTarget {
    [[OBAApplication sharedApplication].references clear];

    [self.applicationUI navigateToTargetInternal:navigationTarget];
}

#pragma mark - Reachability

- (void)reachabilityChanged:(NSNotification*)note {

    OBAReachability *reachability = note.object;

    if (!reachability.isReachable) {
        [AlertPresenter showWarning:NSLocalizedString(@"Cannot connect to the Internet", @"Reachability alert title") body:NSLocalizedString(@"Please check your Internet connection and try again.", @"Reachability alert body")];
    }
}

#pragma mark - RegionListDelegate

- (void)regionSelected {
    [_regionNavigationController removeFromParentViewController];
    _regionNavigationController = nil;
    _regionListViewController = nil;

    self.window.rootViewController = self.applicationUI.rootViewController;
    [self.window makeKeyAndVisible];
}

#pragma mark - OBARegionHelperDelegate

- (void)regionHelperShowRegionListController:(OBARegionHelper *)regionHelper {
    _regionListViewController = [[RegionListViewController alloc] init];
    _regionListViewController.delegate = self;
    _regionNavigationController = [[UINavigationController alloc] initWithRootViewController:_regionListViewController];

    self.window.rootViewController = _regionNavigationController;
}

@end
