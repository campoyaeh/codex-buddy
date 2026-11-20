#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *UpdaterCurrentVersion(void);
FOUNDATION_EXPORT NSComparisonResult UpdaterCompareVersions(NSString *a, NSString *b);

@interface AppUpdater : NSObject
@property(nonatomic, readonly) BOOL checking;
@property(nonatomic, readonly) BOOL downloading;
@property(nonatomic, copy, readonly, nullable) NSString *latestVersion;
@property(nonatomic, copy, readonly, nullable) NSString *releaseURL;
@property(nonatomic, copy, readonly, nullable) NSString *dmgURL;
@property(nonatomic, copy, readonly, nullable) NSString *sha256URL;
@property(nonatomic, copy, readonly, nullable) NSString *releaseNotes;
@property(nonatomic, copy, nullable) void (^onStatusChange)(NSString *status);

- (void)checkForUpdatesInteractive:(BOOL)interactive
                        completion:(void (^ _Nullable)(BOOL hasUpdate, NSString * _Nullable latestVersion, NSString * _Nullable message))completion;
- (void)installAvailableUpdate;
@end

NS_ASSUME_NONNULL_END
