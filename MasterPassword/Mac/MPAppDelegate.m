//
//  MPAppDelegate.m
//  MasterPassword
//
//  Created by Maarten Billemont on 04/03/12.
//  Copyright (c) 2012 Lyndir. All rights reserved.
//

#import "MPAppDelegate.h"
#import "MPAppDelegate_Key.h"
#import "MPAppDelegate_Store.h"
#import <Carbon/Carbon.h>


@implementation MPAppDelegate
@synthesize statusItem;
@synthesize lockItem;
@synthesize showItem;
@synthesize statusMenu;
@synthesize useICloudItem;
@synthesize rememberPasswordItem;
@synthesize savePasswordItem;
@synthesize passwordWindow;

@synthesize key;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfour-char-constants"
static EventHotKeyID MPShowHotKey = {.signature = 'show', .id = 1};
static EventHotKeyID MPLockHotKey = {.signature = 'lock', .id = 1};
#pragma clang diagnostic pop

+ (void)initialize {

    static dispatch_once_t initialize;
    dispatch_once(&initialize, ^{
        [MPMacConfig get];

    #ifdef DEBUG
        [PearlLogger get].printLevel = PearlLogLevelDebug;//Trace;
    #endif
    });
}

static OSStatus MPHotKeyHander(EventHandlerCallRef nextHandler, EventRef theEvent, void *userData) {

    // Extract the hotkey ID.
    EventHotKeyID hotKeyID;
    GetEventParameter(theEvent, kEventParamDirectObject, typeEventHotKeyID,
     NULL, sizeof(hotKeyID), NULL, &hotKeyID);

    // Check which hotkey this was.
    if (hotKeyID.signature == MPShowHotKey.signature && hotKeyID.id == MPShowHotKey.id) {
        [((__bridge MPAppDelegate *)userData) activate:nil];
        return noErr;
    }
    if (hotKeyID.signature == MPLockHotKey.signature && hotKeyID.id == MPLockHotKey.id) {
        [((__bridge MPAppDelegate *)userData) lock:nil];
        return noErr;
    }

    return eventNotHandledErr;
}

- (void)updateUsers {
    
    [[[self.usersItem submenu] itemArray] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        if (idx > 1)
            [[self.usersItem submenu] removeItem:obj];
    }];

    NSManagedObjectContext *moc = [MPAppDelegate managedObjectContextForThreadIfReady];
    if (!moc) {
        self.createUserItem.title = @"New User (Not ready)";
        self.createUserItem.enabled = NO;
        self.createUserItem.toolTip = @"Please wait until the app is fully loaded.";
        [self.usersItem.submenu addItemWithTitle:@"Loading..." action:NULL keyEquivalent:@""].enabled = NO;

        return;
    }

    self.createUserItem.title = @"New User";
    self.createUserItem.enabled = YES;
    self.createUserItem.toolTip = nil;
    
    NSError        *error        = nil;
    NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:NSStringFromClass([MPUserEntity class])];
    fetchRequest.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"lastUsed" ascending:NO]];
    NSArray        *users = [moc executeFetchRequest:fetchRequest error:&error];
    if (!users)
        err(@"Failed to load users: %@", error);
    
    if (![users count]) {
        NSMenuItem *noUsersItem = [self.usersItem.submenu addItemWithTitle:@"No users" action:NULL keyEquivalent:@""];
        noUsersItem.enabled = NO;
        noUsersItem.toolTip = @"Use the iOS app to create users and make sure iCloud is enabled in its preferences as well.  "
        @"Then give iCloud some time to sync the new user to your Mac.";
    }
    
    for (MPUserEntity *user in users) {
        NSMenuItem *userItem = [[NSMenuItem alloc] initWithTitle:user.name action:@selector(selectUser:) keyEquivalent:@""];
        [userItem setTarget:self];
        [userItem setRepresentedObject:[user objectID]];
        [[self.usersItem submenu] addItem:userItem];
        
        if ([user.name isEqualToString:[MPMacConfig get].usedUserName])
            [self selectUser:userItem];
    }
}

- (void)selectUser:(NSMenuItem *)item {
    
    self.activeUser = (MPUserEntity *)[[MPAppDelegate managedObjectContextForThreadIfReady] objectRegisteredForID:[item representedObject]];
}

- (void)showMenu {

    [self updateMenuItems];

    [self.statusItem popUpStatusItemMenu:self.statusMenu];
}

