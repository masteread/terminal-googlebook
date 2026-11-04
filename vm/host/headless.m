// SPICE client with no window. Reuses CocoaSpice's CSConnection and CSDisplay with a renderer that
// draws nothing: it acknowledges each frame to release the server and leaves the texture ready.
// It must connect at boot and stay connected for the VM's whole life: a client that reconnects to
// a running VM gets no scanout until the guest allocates a new one.
//   headless /absolute/path/spice.sock /absolute/path/frame.sock
// stdin:  "shot /absolute/path.png"     stdout: "FRAME ok WIDTH HEIGHT" or "FRAME err REASON"
// frame.sock serves one viewer at a time: frames only when the screen changed, at most 30 per second,
// each as four little-endian uint32 (width, height, bytesPerRow, length) and `length` bytes of
// lz4-compressed BGRA rows. With no viewer, or a still screen, it does no work.
#import <AppKit/AppKit.h>
#import <poll.h>
#import <stdatomic.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import "CocoaSpice.h"
#import "CSDisplay+Protected.h"
#import "CSRenderer.h"

static atomic_ulong frames;
static int wakeWrite = -1;
static void frameChanged(void) {
  frames++;
  if (wakeWrite >= 0) { char byte = 0; (void)!write(wakeWrite, &byte, 1); }  // nonblocking: a full pipe already wakes the reader
}

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
  sourceBytesPerRow:(NSUInteger)p completion:(completionCallback_t)c { frameChanged(); if (c) c(); }
- (void)invalidateRenderSource:(id<CSRenderSource>)s withCompletion:(completionCallback_t)c { frameChanged(); if (c) c(); }
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

static BOOL writeAll(int fd, const void *bytes, size_t count) {
  const char *p = bytes;
  while (count) {
    ssize_t n = write(fd, p, count);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return NO;
    p += n; count -= n;
  }
  return YES;
}

/// The current picture as compressed BGRA. Blits on the renderer's queue, the one CSDisplay copies the
/// scanout on, so the copy cannot overlap a newer frame.
static NSData *encodeFrame(Client *client, uint32_t header[4]) {
  __block id<MTLTexture> texture;
  dispatch_semaphore_t ready = dispatch_semaphore_create(0);
  [CSMain.sharedInstance asyncWith:^{ texture = client.display.texture; dispatch_semaphore_signal(ready); }];
  dispatch_semaphore_wait(ready, DISPATCH_TIME_FOREVER);
  if (!texture || (texture.pixelFormat != MTLPixelFormatBGRA8Unorm && texture.pixelFormat != MTLPixelFormatRGBA8Unorm)) return nil;
  static id<MTLBuffer> buffer;
  NSUInteger width = texture.width, height = texture.height, stride = width * 4;
  if (buffer.length != stride * height) buffer = [client.renderer.device newBufferWithLength:stride * height options:MTLResourceStorageModeShared];
  id<MTLCommandBuffer> commands = [client.renderer.commandQueue commandBuffer];
  id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
  [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(width, height, 1)
               toBuffer:buffer destinationOffset:0 destinationBytesPerRow:stride destinationBytesPerImage:stride * height];
  [blit endEncoding];
  [commands commit];
  [commands waitUntilCompleted];
  if (commands.error) return nil;
  if (texture.pixelFormat == MTLPixelFormatRGBA8Unorm) {
    uint32_t *pixel = buffer.contents;
    for (NSUInteger i = 0; i < width * height; i++) pixel[i] = (pixel[i] & 0xff00ff00) | (pixel[i] & 0xff) << 16 | (pixel[i] >> 16 & 0xff);
  }
  NSData *raw = [NSData dataWithBytesNoCopy:buffer.contents length:stride * height freeWhenDone:NO];
  NSData *compressed = [raw compressedDataUsingAlgorithm:NSDataCompressionAlgorithmLZ4 error:nil];
  header[0] = (uint32_t)width; header[1] = (uint32_t)height; header[2] = (uint32_t)stride; header[3] = (uint32_t)compressed.length;
  return compressed;
}

static void serveViewer(Client *client, int viewer, int wake) {
  unsigned long sent = frames - 1;
  double last = 0;
  while (1) {
    if (frames == sent) {
      struct pollfd waiting[2] = {{viewer, POLLIN, 0}, {wake, POLLIN, 0}};
      if (poll(waiting, 2, -1) < 0 && errno != EINTR) return;
      if (waiting[0].revents) return;  // the viewer never writes: this is its exit
      char drain[256]; while (read(wake, drain, sizeof drain) > 0) {}
      continue;
    }
    double wait = last + 1.0 / 30 - CFAbsoluteTimeGetCurrent();
    if (wait > 0) usleep((useconds_t)(wait * 1e6));
    last = CFAbsoluteTimeGetCurrent();
    sent = frames;
    @autoreleasepool {
      uint32_t header[4];
      NSData *frame = encodeFrame(client, header);
      if (frame && (!writeAll(viewer, header, sizeof header) || !writeAll(viewer, frame.bytes, frame.length))) return;
    }
  }
}

static void startFrameServer(Client *client, const char *path) {
  struct sockaddr_un address = {.sun_family = AF_UNIX};
  if (strlen(path) >= sizeof address.sun_path) { fprintf(stderr, "frame socket path too long\n"); exit(1); }
  strcpy(address.sun_path, path);
  unlink(path);
  int listener = socket(AF_UNIX, SOCK_STREAM, 0), wake[2];
  mode_t mask = umask(0177);
  BOOL bound = bind(listener, (struct sockaddr *)&address, sizeof address) == 0;
  umask(mask);
  if (!bound || listen(listener, 1) != 0 || pipe(wake) != 0) { fprintf(stderr, "frame socket failed: %s\n", strerror(errno)); exit(1); }
  fcntl(wake[0], F_SETFL, O_NONBLOCK); fcntl(wake[1], F_SETFL, O_NONBLOCK);
  wakeWrite = wake[1];
  int wakeRead = wake[0];
  signal(SIGPIPE, SIG_IGN);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
    while (1) {
      int viewer = accept(listener, NULL, NULL);
      if (viewer < 0) continue;
      serveViewer(client, viewer, wakeRead);
      close(viewer);
    }
  });
}

int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: headless SPICE_SOCK FRAME_SOCK\n"); return 2; }
  static Client *client; client = [Client new];
  client.renderer = [NullRenderer new];
  if (![CSMain.sharedInstance spiceStart]) { fprintf(stderr, "SPICE worker failed\n"); return 1; }
  client.connection = [[CSConnection alloc] initWithUnixSocketFile:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]]];
  client.connection.audioEnabled = NO; client.connection.session.shareClipboard = NO; client.connection.delegate = client;
  [client.connection connect];
  startFrameServer(client, argv[2]);
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
