//
//  BVBackgroundHelper.m
//  backgroundvoip
//
//  Created by Sergey Mamontov on 4/11/14.
//  Copyright (c) 2014 Sergey Mamontov. All rights reserved.
//

#import "BVBackgroundHelper.h"
#import <AVFoundation/AVFoundation.h>
#import "BVAlertView.h"


#pragma mark Static

/**
 Stores reference on action which should be treated as APNS notification simulation.
 */
static NSString * const kBVMessageAPNSAction = @"apns";

/**
 Stores reference on key under which concrete notification identifier is stored.
 */
static NSString * const kBVNotificationIdentifierKey = @"identifier";

/**
 Stores reference on identifier of notification which is issued by helper itself to somehow inform user in case if
 application will be suspended by system and should be relaunched.
 */
static NSString * const kBVBackgroundHelperNotificationIdentifier = @"com.background.helper.notification";

/**
 Stores reference on minimum difference in time before local notification should be reissued.
 */
static NSTimeInterval const kBVBackgroundMinimumTimeBeforeNotificationFire = 15.0f;

/**
 Stores reference on interval after which local notification should be checked.
 */
static NSTimeInterval const kBVLocalNotificationCheckInterval = 4.0f;


#pragma mark - Structures

struct BVMessagePayloadKeysStruct {
    
    /**
     Under this key expected action is stored.
     */
    __unsafe_unretained NSString *actionType;
    
    /**
     Under this key store message which should be shown with notification center.
     */
    __unsafe_unretained NSString *message;
};

struct BVMessagePayloadKeysStruct BVMessagePayloadKeys = {
    
    .actionType = @"action",
    .message = @"message"
};


#pragma mark - Private interface declaration

@interface BVBackgroundHelper () <AVAudioSessionDelegate>


#pragma mark - Properties
/**
 Stores reference on block which should be used by helper to complete application stack and PubNub client
 configuration.
 */
@property (nonatomic, copy) void(^completionHandler)(void(^)(void));

/**
 Stores reference on block which should be used by helper in case if stack reinitialization will be required.
 */
@property (nonatomic, copy) void(^reinitializationBlock)(void);

/**
 Stores reference on audio player which is used during application execution in background context support. This instance
 will play silent sound to keep app running in background.
 */
@property (nonatomic, strong) AVAudioPlayer *player;

/**
 Stores whether player playback has been interrupted or not.
 */
@property (nonatomic, assign, getter = isInterrupted) BOOL interrupted;

/**
 Stores reference on next local notification fire date (will be used to check whether shoould update notification or not).
 */
@property (nonatomic, strong) NSDate *nextLocalNotificationFireDate;

/**
 Stores reference on timer which is used for local notification state check.
 */
@property (nonatomic, strong) NSTimer *localNotificationCheckTimer;


#pragma mark - Class methods

+ (BVBackgroundHelper *)sharedInstance;


#pragma mark - Instance methods

/**
 Prepare audio session and player for further usage to support application execution in background context.
 */
- (void)prepareAudioSession;

/**
 Launch audio player which will force application to keep working in background (till interruption by call).
 */
- (void)startBackgroundSupportWithAudio;

/**
 Can be used to pause audio till next moment when background support with audio maybe required.
 */
- (void)stopBackgroundSupportWithAudio;

/**
 Launch background support using VoIP functionality. System will give us ability to call re-initialization block after
 some amount of time.
 Basically this approach will be used by helper to make sure that sockets will survive connection termination because of 
 interruption with a phone call.
 */
- (void)startBackgroundSupportWithVoIP;

/**
 Ask system to stop reissue re-initialization block and stop counting how many messages has been received in background.
 */
- (void)stopBackgroundSupportWithVoIP;

/**
 Start background execution support (if required) using suitable approach for current situation.
 */
- (void)startBackgroundSupport;

/**
 Stop currently enabled background execution support (if possible).
 */
- (void)stopBackgroundSupport;

/**
 Schedule application launch notification.
 */