- (IBAction)activate:(id)sender {

    if (!self.activeUser)
        // No user, can't activate.
        return;

    if ([[NSApplication sharedApplication] isActive])
        [self applicationDidBecomeActive:nil];
    else
        [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
}

- (IBAction)togglePreference:(NSMenuItem *)sender {

    if (sender == useICloudItem)
        [MPConfig get].iCloud = @(sender.state == NSOnState);
    if (sender == rememberPasswordItem)
        [MPConfig get].rememberLogin = [NSNumber numberWithBool:![[MPConfig get].rememberLogin boolValue]];
    if (sender == savePasswordItem) {
        MPUserEntity *activeUser = [MPAppDelegate get].activeUser;
        if ((activeUser.saveKey = !activeUser.saveKey))
            [[MPAppDelegate get] storeSavedKeyFor:activeUser];
        else
            [[MPAppDelegate get] forgetSavedKeyFor:activeUser];
        [activeUser saveContext];
    }
}

- (IBAction)newUser:(NSMenuItem *)sender {
}

- (IBAction)signOut:(id)sender {
    
    [self signOutAnimated:YES];
}

- (IBAction)lock:(id)sender {

    self.key = nil;
}

- (void)didUpdateConfigForKey:(SEL)configKey fromValue:(id)oldValue {

    [[NSNotificationCenter defaultCenter] postNotificationName:MPCheckConfigNotification
                                                        object:NSStringFromSelector(configKey) userInfo:nil];
}

#pragma mark - NSApplicationDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {

    // Setup delegates and listeners.
    [MPConfig get].delegate = self;
    __weak id weakSelf = self;
    [self addObserverBlock:^(NSString *keyPath, id object, NSDictionary *change, void *context) {
        [weakSelf updateMenuItems];
    } forKeyPath:@"key" options:NSKeyValueObservingOptionInitial context:nil];
    [self addObserverBlock:^(NSString *keyPath, id object, NSDictionary *change, void *context) {
        [weakSelf updateMenuItems];
    } forKeyPath:@"activeUser" options:NSKeyValueObservingOptionInitial context:nil];

    // Status item.
    self.statusItem               = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.image         = [NSImage imageNamed:@"menu-icon"];
    self.statusItem.highlightMode = YES;
    self.statusItem.target        = self;
    self.statusItem.action        = @selector(showMenu);

    __weak MPAppDelegate *wSelf = self;
    [self addObserverBlock:^(NSString *keyPath, id object, NSDictionary *change, void *context) {
        MPUserEntity *activeUser = wSelf.activeUser;
        [[[wSelf.usersItem submenu] itemArray] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            if ([[obj representedObject] isEqual:[activeUser objectID]])
                [obj setState:NSOnState];
            else
                [obj setState:NSOffState];
        }];

        [MPMacConfig get].usedUserName = activeUser.name;
    }           forKeyPath:@"activeUserObjectID" options:0 context:nil];
    [[NSNotificationCenter defaultCenter] addObserverForName:UbiquityManagedStoreDidChangeNotification object:nil queue:nil usingBlock:
     ^(NSNotification *note) {
         [self updateUsers];
     }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UbiquityManagedStoreDidImportChangesNotification object:nil queue:nil
                                                  usingBlock:
                                                   ^(NSNotification *note) {
                                                       [self updateUsers];
                                                   }];
    [[NSNotificationCenter defaultCenter] addObserverForName:MPCheckConfigNotification object:nil queue:nil usingBlock:
     ^(NSNotification *note) {
         self.rememberPasswordItem.state = [[MPConfig get].rememberLogin boolValue]? NSOnState: NSOffState;
         self.savePasswordItem.state     = [MPAppDelegate get].activeUser.saveKey? NSOnState: NSOffState;
     }];
    [self updateUsers];

    // Global hotkey.
    EventHotKeyRef hotKeyRef;
    EventTypeSpec  hotKeyEvents[1] = {{.eventClass = kEventClassKeyboard, .eventKind = kEventHotKeyPressed}};
    OSStatus       status          = InstallApplicationEventHandler(NewEventHandlerUPP(MPHotKeyHander), GetEventTypeCount(hotKeyEvents),
                                                                    hotKeyEvents,
                                                                    (__bridge void *)self, NULL);
    if (status != noErr)
    err(@"Error installing application event handler: %d", status);
    status = RegisterEventHotKey(35 /* p */, controlKey + cmdKey, MPShowHotKey, GetApplicationEventTarget(), 0, &hotKeyRef);
    if (status != noErr)
    err(@"Error registering 'show' hotkey: %d", status);
    status = RegisterEventHotKey(35 /* p */, controlKey + optionKey + cmdKey, MPLockHotKey, GetApplicationEventTarget(), 0, &hotKeyRef);
    if (status != noErr)
    err(@"Error registering 'lock' hotkey: %d", status);
}

