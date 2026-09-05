#import "PersistentStartup.h"
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <AVFoundation/AVFoundation.h>
#import <ServiceManagement/ServiceManagement.h>

static NSString * const LaunchAtLoginPreferenceKey = @"launchAtLoginPreference";

static NSString *PermissionPaneName(void) {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27) {
        return @"Device Control and Data Access";
    }
    return @"Accessibility";
}

// Exit through AppKit so the running app also shuts down its speech engine.
static int QuitRunningReaders(void) {
    NSArray<NSRunningApplication *> *apps = [NSRunningApplication
        runningApplicationsWithBundleIdentifier:@"com.local.kokoro-reader"];
    pid_t currentPID = NSProcessInfo.processInfo.processIdentifier;
    for (NSRunningApplication *app in apps) {
        if (app.processIdentifier != currentPID && !app.terminated && ![app terminate]) {
            fputs("Could not quit Kokoro Reader. Quit it from its menu and try again.\n", stderr);
            return 1;
        }
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (YES) {
        BOOL running = NO;
        for (NSRunningApplication *app in apps) {
            if (app.processIdentifier != currentPID && !app.terminated) running = YES;
        }
        if (!running) return 0;
        if (deadline.timeIntervalSinceNow <= 0) {
            fputs("Kokoro Reader is still running. Close its dialogs, quit it, and try again.\n", stderr);
            return 1;
        }
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
}

typedef NS_ENUM(NSInteger, ReaderState) {
    ReaderStateStarting,
    ReaderStateReady,
    ReaderStateGenerating,
    ReaderStateSpeaking,
    ReaderStateFailed,
};

@interface SelectionReader : NSObject
@property(nonatomic) pid_t lastExternalPID;
@property(nonatomic, strong) id observer;
- (BOOL)requestAccessibilityIfNeeded;
- (NSString *)selectedText;
@end

@implementation SelectionReader
- (instancetype)init {
    if ((self = [super init])) {
        NSRunningApplication *frontmost = NSWorkspace.sharedWorkspace.frontmostApplication;
        if (frontmost.processIdentifier != NSProcessInfo.processInfo.processIdentifier) {
            _lastExternalPID = frontmost.processIdentifier;
        }
        __weak typeof(self) weakSelf = self;
        _observer = [NSWorkspace.sharedWorkspace.notificationCenter
            addObserverForName:NSWorkspaceDidActivateApplicationNotification
            object:nil
            queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *note) {
                NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
                if (app.processIdentifier != NSProcessInfo.processInfo.processIdentifier) {
                    weakSelf.lastExternalPID = app.processIdentifier;
                }
            }];
    }
    return self;
}

- (void)dealloc {
    if (_observer) [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:_observer];
}

- (BOOL)requestAccessibilityIfNeeded {
    if (AXIsProcessTrusted()) return YES;
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    return NO;
}

- (NSString *)selectedText {
    if (!AXIsProcessTrusted()) return nil;
    AXUIElementRef application = AXUIElementCreateApplication(self.lastExternalPID);
    NSString *text = [self selectedTextFrom:application];
    CFRelease(application);
    if (!text) {
        AXUIElementRef system = AXUIElementCreateSystemWide();
        text = [self selectedTextFrom:system];
        CFRelease(system);
    }
    NSString *clean = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return clean.length ? clean : nil;
}

- (NSString *)selectedTextFrom:(AXUIElementRef)root {
    AXUIElementRef focused = NULL;
    AXError result = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute, (CFTypeRef *)&focused);
    AXUIElementRef target = result == kAXErrorSuccess && focused ? focused : root;
    CFTypeRef selected = NULL;
    NSString *text = nil;
    if (AXUIElementCopyAttributeValue(target, kAXSelectedTextAttribute, &selected) == kAXErrorSuccess) {
        if (selected && CFGetTypeID(selected) == CFStringGetTypeID()) {
            text = [(__bridge NSString *)selected copy];
        }
    }
    if (selected) CFRelease(selected);
    if (focused) CFRelease(focused);
    return text;
}
@end

@interface KokoroEngine : NSObject
@property(nonatomic, copy) void (^eventHandler)(NSDictionary *event);
@property(nonatomic, strong) NSTask *task;
@property(nonatomic, strong) NSPipe *input;
@property(nonatomic, strong) NSPipe *output;
@property(nonatomic, strong) NSPipe *errors;
@property(nonatomic, strong) NSMutableData *buffer;
- (BOOL)startWithProjectRoot:(NSString *)root error:(NSError **)error;
- (BOOL)speak:(NSString *)text error:(NSError **)error;
- (void)cancel;
- (void)shutdown;
@end

@implementation KokoroEngine
- (instancetype)init {
    if ((self = [super init])) _buffer = NSMutableData.data;
    return self;
}