- (void)rescheduleReminderNotification;
- (void)cancelReminderNotification;

/**
 Launch and stop local notification verification process (required to reschedule local notification if required).
 */
- (void)startLocalNotificationCheck;
- (void)stopLocalNotificationCheck;


#pragma mark - Handler methods

- (void)handleApplicationDidEnterBackground:(NSNotification *)notification;
- (void)handleApplicationDidBecomeActive:(NSNotification *)notification;


#pragma mark - Misc methods

- (void)handleNewMessage:(PNMessage *)message;

#pragma mark -


@end


#pragma mark Public interface implementation

@implementation BVBackgroundHelper


#pragma mark - Class methods

+ (BVBackgroundHelper *)sharedInstance {
    
    static BVBackgroundHelper *_sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        
        _sharedInstance = [self new];
    });
    
    
    return _sharedInstance;
}

+ (void)prepareWithInitializationCompleteHandler:(void(^)(void(^)(void)))completionHandler
                        andReinitializationBlock:(void(^)(void))reinitializationBlock {

    [self sharedInstance].reinitializationBlock = ^{

        if (reinitializationBlock) {

            reinitializationBlock();
        }
    };
    [self sharedInstance].completionHandler = completionHandler;
}

+ (void)connectWithSuccessBlock:(void(^)(NSString *))success errorBlock:(void(^)(PNError *))failure {
    
    [[self sharedInstance] startBackgroundSupport];
    [PubNub connectWithSuccessBlock:success errorBlock:failure];
}

#pragma mark - Instance methods

- (id)init {
    
    // Check whether initialization has been successful or not.
    if ((self = [super init])) {
        
        [self prepareAudioSession];

        __block __pn_desired_weak __typeof(self) weakSelf = self;

        // Subscribe on PubNub client connection state observation.
        [[PNObservationCenter defaultCenter] addClientConnectionStateObserver:self
                                                            withCallbackBlock:^(NSString *origin, BOOL connected,
                                                                                PNError *connectionError) {

            if (connected) {
                
                void(^completionHandler)(void) = ^{
                    
                    [weakSelf startBackgroundSupport];
                };
                
                if (weakSelf.completionHandler) {
                    
                    // Passing block which will be called by user at the end of his preparations to switch
                    // execution mode back to VoIP style.
                    weakSelf.completionHandler(completionHandler);
                }
                else {
                    
                    completionHandler();
                }
            }
            // Looks like client is unable to connect because of some reasons (no internet connection or troubles
            // with SSL),
            else if (connectionError) {

                PNLog(PNLogGeneralLevel, weakSelf, @"{ERROR} Looks like PubNub client were unable to connect to the "
                      "origin because of error: %@", connectionError.localizedFailureReason);

                switch (connectionError.code) {

                    case kPNClientConnectionFailedOnInternetFailureError:
                    case kPNClientConnectionClosedOnInternetFailureError:
                    case kPNClientConnectionClosedOnServerRequestError:
                        
                        [weakSelf startBackgroundSupport];
                        break;
                    default:
                        break;
                }
            }
            // Looks like PubNub client doesn't have enough time to complete network availability check so we just
            // need to wait. Or client has been disconnected by user request.
            else if (!connectionError && !connected) {

                PNLog(PNLogGeneralLevel, weakSelf, @"{INFO} PubNub client wasn't able to check network connection "
                      "availability or disconnected by user request");
                
                [weakSelf startBackgroundSupport];
            }
        }];
        
        [[PNObservationCenter defaultCenter] addMessageReceiveObserver:self withBlock:^(PNMessage *message) {
            
            [self handleNewMessage:message];
        }];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleApplicationDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleApplicationDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    
    
    return self;
}

- (void)prepareAudioSession {
    
    // Preparing local variables to store error from corresponding actions (if they will appear).
    NSError *sessionCategoryConfigurationError;
    NSError *playerInitializationError;
    NSError *sessionActivationError;
    
    [[AVAudioSession sharedInstance] setDelegate:self];
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                           error:&sessionCategoryConfigurationError];
    
    if (!sessionCategoryConfigurationError) {
        
        [[AVAudioSession sharedInstance] setActive:YES error:&sessionActivationError];
        
        if (!sessionActivationError) {
            
            // Compose URL to the sound which will be used to keep application in background by playing same sound in the loop.
            NSString *pathToTheFile = [[NSBundle mainBundle] pathForResource:@"background-sound" ofType:@"m4a"];
            
            if (pathToTheFile) {
                
                self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:pathToTheFile]
                                                                     error:&playerInitializationError];
                if (!playerInitializationError) {
                    
                    // Additionaly reducing volume in case if sound has some noise in it.
                    self.player.volume = 0.1f;
                    
                    // Configure to play sound forever (looped).
                    self.player.numberOfLoops = -1;
                }
                else {
                    
                    self.player = nil;
                    
                    PNLog(PNLogGeneralLevel, self, @"{ERROR} Audio player initialization failed with error: %@",
                          playerInitializationError);
                }
            }
            else {
                
                PNLog(PNLogGeneralLevel, self, @"{ERROR} Audio player can't be used, because specified sound can't be "
                      "found in application bundle.");
            }
        }
        else {
            
            PNLog(PNLogGeneralLevel, self, @"{ERROR} Audio session activation failed with error: %@",
                  sessionActivationError);
        }
    }
    else {
        
        PNLog(PNLogGeneralLevel, self, @"{ERROR} Audio session configuration failed with error: %@",
              sessionCategoryConfigurationError);
    }
}

