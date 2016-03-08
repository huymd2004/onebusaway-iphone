//
//  OBAParallaxTableHeaderView.m
//  org.onebusaway.iphone
//
//  Created by Aaron Brethorst on 3/4/16.
//  Copyright © 2016 OneBusAway. All rights reserved.
//

#import "OBAParallaxTableHeaderView.h"
#import <Masonry/Masonry.h>
#import <PromiseKit/PromiseKit.h>
#import <DateTools/DateTools.h>
#import "OBAArrivalsAndDeparturesForStopV2.h"
#import "OBAMapHelpers.h"
#import "OBAImageHelpers.h"
#import "OBAStopIconFactory.h"
#import "OBADateHelpers.h"

#define kHeaderImageViewBackgroundColor [UIColor colorWithWhite:0.f alpha:0.4f]

@interface OBAParallaxTableHeaderView ()
@property(nonatomic,strong,readwrite) UIImageView *headerImageView;
@property(nonatomic,strong,readwrite) UILabel *stopInformationLabel;
@property(nonatomic,strong,readwrite) UIStackView *directionsAndDistanceView;
@end

@implementation OBAParallaxTableHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self) {
        self.backgroundColor = [OBATheme backgroundColor];

        _headerImageView = ({
            UIImageView *imageView = [[UIImageView alloc] initWithFrame:self.bounds];
            imageView.backgroundColor = kHeaderImageViewBackgroundColor;
            imageView.contentMode = UIViewContentModeScaleAspectFill;
            imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
            imageView.alpha = 1.f;
            imageView;
        });
        [self addSubview:_headerImageView];

        _stopInformationLabel = ({
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
            [self.class applyHeaderStylingToLabel:label];
            label.numberOfLines = 0;
            label.autoresizingMask = UIViewAutoresizingFlexibleHeight|UIViewAutoresizingFlexibleWidth;

            label;
        });

        _directionsAndDistanceView = ({
            UIActivityIndicatorView *activity = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
            [activity startAnimating];
            UILabel *loading = [[UILabel alloc] initWithFrame:CGRectZero];
            [self.class applyHeaderStylingToLabel:loading];
            loading.text = NSLocalizedString(@"Determining walk time", @"");
            UIStackView *sv = [[UIStackView alloc] initWithArrangedSubviews:@[activity, loading]];
            sv;
        });

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_stopInformationLabel, _directionsAndDistanceView]];
        stack.spacing = [OBATheme defaultPadding];
        stack.axis = UILayoutConstraintAxisVertical;
        [self addSubview:stack];
        [stack mas_makeConstraints:^(MASConstraintMaker *make) {
            make.edges.equalTo(self).insets(UIEdgeInsetsMake([OBATheme defaultPadding], [OBATheme defaultPadding], [OBATheme defaultPadding], [OBATheme defaultPadding]));
        }];
    }
    return self;
}

#pragma mark - Public

- (void)populateTableHeaderFromArrivalsAndDeparturesModel:(OBAArrivalsAndDeparturesForStopV2*)result {

    if (self.highContrastMode) {
        self.headerImageView.backgroundColor = OBAGREEN;
    }
    else {
        MKMapSnapshotter *snapshotter = ({
            MKMapSnapshotOptions *options = [[MKMapSnapshotOptions alloc] init];
            options.region = [OBAMapHelpers coordinateRegionWithCenterCoordinate:result.stop.coordinate zoomLevel:15 viewSize:self.headerImageView.frame.size];
            options.size = self.headerImageView.frame.size;
            options.scale = [[UIScreen mainScreen] scale];
            [[MKMapSnapshotter alloc] initWithOptions:options];
        });

        [snapshotter promise].thenInBackground(^(MKMapSnapshot *snapshot) {
            UIImage *annotatedImage = [OBAImageHelpers draw:[OBAStopIconFactory getIconForStop:result.stop]
                                                       onto:snapshot.image
                                                    atPoint:[snapshot pointForCoordinate:result.stop.coordinate]];
            return [OBAImageHelpers colorizeImage:annotatedImage withColor:kHeaderImageViewBackgroundColor];
        }).then(^(UIImage *colorizedImage) {
            self.headerImageView.image = colorizedImage;
        });
    }

    NSMutableArray *stopMetadata = [[NSMutableArray alloc] init];

    if (result.stop.name) {
        [stopMetadata addObject:result.stop.name];
    }

    NSString *stopNumber = nil;

    if (result.stop.direction) {
        stopNumber = [NSString stringWithFormat:@"%@ #%@ - %@ %@", NSLocalizedString(@"Stop", @"text"), result.stop.code, result.stop.direction, NSLocalizedString(@"bound", @"text")];
    }
    else {
        stopNumber = [NSString stringWithFormat:@"%@ #%@", NSLocalizedString(@"Stop", @"text"), result.stop.code];
    }
    [stopMetadata addObject:stopNumber];

    NSString *stopRoutes = [result.stop routeNamesAsString];
    if (stopRoutes) {
        [stopMetadata addObject:[NSString stringWithFormat:NSLocalizedString(@"Routes: %@", @""), stopRoutes]];
    }

    self.stopInformationLabel.text = [stopMetadata componentsJoinedByString:@"\r\n"];
}

- (void)loadETAToLocation:(CLLocationCoordinate2D)coordinate {

    static NSUInteger iterations = 0;

    [CLLocationManager until:^BOOL(CLLocation *location) {
        iterations += 1;
        if (iterations >= 5) {
            return YES;
        }
        else {
            return location.horizontalAccuracy <= kCLLocationAccuracyNearestTenMeters;
        }
    }].thenInBackground(^(CLLocation* currentLocation) {
        MKPlacemark *sourcePlacemark = [[MKPlacemark alloc] initWithCoordinate:currentLocation.coordinate addressDictionary:nil];
        MKPlacemark *destinationPlacemark = [[MKPlacemark alloc] initWithCoordinate:coordinate addressDictionary:nil];
        MKDirections *directions = [[MKDirections alloc] initWithRequest:({
            MKDirectionsRequest *r = [[MKDirectionsRequest alloc] init];
            r.source = [[MKMapItem alloc] initWithPlacemark:sourcePlacemark];
            r.destination = [[MKMapItem alloc] initWithPlacemark:destinationPlacemark];
            r.transportType = MKDirectionsTransportTypeWalking;
            r;
        })];
        return [directions calculateETA];
    }).then(^(MKETAResponse* ETA) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.numberOfLines = 1;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.8f;
        [OBAParallaxTableHeaderView applyHeaderStylingToLabel:label];

        label.text = [NSString stringWithFormat:@"Walk to stop: %@: %.0f min, arriving at %@.", [OBAMapHelpers stringFromDistance:ETA.distance],
                      [[NSDate dateWithTimeIntervalSinceNow:ETA.expectedTravelTime] minutesUntil],
                      [OBADateHelpers formatShortTimeNoDate:ETA.expectedArrivalDate]];

        [self.directionsAndDistanceView.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
        [self.directionsAndDistanceView addArrangedSubview:label];
    }).catch(^(NSError *error) {
        NSLog(@"Unable to calculate walk time to stop: %@", error);
        [self.directionsAndDistanceView.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    }).finally(^{
        iterations = 0;
    });
}

#pragma mark - Private Helpers

+ (void)applyHeaderStylingToLabel:(UILabel*)label {
    label.textColor = [UIColor whiteColor];
    label.shadowColor = [UIColor colorWithWhite:0.f alpha:0.5f];
    label.shadowOffset = CGSizeMake(0, 1);
    label.font = [OBATheme bodyFont];
}

@end