- (BOOL)startWithProjectRoot:(NSString *)root error:(NSError **)error {
    NSString *python = [root stringByAppendingPathComponent:@".venv/bin/python3"];
    NSString *engine = [NSBundle.mainBundle.resourceURL.path stringByAppendingPathComponent:@"engine.py"];
    NSString *model = [root stringByAppendingPathComponent:@"models/Kokoro-82M-bf16"];
    if (![NSFileManager.defaultManager isExecutableFileAtPath:python]) {
        if (error) *error = [NSError errorWithDomain:@"KokoroReader" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"Local runtime is missing. Run scripts/setup-runtime.sh."
        }];
        return NO;
    }

    self.task = NSTask.new;
    self.input = NSPipe.pipe;
    self.output = NSPipe.pipe;
    self.errors = NSPipe.pipe;
    self.task.executableURL = [NSURL fileURLWithPath:python];
    self.task.arguments = @[engine, @"--model-dir", model];
    NSMutableDictionary *environment = NSProcessInfo.processInfo.environment.mutableCopy;
    environment[@"PYTHONUNBUFFERED"] = @"1";
    self.task.environment = environment;
    self.task.standardInput = self.input;
    self.task.standardOutput = self.output;
    self.task.standardError = self.errors;

    __weak typeof(self) weakSelf = self;
    self.output.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (!data.length) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf consume:data]; });
    };
    self.errors.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (!data.length) return;
        NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSLog(@"Kokoro engine: %@", [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    };
    self.task.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.eventHandler) weakSelf.eventHandler(@{
                @"event": @"error",
                @"message": [NSString stringWithFormat:@"Speech engine stopped (code %d).", task.terminationStatus]
            });
        });
    };
    return [self.task launchAndReturnError:error];
}

- (BOOL)speak:(NSString *)text error:(NSError **)error {
    return [self sendCommand:@{@"command": @"speak", @"text": text} error:error];
}

- (BOOL)sendCommand:(NSDictionary *)command error:(NSError **)error {
    NSData *json = [NSJSONSerialization dataWithJSONObject:command options:0 error:error];
    if (!json) return NO;
    NSMutableData *line = json.mutableCopy;
    uint8_t newline = '\n';
    [line appendBytes:&newline length:1];
    return [self.input.fileHandleForWriting writeData:line error:error];
}

- (void)cancel {
    [self sendCommand:@{@"command": @"stop"} error:nil];
}

- (void)shutdown {
    self.output.fileHandleForReading.readabilityHandler = nil;
    self.errors.fileHandleForReading.readabilityHandler = nil;
    self.task.terminationHandler = nil;
    if (self.task.running) [self.task terminate];
}

- (void)consume:(NSData *)data {
    [self.buffer appendData:data];
    while (YES) {
        const uint8_t *bytes = self.buffer.bytes;
        NSUInteger newline = NSNotFound;
        for (NSUInteger index = 0; index < self.buffer.length; index++) {
            if (bytes[index] == '\n') { newline = index; break; }
        }
        if (newline == NSNotFound) break;
        NSData *line = [self.buffer subdataWithRange:NSMakeRange(0, newline)];
        [self.buffer replaceBytesInRange:NSMakeRange(0, newline + 1) withBytes:NULL length:0];
        if (!line.length) continue;
        NSDictionary *event = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
        if ([event isKindOfClass:NSDictionary.class] && self.eventHandler) self.eventHandler(event);
    }
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, AVAudioPlayerDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) SelectionReader *selectionReader;
@property(nonatomic, strong) KokoroEngine *engine;
@property(nonatomic, strong) AVAudioPlayer *player;
@property(nonatomic, strong) NSMutableArray<NSString *> *audioQueue;
@property(nonatomic) BOOL streamEnded;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) ReaderState state;
@property(nonatomic, copy) NSString *launchAtLoginError;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{LaunchAtLoginPreferenceKey: @YES}];
    [self ensureLaunchAtLoginIfPreferred];

    self.state = ReaderStateStarting;
    self.selectionReader = SelectionReader.new;
    self.engine = KokoroEngine.new;
    self.audioQueue = NSMutableArray.array;
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.length = NSSquareStatusItemLength;
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(statusItemClicked:);
    [self.statusItem.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    [self updateIcon];

    __weak typeof(self) weakSelf = self;
    self.engine.eventHandler = ^(NSDictionary *event) { [weakSelf handleEvent:event]; };
    NSString *root = NSProcessInfo.processInfo.environment[@"KOKORO_READER_HOME"];
    if (!root.length) {
        root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Kokoro Reader"];
    }
    NSError *error = nil;
    if (![self.engine startWithProjectRoot:root error:&error]) {
        self.state = ReaderStateFailed;
        [self updateIcon];
        [self showAlert:@"Kokoro Reader couldn’t start" message:error.localizedDescription];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.player stop];
    [self.engine shutdown];
}