- (void)startBackgroundSupportWithAudio {
    
    if (self.player) {
        
        if (![self.player isPlaying]) {
            
            PNLog(PNLogGeneralLevel, self, @"{INFO} Use audio player to support background execution.");
        
            [self.player play];
        }
    }
    else {
        
        PNLog(PNLogGeneralLevel, self, @"{ERROR} Audio can't be used to support application execution in background context.");
    }
}

- (void)stopBackgroundSupportWithAudio {
    
    if (self.player) {
        
        if ([self.player isPlaying]) {
            
            PNLog(PNLogGeneralLevel, self, @"{INFO} Stop using audio player background execution support.");
            
            [self.player stop];
        }
    }
    else {
        
        PNLog(PNLogGeneralLevel, self, @"{ERROR} There is no valid audio player which can stopped.");
    }
}

- (void)startBackgroundSupportWithVoIP {
    
    // Checking whether re-initializarion block has been provided, so system will be able to use it for
    // stack re-initialization.
    if (self.reinitializationBlock) {
        
        PNLog(PNLogGeneralLevel, self, @"{INFO} Use VoIP to support background execution.");
        
        // In case if client was unable to connect or connect to controlling channel we will ask system to
        // pull our application back in 10 minutes and 10 seconds.
        [[UIApplication sharedApplication] setKeepAliveTimeout:610 handler:self.reinitializationBlock];
    }
    else {
        
        PNLog(PNLogGeneralLevel, self, @"{INFO} Stop using VoIP background execution support because there is no "
              "re-initialization block has been provided.");
        
        // User didn't specified any block which can be used for stack reinitialization so we cancel our
        // request to periodically awake application.
        [[UIApplication sharedApplication] clearKeepAliveTimeout];
    }
}

- (void)stopBackgroundSupportWithVoIP {
    
    PNLog(PNLogGeneralLevel, self, @"{INFO} Stop using VoIP background execution support.");
    
    // Unregister from awakening on specified intervals to maintain connection to the origin.
    [[UIApplication sharedApplication] clearKeepAliveTimeout];
}

