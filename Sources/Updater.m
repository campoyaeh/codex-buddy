#import "Updater.h"
#import <unistd.h>

static NSString * const kGitHubLatestReleaseAPI = @"https://api.github.com/repos/campoyaeh/codex-buddy/releases/latest";
static NSString * const kGitHubReleasesPage = @"https://github.com/campoyaeh/codex-buddy/releases/latest";
static NSString * const kFallbackVersion = @"0.3.8";

static NSString *StripVersionPrefix(NSString *raw) {
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([trimmed hasPrefix:@"v"] || [trimmed hasPrefix:@"V"]) {
        trimmed = [trimmed substringFromIndex:1];
    }
    return trimmed ?: @"";
}

NSString *UpdaterCurrentVersion(void) {
    NSString *v = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"];
    if ([v isKindOfClass:NSString.class] && v.length > 0) {
        return StripVersionPrefix(v);
    }
    return kFallbackVersion;
}

NSComparisonResult UpdaterCompareVersions(NSString *a, NSString *b) {
    NSArray<NSString *> *partsA = [StripVersionPrefix(a) componentsSeparatedByString:@"."];
    NSArray<NSString *> *partsB = [StripVersionPrefix(b) componentsSeparatedByString:@"."];
    NSUInteger count = MAX(partsA.count, partsB.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSInteger va = i < partsA.count ? partsA[i].integerValue : 0;
        NSInteger vb = i < partsB.count ? partsB[i].integerValue : 0;
        if (va < vb) return NSOrderedAscending;
        if (va > vb) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

@interface AppUpdater ()
@property(nonatomic, readwrite) BOOL checking;
@property(nonatomic, readwrite) BOOL downloading;
@property(nonatomic, copy, readwrite, nullable) NSString *latestVersion;
@property(nonatomic, copy, readwrite, nullable) NSString *releaseURL;
@property(nonatomic, copy, readwrite, nullable) NSString *dmgURL;
@property(nonatomic, copy, readwrite, nullable) NSString *sha256URL;
@property(nonatomic, copy, readwrite, nullable) NSString *releaseNotes;
@end

@implementation AppUpdater

- (void)notifyStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onStatusChange) self.onStatusChange(status);
    });
}