- (void)statusItemClicked:(id)sender {
    if (NSApp.currentEvent.type == NSEventTypeRightMouseUp) [self showContextMenu];
    else [self readOrStop];
}

- (void)readOrStop {
    if (self.player.playing || self.state == ReaderStateGenerating || self.state == ReaderStateSpeaking) {
        [self.engine cancel];
        [self.player stop];
        self.player = nil;
        [self.audioQueue removeAllObjects];
        self.cancelled = YES;
        self.streamEnded = YES;
        self.state = ReaderStateReady;
        [self updateIcon];
        return;
    }
    if (self.state != ReaderStateReady) { NSBeep(); return; }
    if (!AXIsProcessTrusted()) {
        // Explain the next step before requesting access: the native prompt
        // is asynchronous and must not be covered by our own modal alert.
        [self showPermissionHelp];
        return;
    }
    NSString *text = self.selectionReader.selectedText;
    if (!text.length) {
        [self showAlert:@"No text selected" message:@"Select text with your mouse, leave it highlighted, then click the waveform icon."];
        return;
    }
    self.cancelled = NO;
    self.streamEnded = NO;
    [self.audioQueue removeAllObjects];
    self.state = ReaderStateGenerating;
    [self updateIcon];
    NSError *error = nil;
    if (![self.engine speak:text error:&error]) {
        self.state = ReaderStateFailed;
        [self updateIcon];
        [self showAlert:@"Couldn’t read that text" message:error.localizedDescription];
    }
}

- (void)handleEvent:(NSDictionary *)event {
    NSString *kind = event[@"event"];
    if ([kind isEqualToString:@"ready"]) {
        self.state = ReaderStateReady;
        [self updateIcon];
    } else if ([kind isEqualToString:@"stream_start"]) {
        if (!self.cancelled) {
            self.state = ReaderStateGenerating;
            [self updateIcon];
        }
    } else if ([kind isEqualToString:@"audio"]) {
        if (!self.cancelled && [event[@"path"] isKindOfClass:NSString.class]) {
            [self.audioQueue addObject:event[@"path"]];
            if (!self.player) [self playNextAudioChunk];
        }
    } else if ([kind isEqualToString:@"done"] || [kind isEqualToString:@"cancelled"]) {
        self.streamEnded = YES;
        if (!self.player && !self.audioQueue.count) {
            self.state = ReaderStateReady;
            [self updateIcon];
        }
    } else if ([kind isEqualToString:@"error"]) {
        if (self.cancelled) return;
        self.state = ReaderStateFailed;
        [self updateIcon];
        [self showAlert:@"Kokoro Reader error" message:event[@"message"] ?: @"Unknown error"];
    }
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    self.player = nil;
    if (self.audioQueue.count) {
        [self playNextAudioChunk];
    } else {
        self.state = self.streamEnded ? ReaderStateReady : ReaderStateGenerating;
        [self updateIcon];
    }
}

- (void)playNextAudioChunk {
    if (!self.audioQueue.count || self.cancelled) return;
    NSString *path = self.audioQueue.firstObject;
    [self.audioQueue removeObjectAtIndex:0];
    NSError *error = nil;
    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&error];
    if (!self.player) {
        self.state = ReaderStateFailed;
        [self updateIcon];
        [self showAlert:@"Couldn’t play audio" message:error.localizedDescription];
        return;
    }
    self.player.delegate = self;
    [self.player prepareToPlay];
    [self.player play];
    self.state = ReaderStateSpeaking;
    [self updateIcon];
}

- (void)updateIcon {
    NSString *symbol;
    NSString *tip;
    switch (self.state) {
        case ReaderStateStarting: symbol = @"waveform.circle"; tip = @"Kokoro Reader is loading…"; break;
        case ReaderStateReady: symbol = @"waveform.circle.fill"; tip = @"Read selected text"; break;
        case ReaderStateGenerating: symbol = @"ellipsis.circle.fill"; tip = @"Generating speech…"; break;
        case ReaderStateSpeaking: symbol = @"speaker.wave.2.circle.fill"; tip = @"Click to stop"; break;
        case ReaderStateFailed: symbol = @"exclamationmark.circle.fill"; tip = @"Kokoro Reader needs attention"; break;
    }
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:@"Kokoro Reader"];
    self.statusItem.button.toolTip = tip;
}

