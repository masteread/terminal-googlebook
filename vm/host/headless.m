// SPICE client with no window. Reuses CocoaSpice's CSConnection and CSDisplay with a renderer that
// draws nothing: it acknowledges each frame to release the server and leaves the texture ready.
// It must connect at boot and stay connected for the VM's whole life: a client that reconnects to
// a running VM gets no scanout until the guest allocates a new one.
//   headless /absolute/path/spice.sock
// stdin:  "shot /absolute/path.png"     stdout: "FRAME ok WIDTH HEIGHT" or "FRAME err REASON"
#import <AppKit/AppKit.h>
#import <stdatomic.h>
#import "CocoaSpice.h"
#import "CSDisplay+Protected.h"
#import "CSRenderer.h"

static atomic_ulong frames;

@interface NullRenderer : NSObject<CSRenderer>
@property(nonatomic,readonly) id<MTLDevice> device;
@property(nonatomic,readonly) id<MTLCommandQueue> commandQueue;
@property(nonatomic,readwrite) CGPoint viewportOrigin;
@property(nonatomic,readwrite) CGFloat viewportScale;
@end
@implementation NullRenderer
- (instancetype)init {
  if ((self = [super init])) { _device = MTLCreateSystemDefaultDevice(); _commandQueue = [_device newCommandQueue]; }
  return self;
}
- (void)renderSouce:(id<CSRenderSource>)s copyBuffer:(id<MTLBuffer>)b region:(MTLRegion)r sourceOffset:(NSUInteger)o
  sourceBytesPerRow:(NSUInteger)p completion:(completionCallback_t)c { frames++; if (c) c(); }
- (void)invalidateRenderSource:(id<CSRenderSource>)s withCompletion:(completionCallback_t)c { frames++; if (c) c(); }
- (void)disableRender {}
@end

@interface Client : NSObject<CSConnectionDelegate>
@property(nonatomic,strong) CSConnection *connection;
@property(nonatomic,strong) NullRenderer *renderer;
@property(nonatomic,strong) CSDisplay *display;
@end
@implementation Client
- (void)shot:(NSString *)path {
  if (!self.display) { printf("FRAME err no-display\n"); fflush(stdout); return; }
  [self.display screenshotWithCompletion:^(CSScreenshot *shot) {
    NSBitmapImageRep *rep = shot.image.TIFFRepresentation ? [NSBitmapImageRep imageRepWithData:shot.image.TIFFRepresentation] : nil;
    NSData *png = rep ? [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] : nil;
    if (png && [png writeToFile:path atomically:YES]) printf("FRAME ok %ld %ld\n", (long)rep.pixelsWide, (long)rep.pixelsHigh);
    else printf("FRAME err no-frame\n");
    fflush(stdout);
  }];
}
- (void)spiceDisplayCreated:(CSConnection *)c display:(CSDisplay *)d {
  dispatch_async(dispatch_get_main_queue(), ^{ self.display = d; [d addRenderer:self.renderer]; });
}
- (void)spiceConnected:(CSConnection *)c {}
- (void)spiceDisconnected:(CSConnection *)c { exit(3); }
- (void)spiceError:(CSConnection *)c code:(CSConnectionError)code message:(NSString *)m { fprintf(stderr, "SPICE error %s\n", m.UTF8String); exit(4); }
- (void)spiceDisplayUpdated:(CSConnection *)c display:(CSDisplay *)d {}
- (void)spiceDisplayDestroyed:(CSConnection *)c display:(CSDisplay *)d {}
- (void)spiceInputAvailable:(CSConnection *)c input:(CSInput *)i {}
- (void)spiceInputUnavailable:(CSConnection *)c input:(CSInput *)i {}
- (void)spiceAgentConnected:(CSConnection *)c supportingFeatures:(CSConnectionAgentFeature)f {}
- (void)spiceAgentDisconnected:(CSConnection *)c {}
- (void)spiceForwardedPortOpened:(CSConnection *)c port:(CSPort *)p {}
- (void)spiceForwardedPortClosed:(CSConnection *)c port:(CSPort *)p {}
@end

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: headless SPICE_SOCK\n"); return 2; }
  static Client *client; client = [Client new];
  client.renderer = [NullRenderer new];
  if (![CSMain.sharedInstance spiceStart]) { fprintf(stderr, "SPICE worker failed\n"); return 1; }
  client.connection = [[CSConnection alloc] initWithUnixSocketFile:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]]];
  client.connection.audioEnabled = NO; client.connection.session.shareClipboard = NO; client.connection.delegate = client;
  [client.connection connect];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    char *line = NULL; size_t capacity = 0; ssize_t length;
    while ((length = getline(&line, &capacity, stdin)) > 0) {
      if (line[length - 1] == '\n') line[length - 1] = 0;
      if (strncmp(line, "shot ", 5)) continue;
      NSString *path = [NSString stringWithUTF8String:line + 5];
      dispatch_async(dispatch_get_main_queue(), ^{ [client shot:path]; });
    }
    exit(0);  // the host process went away
  });
  dispatch_main();
}