- (void)checkForUpdatesInteractive:(BOOL)interactive
                        completion:(void (^ _Nullable)(BOOL hasUpdate, NSString * _Nullable latestVersion, NSString * _Nullable message))completion {
    if (self.checking || self.downloading) {
        if (completion) completion(NO, self.latestVersion, @"正在检查或下载更新…");
        return;
    }
    self.checking = YES;
    [self notifyStatus:@"正在检查更新…"];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kGitHubLatestReleaseAPI]];
    req.timeoutInterval = 12.0;
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [req setValue:[NSString stringWithFormat:@"CodexBuddy/%@", UpdaterCurrentVersion()] forHTTPHeaderField:@"User-Agent"];

    __weak AppUpdater *weakSelf = self;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AppUpdater *owner = weakSelf;
            if (!owner) return;
            owner.checking = NO;
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            if (error || !data || (http && http.statusCode != 200)) {
                NSString *msg = http.statusCode == 403
                    ? @"GitHub 接口请求受限，请稍后再试或前往发布页查看"
                    : @"检查更新失败，请检查网络连接";
                [owner notifyStatus:msg];
                if (interactive) {
                    NSAlert *alert = [NSAlert new];
                    alert.messageText = @"无法检查更新";
                    alert.informativeText = msg;
                    [alert addButtonWithTitle:@"打开 GitHub 发布页"];
                    [alert addButtonWithTitle:@"好"];
                    if ([alert runModal] == NSAlertFirstButtonReturn) {
                        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:kGitHubReleasesPage]];
                    }
                }
                if (completion) completion(NO, nil, msg);
                return;
            }

            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if (![json isKindOfClass:NSDictionary.class] || ![json[@"tag_name"] isKindOfClass:NSString.class]) {
                NSString *msg = @"未解析到有效版本信息";
                [owner notifyStatus:msg];
                if (completion) completion(NO, nil, msg);
                return;
            }

            NSString *latest = StripVersionPrefix(json[@"tag_name"]);
            NSString *current = UpdaterCurrentVersion();
            owner.latestVersion = latest;
            owner.releaseURL = [json[@"html_url"] isKindOfClass:NSString.class] ? json[@"html_url"] : kGitHubReleasesPage;
            owner.releaseNotes = [json[@"body"] isKindOfClass:NSString.class] ? json[@"body"] : @"";
            owner.dmgURL = nil;
            owner.sha256URL = nil;

            NSArray *assets = [json[@"assets"] isKindOfClass:NSArray.class] ? json[@"assets"] : @[];
            for (NSDictionary *asset in assets) {
                if (![asset isKindOfClass:NSDictionary.class]) continue;
                NSString *name = [asset[@"name"] isKindOfClass:NSString.class] ? asset[@"name"] : @"";
                NSString *url = [asset[@"browser_download_url"] isKindOfClass:NSString.class] ? asset[@"browser_download_url"] : @"";
                if ([name hasSuffix:@".dmg"] && url.length) {
                    owner.dmgURL = url;
                } else if ([name hasSuffix:@".dmg.sha256"] && url.length) {
                    owner.sha256URL = url;
                }
            }

            BOOL hasUpdate = UpdaterCompareVersions(latest, current) == NSOrderedDescending;
            if (!hasUpdate) {
                NSString *msg = [NSString stringWithFormat:@"已是最新版本（v%@）", current];
                [owner notifyStatus:msg];
                if (interactive) {
                    NSAlert *alert = [NSAlert new];
                    alert.messageText = @"当前已是最新版本";
                    alert.informativeText = [NSString stringWithFormat:@"工头喵 v%@ 已是最新版。", current];
                    [alert addButtonWithTitle:@"好"];
                    [alert runModal];
                }
                if (completion) completion(NO, latest, msg);
                return;
            }

            NSString *msg = [NSString stringWithFormat:@"发现新版本 v%@（当前 v%@）", latest, current];
            [owner notifyStatus:msg];
            if (interactive) {
                [owner promptUserToInstallUpdate];
            }
            if (completion) completion(YES, latest, msg);
        });
    }];
    [task resume];
}

- (void)promptUserToInstallUpdate {
    NSString *notes = self.releaseNotes.length > 0 ? self.releaseNotes : @"包含体验优化与问题修复。";
    if (notes.length > 520) {
        notes = [[notes substringToIndex:520] stringByAppendingString:@"…"];
    }
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"发现新版本 v%@", self.latestVersion ?: @""];
    alert.informativeText = [NSString stringWithFormat:@"当前版本：v%@\n\n更新内容：\n%@", UpdaterCurrentVersion(), notes];
    if (self.dmgURL.length) {
        [alert addButtonWithTitle:@"立即自动更新"];
        [alert addButtonWithTitle:@"前往 GitHub 下载"];
        [alert addButtonWithTitle:@"稍后提醒"];
        NSModalResponse resp = [alert runModal];
        if (resp == NSAlertFirstButtonReturn) {
            [self installAvailableUpdate];
        } else if (resp == NSAlertSecondButtonReturn) {
            [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:self.releaseURL ?: kGitHubReleasesPage]];
        }
    } else {
        [alert addButtonWithTitle:@"前往 GitHub 下载"];
        [alert addButtonWithTitle:@"稍后提醒"];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:self.releaseURL ?: kGitHubReleasesPage]];
        }
    }
}