- (void)startBackgroundSupport {
    
    // Checking whether method has been called while application is executed in background execution context or not.
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
    
        // Checking whether current audio session has been interruped or not.
        if (self.isInterrupted) {
            
            // While audio session is inactive, only VoIP can be used (but not guaranteed that system will awake application
            // when new messages will arrive, but at least will maintain sockets).
            [self startBackgroundSupportWithVoIP];
            
            // Stop previously started background execution support which used audio player fot this purpose.
            [self stopBackgroundSupportWithAudio];
        }
        else {
            
            // Audio session is available and we can use audio to keep app running in background.
            [self startBackgroundSupportWithAudio];
            
            // Stop previously started background execution support which used VoIP fot this purpose.
            [self stopBackgroundSupportWithVoIP];
        }
    }
    // Looks like application operation in active state and we can discard any background support approaches.
    else {

        [self stopBackgroundSupport];
    }
}

- (void)stopBackgroundSupport {
    
    [self stopBackgroundSupportWithAudio];
    [self stopBackgroundSupportWithVoIP];
}

- (void)rescheduleReminderNotification {
    
    // Calculate how much time is left before loocal notification will appear.
    NSTimeInterval timeBeforeNotificationApper = [self.nextLocalNotificationFireDate timeIntervalSinceDate:[NSDate date]];
    
    // Checking whether helper should update local notification data or schedule new one.
    if (!self.nextLocalNotificationFireDate ||
        (self.nextLocalNotificationFireDate && timeBeforeNotificationApper < kBVBackgroundMinimumTimeBeforeNotificationFire)) {
        
        __block UILocalNotification *reminderNotification;
        
        // Make a copy, so it won't be mutabed while iterated.
        NSArray *notifications = [[UIApplication sharedApplication].scheduledLocalNotifications copy];
        [[notifications copy] enumerateObjectsUsingBlock:^(UILocalNotification *notification, NSUInteger notificationIdx,
                                                           BOOL *notificationEnumeratorStop) {
            
            NSString *notificationIdentifier = [notification.userInfo valueForKeyPath:kBVNotificationIdentifierKey];
            if ([notificationIdentifier isEqualToString:kBVBackgroundHelperNotificationIdentifier]) {
                
                reminderNotification = notification;
                [[UIApplication sharedApplication] cancelLocalNotification:notification];
            }
        }];
        
        BOOL shouldSchedule = NO;
        if (!reminderNotification) {
            
            shouldSchedule = YES;
            
            reminderNotification = [UILocalNotification new];
            reminderNotification.alertBody = @"Launch me please ;)";
            reminderNotification.alertAction = @"Launch...";
            reminderNotification.userInfo = @{kBVNotificationIdentifierKey:kBVBackgroundHelperNotificationIdentifier};
            
            // Storing date for future computations
            self.nextLocalNotificationFireDate = [NSDate dateWithTimeIntervalSinceNow:60.0f];
            
            // Actual reminder will be fired in 60 seconds (if it won't be canceled by next round of application activity).
            reminderNotification.fireDate = self.nextLocalNotificationFireDate;
            
            // Next time if application not working, than in a hour user will be notified about that..
            reminderNotification.repeatInterval = NSHourCalendarUnit;
        }
        else {
                
            shouldSchedule = YES;
            
            // Storing date for future computations
            self.nextLocalNotificationFireDate = [NSDate dateWithTimeIntervalSinceNow:60.0f];
            
            // Update actual reminder will be fired in 60 seconds (if it won't be canceled by nex round of application activity).
            reminderNotification.fireDate = self.nextLocalNotificationFireDate;
        }
        
        if (shouldSchedule && [UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
            
            [[UIApplication sharedApplication] scheduleLocalNotification:reminderNotification];
        }
    }
}

- (void)cancelReminderNotification {
    
    // Checking whether local notification has been scheduled before or not.
    if (self.nextLocalNotificationFireDate) {
        
        // Make a copy, so it won't be mutabed while iterated.
        NSArray *notifications = [[UIApplication sharedApplication].scheduledLocalNotifications copy];
        [[notifications copy] enumerateObjectsUsingBlock:^(UILocalNotification *notification, NSUInteger notificationIdx,
                                                           BOOL *notificationEnumeratorStop) {
            
            NSString *notificationIdentifier = [notification.userInfo valueForKeyPath:kBVNotificationIdentifierKey];
            if ([notificationIdentifier isEqualToString:kBVBackgroundHelperNotificationIdentifier]) {
                
                [[UIApplication sharedApplication] cancelLocalNotification:notification];
            }
        }];
        
        self.nextLocalNotificationFireDate = nil;
    }
}

- (void)startLocalNotificationCheck {
    
    [self stopLocalNotificationCheck];
    
    self.localNotificationCheckTimer = [NSTimer timerWithTimeInterval:kBVLocalNotificationCheckInterval
                                                               target:self selector:@selector(rescheduleReminderNotification)
                                                             userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.localNotificationCheckTimer forMode:NSRunLoopCommonModes];
}

- (void)stopLocalNotificationCheck {
    
    if ([self.localNotificationCheckTimer isValid]) {
        
        [self.localNotificationCheckTimer invalidate];
    }
    self.localNotificationCheckTimer = nil;
}


#pragma mark - Handler methods

- (void)handleApplicationDidEnterBackground:(NSNotification *)notification {
    
    NSLog(@"[BVBackgroundHelper::State] Application entered background execution context");
    
    [self  startLocalNotificationCheck];
    [self startBackgroundSupport];
}

- (void)handleApplicationDidBecomeActive:(NSNotification *)notification {

    NSLog(@"[BVBackgroundHelper::State] Application entered foreground execution context");

    [UIApplication sharedApplication].applicationIconBadgeNumber = 0;
    [self stopLocalNotificationCheck];
    [self cancelReminderNotification];
    [self stopBackgroundSupport];
}



#pragma mark - Misc methods

- (void)handleNewMessage:(PNMessage *)message {
    
    void(^showMessageAlertView)(id) = ^(id messageForAlertView) {
        
        NSString *message = messageForAlertView;
        if (![message respondsToSelector:@selector(length)]) {
            
            NSError *error;
            NSData *messageData = [NSJSONSerialization dataWithJSONObject:message options:NSJSONWritingPrettyPrinted
                                                                    error:&error];
            message = [[NSString alloc] initWithData:messageData encoding:NSUTF8StringEncoding];
        }
        BVAlertView *alert = [BVAlertView viewWithTitle:@"New message" type:BVAlertSuccess
                                           shortMessage:@"There is a new message for you."
                                        detailedMessage:message cancelButtonTitle:nil otherButtonTitles:nil
                                  andEventHandlingBlock:NULL];
        [alert show];
    };
    
    if ([message.message isKindOfClass:[NSDictionary class]]) {
        
        NSDictionary *messagePayload = (NSDictionary *)message.message;
        if ([[messagePayload valueForKeyPath:BVMessagePayloadKeys.actionType] isEqualToString:kBVMessageAPNSAction]) {
            
            id messageToShow = [messagePayload valueForKeyPath:BVMessagePayloadKeys.message];
            
            // Checking whether method has been called while application is executed in background execution context or not.
            if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
                
                NSInteger applicationBadgeCount = [UIApplication sharedApplication].applicationIconBadgeNumber;
                [UIApplication sharedApplication].applicationIconBadgeNumber = (applicationBadgeCount + 1);
                
                UILocalNotification *messageNotification = [UILocalNotification new];
                messageNotification.alertBody = messageToShow;
                messageNotification.alertAction = @"Show application";
                messageNotification.fireDate = [NSDate date];
                [[UIApplication sharedApplication] scheduleLocalNotification:messageNotification];
            }
            else {
                
                showMessageAlertView(messageToShow);
            }
        }
        else {
            
            showMessageAlertView(messagePayload);
        }
    }
    else {
        
        showMessageAlertView(message.message);
    }
}


#pragma mark - AVAudioSession delegate methods

- (void)beginInterruption {
    
    NSLog(@"[BVBackgroundHelper::Audio] Audio interruption started.");
    self.interrupted = YES;
    [self startBackgroundSupport];
}

- (void)endInterruption {
    
    NSLog(@"[BVBackgroundHelper::Audio] Audio interruption completed.");
    self.interrupted = NO;
    [self startBackgroundSupport];
}

#pragma mark -


@end