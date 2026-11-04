// Spike 0.1: cliente SPICE sin ventana. Reutiliza CSConnection y CSDisplay de CocoaSpice, con un
// renderer que no dibuja nada: confirma cada frame para liberar al servidor y deja la textura lista.
//   headless /ruta/absoluta/spice.sock CARPETA SEGUNDOS
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
@property(nonatomic,strong) NSString *folder;
@property(nonatomic) int seconds, index;
@end
@implementation Client
- (void)capture {
  if (self.index >= self.seconds) { fprintf(stderr, "HEADLESS done frames=%lu\n", (unsigned long)frames); exit(0); }
  int i = self.index++;
  double t = CFAbsoluteTimeGetCurrent(); unsigned long seen = frames;
  [self.display screenshotWithCompletion:^(CSScreenshot *shot) {
    NSData *tiff = shot.image.TIFFRepresentation;
    NSData *png = tiff ? [[NSBitmapImageRep imageRepWithData:tiff] representationUsingType:NSBitmapImageFileTypePNG properties:@{}] : nil;
    NSString *path = [self.folder stringByAppendingPathComponent:[NSString stringWithFormat:@"frame-%04d.png", i]];
    [png writeToFile:path atomically:YES];
    fprintf(stderr, "HEADLESS shot=%d bytes=%lu ms=%.0f frames=%lu\n", i, (unsigned long)png.length, (CFAbsoluteTimeGetCurrent() - t) * 1000, seen);
  }];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self capture]; });
}
- (void)spiceDisplayCreated:(CSConnection *)c display:(CSDisplay *)d {
  dispatch_async(dispatch_get_main_queue(), ^{
    self.display = d; [d addRenderer:self.renderer];
    fprintf(stderr, "HEADLESS display %.0fx%.0f GL=%d\n", d.displaySize.width, d.displaySize.height, d.isGLEnabled);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self capture]; });
  });
}
- (void)spiceConnected:(CSConnection *)c { fprintf(stderr, "HEADLESS connected\n"); }
- (void)spiceDisconnected:(CSConnection *)c { fprintf(stderr, "HEADLESS disconnected\n"); exit(3); }
- (void)spiceError:(CSConnection *)c code:(CSConnectionError)code message:(NSString *)m { fprintf(stderr, "HEADLESS error %s\n", m.UTF8String); exit(4); }
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
  if (argc != 4) { fprintf(stderr, "uso: headless SPICE_SOCK CARPETA SEGUNDOS\n"); return 2; }
  static Client *client; client = [Client new];
  client.renderer = [NullRenderer new];
  client.folder = [NSString stringWithUTF8String:argv[2]]; client.seconds = atoi(argv[3]);
  [NSFileManager.defaultManager createDirectoryAtPath:client.folder withIntermediateDirectories:YES attributes:nil error:nil];
  if (![CSMain.sharedInstance spiceStart]) { fprintf(stderr, "SPICE no arrancó\n"); return 1; }
  client.connection = [[CSConnection alloc] initWithUnixSocketFile:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]]];
  client.connection.audioEnabled = NO; client.connection.session.shareClipboard = NO; client.connection.delegate = client;
  [client.connection connect];
  dispatch_main();
}