- (BOOL)verifySHA256ForFile:(NSString *)filePath expectedText:(NSString *)shaText {
    NSString *expected = [[shaText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet].firstObject.lowercaseString;
    if (expected.length != 64) return YES; // Ignore malformed sha file rather than blocking if unexpected format
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/shasum"];
    task.arguments = @[@"-a", @"256", filePath];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:NULL]) return NO;
    [task waitUntilExit];
    if (task.terminationStatus != 0) return NO;
    NSData *outData = [pipe.fileHandleForReading readDataToEndOfFile];
    NSString *outStr = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
    NSString *actual = [outStr componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet].firstObject.lowercaseString;
    return [actual isEqualToString:expected];
}

- (void)installAvailableUpdate {
    if (self.downloading || !self.dmgURL.length) return;
    self.downloading = YES;
    [self notifyStatus:[NSString stringWithFormat:@"正在下载 v%@ 安装包…", self.latestVersion ?: @""]];

    NSURL *dmgURL = [NSURL URLWithString:self.dmgURL];
    NSURL *shaURL = self.sha256URL.length ? [NSURL URLWithString:self.sha256URL] : nil;

    __weak AppUpdater *weakSelf = self;
    NSURLSessionDownloadTask *dl = [NSURLSession.sharedSession downloadTaskWithURL:dmgURL completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        AppUpdater *owner = weakSelf;
        if (!owner) return;
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (error || !location || (http && http.statusCode != 200)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                owner.downloading = NO;
                [owner notifyStatus:@"下载更新失败，请重试或前往 GitHub 下载"];
                NSAlert *alert = [NSAlert new];
                alert.messageText = @"下载更新失败";
                alert.informativeText = error.localizedDescription ?: @"网络连接中断，是否打开 GitHub 发布页手动下载？";
                [alert addButtonWithTitle:@"打开 GitHub 发布页"];
                [alert addButtonWithTitle:@"取消"];
                if ([alert runModal] == NSAlertFirstButtonReturn) {
                    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:owner.releaseURL ?: kGitHubReleasesPage]];
                }
            });
            return;
        }

        NSString *tempRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"codex-buddy-update-%@", NSUUID.UUID.UUIDString]];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:tempRoot withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *dmgPath = [tempRoot stringByAppendingPathComponent:@"update.dmg"];
        NSError *moveErr = nil;
        if (![fm moveItemAtPath:location.path toPath:dmgPath error:&moveErr]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                owner.downloading = NO;
                [owner notifyStatus:@"保存安装包失败"];
            });
            return;
        }

        // Optional SHA-256 verification
        if (shaURL) {
            NSString *shaText = [NSString stringWithContentsOfURL:shaURL encoding:NSUTF8StringEncoding error:NULL];
            if (shaText.length && ![owner verifySHA256ForFile:dmgPath expectedText:shaText]) {
                [fm removeItemAtPath:tempRoot error:NULL];
                dispatch_async(dispatch_get_main_queue(), ^{
                    owner.downloading = NO;
                    [owner notifyStatus:@"安装包校验失败，已取消更新"];
                    NSAlert *alert = [NSAlert new];
                    alert.messageText = @"安装包校验失败";
                    alert.informativeText = @"下载的 DMG SHA-256 校验未通过，为安全起见已取消自动安装。";
                    [alert addButtonWithTitle:@"好"];
                    [alert runModal];
                });
                return;
            }
        }

        [owner notifyStatus:@"正在解压并验证安装包…"];
        NSString *mountPoint = [tempRoot stringByAppendingPathComponent:@"mount"];
        [fm createDirectoryAtPath:mountPoint withIntermediateDirectories:YES attributes:nil error:NULL];
        NSTask *attach = [NSTask new];
        attach.executableURL = [NSURL fileURLWithPath:@"/usr/bin/hdiutil"];
        attach.arguments = @[@"attach", @"-nobrowse", @"-readonly", @"-mountpoint", mountPoint, dmgPath];
        attach.standardOutput = NSFileHandle.fileHandleWithNullDevice;
        attach.standardError = NSFileHandle.fileHandleWithNullDevice;
        if (![attach launchAndReturnError:NULL]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                owner.downloading = NO;
                [owner notifyStatus:@"挂载 DMG 失败"];
            });
            return;
        }
        [attach waitUntilExit];

        NSString *sourceApp = [mountPoint stringByAppendingPathComponent:@"工头喵.app"];
        if (attach.terminationStatus != 0 || ![fm fileExistsAtPath:sourceApp]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                owner.downloading = NO;
                [owner notifyStatus:@"安装包中未找到工头喵.app"];
            });
            return;
        }

        NSString *currentBundle = NSBundle.mainBundle.bundlePath;
        BOOL isAppBundle = [currentBundle hasSuffix:@".app"];
        NSString *parentDir = currentBundle.stringByDeletingLastPathComponent;
        BOOL canReplaceInPlace = isAppBundle && [fm isWritableFileAtPath:parentDir] && [fm isWritableFileAtPath:currentBundle];

        if (!canReplaceInPlace) {
            // Fall back to opening the DMG so the user can drag into /Applications
            NSTask *detach = [NSTask new];
            detach.executableURL = [NSURL fileURLWithPath:@"/usr/bin/hdiutil"];
            detach.arguments = @[@"detach", mountPoint, @"-quiet"];
            [detach launchAndReturnError:NULL];
            [detach waitUntilExit];
            dispatch_async(dispatch_get_main_queue(), ^{
                owner.downloading = NO;
                [owner notifyStatus:@"已下载 DMG，请在打开的窗口中拖入「应用程序」"];
                [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:dmgPath]];
            });
            return;
        }

        // Launch detached helper script to atomically swap .app after current process exits
        NSString *scriptPath = [tempRoot stringByAppendingPathComponent:@"apply_update.sh"];
        pid_t pid = getpid();
        NSString *script = [NSString stringWithFormat:
            @"#!/bin/sh\n"
            @"PID=%d\n"
            @"SRC=\"%@\"\n"
            @"DST=\"%@\"\n"
            @"MNT=\"%@\"\n"
            @"TMP=\"%@\"\n"
            @"STAGE=\"${DST}.new\"\n"
            @"BACKUP=\"${DST}.bak\"\n"
            @"for i in $(seq 1 40); do\n"
            @"  kill -0 \"$PID\" 2>/dev/null || break\n"
            @"  sleep 0.25\n"
            @"done\n"
            @"rm -rf \"$STAGE\" \"$BACKUP\"\n"
            @"if /usr/bin/ditto \"$SRC\" \"$STAGE\"; then\n"
            @"  mv \"$DST\" \"$BACKUP\" && mv \"$STAGE\" \"$DST\" && rm -rf \"$BACKUP\"\n"
            @"fi\n"
            @"/usr/bin/hdiutil detach \"$MNT\" -quiet 2>/dev/null || true\n"
            @"rm -rf \"$TMP\"\n"
            @"/usr/bin/open -n \"$DST\"\n",
            pid, sourceApp, currentBundle, mountPoint, tempRoot];
        [script writeToFile:scriptPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        [fm setAttributes:@{NSFilePosixPermissions: @(0700)} ofItemAtPath:scriptPath error:NULL];

        dispatch_async(dispatch_get_main_queue(), ^{
            owner.downloading = NO;
            [owner notifyStatus:@"正在安装更新并重启…"];
            NSTask *apply = [NSTask new];
            apply.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
            apply.arguments = @[scriptPath];
            apply.standardOutput = NSFileHandle.fileHandleWithNullDevice;
            apply.standardError = NSFileHandle.fileHandleWithNullDevice;
            if ([apply launchAndReturnError:NULL]) {
                [NSApp terminate:nil];
            } else {
                [owner notifyStatus:@"启动更新脚本失败"];
            }
        });
    }];
    [dl resume];
}

@end