- (void)showContextMenu {
    NSMenu *menu = NSMenu.new;
    BOOL active = self.player.playing || self.state == ReaderStateGenerating || self.state == ReaderStateSpeaking;
    NSMenuItem *read = [[NSMenuItem alloc] initWithTitle:(active ? @"Stop Speaking" : @"Read Selected Text") action:@selector(readOrStop) keyEquivalent:@""];
    read.target = self;
    read.enabled = self.state == ReaderStateReady || active;
    [menu addItem:read];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *permissions = [[NSMenuItem alloc] initWithTitle:@"Text Access Help…" action:@selector(showPermissionHelp) keyEquivalent:@""];
    permissions.target = self;
    [menu addItem:permissions];
    NSMenuItem *launchAtLogin = [[NSMenuItem alloc] initWithTitle:@"Launch at Login & Keep Running" action:@selector(toggleLaunchAtLogin) keyEquivalent:@""];
    launchAtLogin.target = self;
    launchAtLogin.state = [self launchAtLoginEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:launchAtLogin];
    if (self.launchAtLoginError.length) {
        NSMenuItem *loginError = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Login item: %@", self.launchAtLoginError] action:nil keyEquivalent:@""];
        loginError.enabled = NO;
        [menu addItem:loginError];
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit Kokoro Reader" action:@selector(quit) keyEquivalent:@""];
    quit.target = self;
    [menu addItem:quit];
    [self.statusItem popUpStatusItemMenu:menu];
}

- (PersistentStartup *)startup {
    return StartupController(@"com.local.autostart.kokoro-reader");
}

- (BOOL)launchAtLoginEnabled {
    return [NSFileManager.defaultManager fileExistsAtPath:self.startup.path] && self.startup.loaded;
}

- (NSString *)launchAtLoginStatusText {
    if ([self launchAtLoginEnabled]) return @"enabled";
    return [NSFileManager.defaultManager fileExistsAtPath:self.startup.path] ? @"inactive" : @"not_registered";
}

- (void)ensureLaunchAtLoginIfPreferred {
    NSError *error = nil;
    BOOL preferred = [NSUserDefaults.standardUserDefaults boolForKey:LaunchAtLoginPreferenceKey];
    BOOL ok = RemoveNativeLoginItem(&error) && [self.startup setEnabled:preferred error:&error];
    self.launchAtLoginError = ok ? nil : error.localizedDescription;
}

- (void)toggleLaunchAtLogin {
    NSError *error = nil;
    // A pending/blocked registration can also be turned off.
    BOOL wasPreferred = [NSUserDefaults.standardUserDefaults boolForKey:LaunchAtLoginPreferenceKey];
    BOOL ok = RemoveNativeLoginItem(&error) && [self.startup setEnabled:!wasPreferred error:&error];
    if (ok) [NSUserDefaults.standardUserDefaults setBool:!wasPreferred forKey:LaunchAtLoginPreferenceKey];
    self.launchAtLoginError = ok ? nil : error.localizedDescription;
}

- (void)quit { [NSApp terminate:nil]; }

- (void)showPermissionHelp {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = NSAlert.new;
    alert.messageText = @"Allow access to selected text";
    alert.informativeText = [NSString stringWithFormat:
        @"Enable Kokoro Reader in System Settings → Privacy & Security → %@.\n\n"
        @"Already enabled after an update? Remove its entry with the minus button, "
        @"then add this installed app with the plus button:\n%@\n\n"
        @"Alternatively, run repair-permissions.command from the downloaded repository. "
        @"Then enable access again. Quit and reopen Kokoro Reader if needed.",
        PermissionPaneName(), NSBundle.mainBundle.bundlePath];
    [alert addButtonWithTitle:@"Open Settings"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [self.selectionReader requestAccessibilityIfNeeded];
        NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
        [NSWorkspace.sharedWorkspace openURL:url];
    }
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = NSAlert.new;
    alert.messageText = title;
    alert.informativeText = message ?: @"";
    alert.alertStyle = NSAlertStyleInformational;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--pause-startup") == 0) {
            NSError *error = nil;
            BOOL ok = [StartupController(@"com.local.autostart.kokoro-reader") pause:&error];
            if (!ok) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            return ok ? 0 : 1;
        }
        if (argc > 1 && strcmp(argv[1], "--quit-running") == 0) {
            NSError *pauseError = nil;
            if (![StartupController(@"com.local.autostart.kokoro-reader") pause:&pauseError]) {
                fprintf(stderr, "%s\n", pauseError.localizedDescription.UTF8String);
                return 1;
            }
            return QuitRunningReaders();
        }
        if (argc > 1 && strcmp(argv[1], "--launch-at-login-status") == 0) {
            AppDelegate *statusDelegate = AppDelegate.new;
            NSString *status = [statusDelegate launchAtLoginStatusText];
            puts(status.UTF8String);
            return [status isEqualToString:@"enabled"] ? 0 : 1;
        }
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = AppDelegate.new;
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
