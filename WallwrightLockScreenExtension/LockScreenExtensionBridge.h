#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <bsm/libbsm.h>
#import <objc/runtime.h>

// Private macOS wallpaper hosting ABI — none of this is in a public header, so it's declared
// here by hand so Swift code can reference it at all. Not guessed: ported from
// reference/WallpaperMachine/Extension/WallpaperExtensionBridge.h (read this session), which
// itself cites the same third-party reverse-engineering source (kageroumado/phosphene) this
// whole plan is built on. `WallpaperPrivateRuntime.load()` verifies the real classes still match
// this shape at runtime before anything here is actually used — see its own doc comment.

@interface CAContext : NSObject
@property(nonatomic, readonly) unsigned int contextId;
@property(nonatomic, retain) CALayer *layer;
- (void)invalidate;
@end

@interface NSXPCConnection (WallpaperCallerIdentity)
@property(nonatomic, readonly) audit_token_t auditToken;
@end

@protocol WallpaperExtensionXPCProtocol <NSObject>
- (void)acquireWithId:(id)identifier request:(id)request reply:(void (^)(id, NSError *))reply;
- (void)updateWithId:(id)identifier request:(id)request reply:(void (^)(NSError *))reply;
- (void)invalidateWithId:(id)identifier reply:(void (^)(NSError *))reply;
- (void)snapshotWithId:(id)identifier reply:(void (^)(id, NSError *))reply;
- (void)provideSettingsViewModelsWithContentTypes:(id)types reply:(void (^)(id, NSError *))reply;
- (void)isChoiceDownloadedWith:(id)choiceID reply:(void (^)(BOOL, NSError *))reply;
- (void)selectedChoicesDidChangeFor:(id)identifier reply:(void (^)(NSError *))reply;
@end