- (void)updateMenuItems {

    if (!(self.showItem.enabled = ![self.passwordWindow.window isVisible])) {
        self.showItem.title   = @"Show (Showing)";
        self.showItem.toolTip = @"Master Password is already showing.";
    } else if (!(self.showItem.enabled = (self.activeUser != nil))) {
        self.showItem.title   = @"Show (No user)";
        self.showItem.toolTip = @"First select the user to show passwords for.";
    } else {
        self.showItem.title   = @"Show";
        self.showItem.toolTip = nil;
    }

    if (self.key) {
        self.lockItem.title   = @"Lock";
        self.lockItem.enabled = YES;
        self.lockItem.toolTip = nil;
    } else {
        self.lockItem.title   = @"Lock (Locked)";
        self.lockItem.enabled = NO;
        self.lockItem.toolTip = @"Master Password is currently locked.";
    }

    self.rememberPasswordItem.state = [[MPConfig get].rememberLogin boolValue]? NSOnState: NSOffState;

    self.savePasswordItem.state     = [MPAppDelegate get].activeUser.saveKey? NSOnState: NSOffState;
    if (!self.activeUser) {
        self.savePasswordItem.title   = @"Save Password (No user)";
        self.savePasswordItem.enabled = NO;
        self.savePasswordItem.toolTip = @"First select your user and unlock by showing the Master Password window.";
    } else if (!self.key) {
        self.savePasswordItem.title   = @"Save Password (Locked)";
        self.savePasswordItem.enabled = NO;
        self.savePasswordItem.toolTip = @"First unlock by showing the Master Password window.";
    } else {
        self.savePasswordItem.title   = @"Save Password";
        self.savePasswordItem.enabled = YES;
        self.savePasswordItem.toolTip = nil;
    }

    self.useICloudItem.state         = [[MPMacConfig get].iCloud boolValue]? NSOnState: NSOffState;
    if (!(self.useICloudItem.enabled = ![[MPMacConfig get].iCloud boolValue])) {
        self.useICloudItem.title   = @"Use iCloud (Required)";
        self.useICloudItem.toolTip = @"iCloud is required in this version.  Future versions will work without iCloud as well.";
    }
    else {
        self.useICloudItem.title   = @"Use iCloud (Required)";
        self.useICloudItem.toolTip = nil;
    }
}

- (void)applicationWillBecomeActive:(NSNotification *)notification {

    if (!self.passwordWindow)
        self.passwordWindow = [[MPPasswordWindowController alloc] initWithWindowNibName:@"MPPasswordWindowController"];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {

    [self.passwordWindow showWindow:self];
}

- (void)applicationWillResignActive:(NSNotification *)notification {

    if (![[MPConfig get].rememberLogin boolValue])
        self.key = nil;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    // Save changes in the application's managed object context before the application terminates.

    NSManagedObjectContext *moc = [MPAppDelegate managedObjectContextForThreadIfReady];
    if (!moc)
        return NSTerminateNow;

    if (![moc commitEditing])
        return NSTerminateCancel;

    if (![moc hasChanges])
        return NSTerminateNow;

    NSError *error = nil;
    if (![moc save:&error])
        err(@"While terminating: %@", error);

    return NSTerminateNow;
}

#pragma mark - UbiquityStoreManagerDelegate

- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager didSwitchToCloud:(BOOL)cloudEnabled {
    
    [super ubiquityStoreManager:manager didSwitchToCloud:cloudEnabled];

    [self updateMenuItems];

    if (![[MPConfig get].iCloudDecided boolValue]) {
        if (cloudEnabled)
            return;
        
        switch ([[NSAlert alertWithMessageText:@"iCloud Is Disabled"
                                 defaultButton:@"Enable iCloud" alternateButton:@"Leave iCloud Off" otherButton:@"Explain?"
                     informativeTextWithFormat:@"It is highly recommended you enable iCloud."] runModal]) {
            case NSAlertDefaultReturn: {
                [MPConfig get].iCloudDecided = @YES;
                manager.cloudEnabled = YES;
                break;
            }
                
            case NSAlertOtherReturn: {
                [[NSAlert alertWithMessageText:@"About iCloud"
                                 defaultButton:[PearlStrings get].commonButtonThanks alternateButton:nil otherButton:nil
                     informativeTextWithFormat:
                  @"iCloud is Apple's solution for saving your data in \"the cloud\" "
                  @"and making sure your other iPhones, iPads and Macs are in sync.\n\n"
                  @"For Master Password, that means your sites are available on all your "
                  @"Apple devices, and you always have a backup of them in case "
                  @"you loose one or need to restore.\n\n"
                  @"Because of the way Master Password works, it doesn't need to send your "
                  @"site's passwords to Apple.  Only their names are saved to make it easier "
                  @"for you to find the site you need.  For some sites you may have set "
                  @"a user-specified password: these are sent to iCloud after being encrypted "
                  @"with your master password.\n\n"
                  @"Apple can never see any of your passwords."] runModal];
                [self ubiquityStoreManager:manager didSwitchToCloud:cloudEnabled];
                break;
            }
                
            default:
                break;
        };
    }
}

@end
