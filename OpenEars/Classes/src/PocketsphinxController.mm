
//  OpenEars 
//  http://www.politepix.com/openears
//
//  PocketsphinxController.mm
//  OpenEars
//
//  PocketsphinxController is a class which controls the creation and management of
//  a continuous speech recognition loop.
//
//  Copyright Politepix UG (haftungsbeschränkt) 2012. All rights reserved.
//  http://www.politepix.com
//  Contact at http://www.politepix.com/contact
//
//  this file is licensed under the Politepix Shared Source license found 
//  found in the root of the source distribution. Please see the file "Version.txt" in the root of 
//  the source distribution for the version number of this OpenEars package.


#import "PocketsphinxController.h"

#import "AudioSessionManager.h"
#import <AudioToolbox/AudioToolbox.h> 

#import "RuntimeVerbosity.h"

#define HAVE_CONFIG_HHAVE_CONFIG_H
@implementation PocketsphinxController

@synthesize voiceRecognitionThread; // A thread so that we can instantiate the continuous recognition loop in the background.
@synthesize continuousModel; // The class containing the actual continuous loop.
@synthesize openEarsEventsObserver; // A class that we'll use to be informed of some important status changes in other parts of OpenEars.
@synthesize secondsOfSilenceToDetect;
@synthesize returnNbest;
@synthesize nBestNumber;
@synthesize calibrationTime;
@synthesize verbosePocketSphinx;
@synthesize processSpeechLocally;
@synthesize outputAudio;
@synthesize sampleRate;
@synthesize returnNullHypotheses;
@synthesize stopping;
@synthesize queuedStart;
@synthesize pathToTestFile;
@synthesize audioSessionMixing;
@synthesize audioMode;

extern int openears_logging;
extern int verbose_pocketsphinx;
extern int input_sample_rate;

#pragma mark -
#pragma mark Initialization and Memory Management

#if TARGET_IPHONE_SIMULATOR
NSString * const DeviceOrSimulator = @"Simulator";
#else
NSString * const DeviceOrSimulator = @"Device";
#endif

- (void)dealloc {

	openEarsEventsObserver.delegate = nil; // When releasing a class that uses a delegate of OpenEarsEventsObserver, set its delegate to nil before releasing.
	[openEarsEventsObserver release]; 
	[voiceRecognitionThread release];
	[continuousModel release];
    [queuedStart release];
    [pathToTestFile release];
    [super dealloc];
}

- (id) init
{
    if ( self = [super init] )
    {

        calibrationTime = 1;
        returnNbest = FALSE;
        nBestNumber = 4;
		continuousModel.exitListeningLoop = 0; // We'll change this when we're ready to exit the loop, for now initialize it to zero.
		continuousModel.inMainRecognitionLoop = FALSE; // We aren't in the main recognition loop.
        processSpeechLocally = TRUE;
        outputAudio = FALSE;
        returnNullHypotheses = FALSE;
        stopping = FALSE;
        audioSessionMixing = FALSE;

    }
    return self;
}

#pragma mark -
#pragma mark Lazy Accessors

// A lazy accessor for the continuous loop.
- (ContinuousModel *)continuousModel {
	if (continuousModel == nil) {
		continuousModel = [[ContinuousModel alloc] init];
        continuousModel.delegate = self;
	}
	return continuousModel;
}

// A lazy accessor for the OpenEarsEventsObserver.
- (OpenEarsEventsObserver *)openEarsEventsObserver {
	if (openEarsEventsObserver == nil) {
		openEarsEventsObserver = [[OpenEarsEventsObserver alloc] init];
        openEarsEventsObserver.delegate = self;
	}
	return openEarsEventsObserver;
}


#pragma mark -
#pragma mark OpenEarsEventsObserver Delegate Methods

// We're just asking for a few delegate methods from OpenEarsEventsObserver so we can react to some specific situations.

- (void) audioRouteDidChangeToRoute:(NSString *)newRoute { // We want to know if the audio route has changed because the ContinuousModel does something different while recording for the headphones route only.

		[self.continuousModel setCurrentRouteTo:newRoute];
}

- (void) fliteDidStartSpeaking { // We need to know when Flite is talking because under some circumstances we will suspend recognition at that time.
	if([DeviceOrSimulator isEqualToString:@"Simulator"]) {
		if(self.continuousModel.inMainRecognitionLoop == TRUE) { // The simulator will crash if we query the current route
			[self suspendRecognitionForFliteSpeech];
		}
	} else {
        
		if(self.continuousModel.inMainRecognitionLoop == TRUE && [[NSString stringWithFormat:@"%@",[self.continuousModel getCurrentRoute]] isEqualToString:@"HeadsetInOut"]==FALSE) { // Only suspend listening if we aren't using headphones, otherwise it's unnecessary

			[self suspendRecognitionForFliteSpeech];
		}		
	}
}
	
- (void) fliteDidFinishSpeaking { // We need to know when Flite is done talking because under some circumstances we will resume recognition at that time.
	if([DeviceOrSimulator isEqualToString:@"Simulator"]) {
		if(self.continuousModel.inMainRecognitionLoop == TRUE) { // The simulator will crash if we query the current route

			[self resumeRecognitionForFliteSpeech];
		}
	} else {

		if(self.continuousModel.inMainRecognitionLoop == TRUE && [[NSString stringWithFormat:@"%@",[self.continuousModel getCurrentRoute]] isEqualToString:@"HeadsetInOut"]==FALSE) { // Only resume listening if we suspended it due to not using headphones

			[self resumeRecognitionForFliteSpeech];
		}		
	}
}
		
		
#pragma mark -
#pragma mark Recognition Control Methods

- (void) validateNBestSettings {
    if(self.returnNbest == TRUE) {
        self.continuousModel.returnNbest = TRUE;
        self.continuousModel.nBestNumber = self.nBestNumber;
    } else {
        self.continuousModel.returnNbest = FALSE;
    }
}

- (void) startListeningWithLanguageModelAtPath:(NSString *)languageModelPath dictionaryAtPath:(NSString *)dictionaryPath acousticModelAtPath:(NSString *)acousticModelPath languageModelIsJSGF:(BOOL)languageModelIsJSGF { // This is an externally-called method that tells this class to detach a new thread and eventually start up the listening loop.

    [self.openEarsEventsObserver setDelegate:self]; // Before we start we need to sign up for the delegate methods of OpenEarsEventsObserver so we can receive important information about the other OpenEars classes.
    
    if(self.stopping == TRUE) {
        self.queuedStart = [NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:languageModelPath, dictionaryPath, acousticModelPath, [NSNumber numberWithBool:languageModelIsJSGF],nil] forKeys:[NSArray arrayWithObjects:@"LanguageModelPath",@"DictionaryPath", @"AcousticModelPath", @"LanguageModelIsJSGF",nil]];

    } else {
    
    
        if (voiceRecognitionThread != nil) { // If it already exists, stop it.
            [self stopVoiceRecognitionThread];
        }
        
        if(self.outputAudio == TRUE) {
            self.continuousModel.outputAudio = TRUE;
        } else {
            self.continuousModel.outputAudio = FALSE;
            
        }

        if(self.returnNullHypotheses == TRUE) {
            self.continuousModel.returnNullHypotheses = TRUE;
        } else {
            self.continuousModel.returnNullHypotheses = FALSE;
        }
        
        if(self.audioSessionMixing == TRUE) {
            [[AudioSessionManager sharedAudioSessionManager] setSoundMixing:TRUE];
        }

        if(self.audioMode && [self.audioMode length] > 4) {
            [[AudioSessionManager sharedAudioSessionManager] setAudioMode:self.audioMode];
        }
        
        if(self.sampleRate == 16000) { // This evaluation is the only place in the project that input_sample_rate can be written and not just read.
            if(openears_logging == 1)NSLog(@"setting sample rate to 16000");
            input_sample_rate = 16000;
        } else if(self.sampleRate == 8000){
            if(openears_logging == 1)NSLog(@"setting sample rate to 8000");        
            input_sample_rate = 8000;
       
        } else {
            if(openears_logging == 1) NSLog(@"A sample rate was requested that isn't one of the two supported values of 16000 or 8000 so we will use the default of 16000.");
            input_sample_rate = 16000;
        }
        

        AudioSessionManager *sharedAudioSessionManager = [AudioSessionManager sharedAudioSessionManager];
        [sharedAudioSessionManager startAudioSession]; // Now we don't start the audio session manager until right before we run listening so we can catch the input sample rate.
        
        if(self.processSpeechLocally == TRUE) {
            self.continuousModel.processSpeechLocally = TRUE;
        } else {
            self.continuousModel.processSpeechLocally = FALSE;
            
        }
        
        if(self.verbosePocketSphinx == 1) {
            verbose_pocketsphinx = 1;
        }
        
        [self validateNBestSettings];
        
        UInt32 audioInputAvailable = 0; 
        UInt32 size = sizeof(audioInputAvailable);
        OSStatus audioInputAvailableError = AudioSessionGetProperty(kAudioSessionProperty_AudioInputAvailable, &size, &audioInputAvailable);
        if (audioInputAvailableError != noErr || audioInputAvailable == 0) {
            if(openears_logging == 1) NSLog(@"Error: Unable to get the availability of the audio input, not starting PocketsphinxController.");

        } else {
            [self startVoiceRecognitionThreadWithLanguageModelAtPath:languageModelPath dictionaryAtPath:dictionaryPath acousticModelAtPath:(NSString *)acousticModelPath languageModelIsJSGF:languageModelIsJSGF];
        }  
    }
}

// Run one recognition round on a recording and return the hypothesis and score. Synchronous.

- (void) runRecognitionOnWavFileAtPath:(NSString *)wavPath usingLanguageModelAtPath:(NSString *)languageModelPath dictionaryAtPath:(NSString *)dictionaryPath acousticModelAtPath:(NSString *)acousticModelPath languageModelIsJSGF:(BOOL)languageModelIsJSGF { 

    if(self.verbosePocketSphinx == 1) {
        verbose_pocketsphinx = 1;
    }
    
    [self validateNBestSettings];

    [self.continuousModel runRecognitionOnWavFileAtPath:wavPath usingLanguageModelAtPath:languageModelPath dictionaryAtPath:dictionaryPath acousticModelAtPath:acousticModelPath languageModelIsJSGF:languageModelIsJSGF];
    
}


- (void) stopListening { // This is an externally-called method that tells this class to exit the voice recognition loop and eventually close up the voice recognition thread.
    self.stopping = TRUE;
	self.continuousModel.exitListeningLoop = 1;
}

- (void) suspendRecognitionForFliteSpeech { // We will react a little differently to the situation in which Flite is asking for a suspend than when the developer is.
	if(self.continuousModel.inMainRecognitionLoop && [self.continuousModel getRecognitionIsInProgress] == 1) {
		[self.continuousModel setRecognitionIsInProgressTo:0];
	}
}

- (void) resumeRecognitionForFliteSpeech { // We will react a little differently to the situation in which Flite is asking for a resume than when the developer is.
    
	if(self.continuousModel.inMainRecognitionLoop && [self.continuousModel getRecognitionIsInProgress] == 0) {
        [self setSecondsOfSilence]; // Set seconds of silence to whatever the user has requested, if they have
		[self.continuousModel setRecognitionIsInProgressTo:1];
	}
}

- (void) suspendRecognition { // This is the externally-called method that tells the class to suspend recognition without exiting the recognition loop.
    
    [self.continuousModel clearBuffers];// Clear the buffer

	if(self.continuousModel.inMainRecognitionLoop && [self.continuousModel getRecordData] == 1) { // If it's safe and relevant to try to suspend,
		[self.continuousModel setRecordDataTo:0]; // Tell the driver not to record data.
		NSDictionary *userInfoDictionary = [NSDictionary dictionaryWithObject:@"PocketsphinxDidSuspendRecognition" forKey:@"OpenEarsNotificationType"]; // And tell OpenEarsEventsObserver we've suspended.
		NSNotification *notification = [NSNotification notificationWithName:@"OpenEarsNotification" object:nil userInfo:userInfoDictionary];
		[[NSNotificationCenter defaultCenter] performSelectorOnMainThread:@selector(postNotification:) withObject:notification waitUntilDone:NO];
	}
}

- (void) resumeRecognition { // This is the externally-called method that tells the class to resume recognition after it was suspended without exiting the recognition loop.
	
	if(self.continuousModel.inMainRecognitionLoop && [self.continuousModel getRecordData] == 0) {	 // If it's safe and relevant to try to resume,
        [self setSecondsOfSilence]; // Set seconds of silence to whatever the user has requested, if they have
		[self.continuousModel setRecordDataTo:1];// Tell the driver to record data.
	
		NSDictionary *userInfoDictionary = [NSDictionary dictionaryWithObject:@"PocketsphinxDidResumeRecognition" forKey:@"OpenEarsNotificationType"]; // And tell OpenEarsEventsObserver we've resumed.
		NSNotification *notification = [NSNotification notificationWithName:@"OpenEarsNotification" object:nil userInfo:userInfoDictionary];
		[[NSNotificationCenter defaultCenter] performSelectorOnMainThread:@selector(postNotification:) withObject:notification waitUntilDone:NO];
	}
}

- (void) changeLanguageModelToFile:(NSString *)languageModelPathAsString withDictionary:(NSString *)dictionaryPathAsString { // If you have already started the recognition loop and you want to switch to a different language model, you can use this and the model will be changed at the earliest opportunity. Will not have any effect unless recognition is already in progress.
	[self.continuousModel changeLanguageModelToFile:languageModelPathAsString withDictionary:dictionaryPathAsString];
}

- (Float32) pocketsphinxInputLevel { // This can only be run in a background thread that you create, otherwise it will block recognition.  It returns the metering level of the Pocketsphinx audio device at the moment it's called.
	return [self.continuousModel getMeteringLevel];
}

- (void) setSecondsOfSilence {
    // Set seconds of silence to detect if the user has set one and it is a realistic value
    if(self.secondsOfSilenceToDetect && self.secondsOfSilenceToDetect > .05 && self.secondsOfSilenceToDetect < 20) {
        self.continuousModel.secondsOfSilenceToDetect = self.secondsOfSilenceToDetect;
    } else {
        self.continuousModel.secondsOfSilenceToDetect = .7; // Otherwise set it to the default value
    }    
}

#pragma mark -
#pragma mark Pocketsphinx Threading

	- (void) startVoiceRecognitionThreadAutoreleasePoolWithArray:(NSArray *)arrayOfLanguageModelItems { // This is the autorelease pool in which the actual business of our loop is handled.

	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init]; // Create the pool.
	
	[NSThread setThreadPriority:.9];     // Give the voice recognition thread high priority for accuracy, though slightly lower than speech (which only occurs rarely, so generally this thread will have the highest priority).
        
        [self setSecondsOfSilence]; // Set seconds of silence to whatever the user has requested, if they have
        self.continuousModel.calibrationTime = self.calibrationTime;
        if(self.pathToTestFile && [self.pathToTestFile length]>10) { // If there is a request to run the engine over a wav file, set it up here.
            self.continuousModel.pathToTestFile = self.pathToTestFile;
        }
        [self.continuousModel listeningLoopWithLanguageModelAtPath:[arrayOfLanguageModelItems objectAtIndex:0] dictionaryAtPath:[arrayOfLanguageModelItems objectAtIndex:1] acousticModelAtPath:[arrayOfLanguageModelItems objectAtIndex:2] languageModelIsJSGF:[[arrayOfLanguageModelItems objectAtIndex:3] intValue]]; // Call the listening loop inside of the autorelease pool.
	[pool drain]; // Drain the pool.
}

- (void) startVoiceRecognitionThreadWithLanguageModelAtPath:(NSString *)languageModelPath dictionaryAtPath:(NSString *)dictionaryPath acousticModelAtPath:(NSString *)acousticModelPath languageModelIsJSGF:(BOOL)languageModelIsJSGF { // Create a new thread for voice recognition.
	
    NSThread *voiceRecThread = [[NSThread alloc] initWithTarget:self selector:@selector(startVoiceRecognitionThreadAutoreleasePoolWithArray:) object:[NSArray arrayWithObjects:languageModelPath,dictionaryPath,acousticModelPath,[NSNumber numberWithBool:languageModelIsJSGF],nil]]; // Then create a thread with the characteristics we want,
    self.voiceRecognitionThread = voiceRecThread; // And give our class thread object those characteristics.
    [voiceRecThread release]; // Get rid of the first thread.
	voiceRecThread = nil; // Set it to nil.
    [self.voiceRecognitionThread start]; // Ask the class voice recognition thread to start up.
}

- (void)waitForVoiceRecognitionThreadToFinish { 
    while (voiceRecognitionThread && ![voiceRecognitionThread isFinished]) { // Wait for the thread to finish.
		[NSThread sleepForTimeInterval:0.1]; // If the thread can't finish yet, sleep.
    }	
}

- (void)stopVoiceRecognitionThread { // This will be called before releasing this class.

    [self.voiceRecognitionThread cancel]; // Ask the thread to stop,
    
	[self waitForVoiceRecognitionThreadToFinish]; // Wait for it to finish,

    self.voiceRecognitionThread = nil; // Set it to nil if that happens successfully.
    self.stopping = FALSE; // We're no longer stopping so if there is a start requested that we previously ignored, let's do it now.
    if(self.queuedStart != nil) {
        
        if([self.queuedStart objectForKey:@"LanguageModelIsJSGF"]) { // This is an OpenEars invocation
              [self startListeningWithLanguageModelAtPath:[self.queuedStart objectForKey:@"LanguageModelPath"] dictionaryAtPath:[self.queuedStart objectForKey:@"DictionaryPath"] acousticModelAtPath:[self.queuedStart objectForKey:@"AcousticModelPath"]languageModelIsJSGF:[[self.queuedStart objectForKey:@"LanguageModelIsJSGF"]boolValue]];
        } else { // This is a RapidEars invocation, only sent if RapidEars is installed and the start request was for RapidEars.
            if([self respondsToSelector:@selector(startRealtimeListeningWithLanguageModelAtPath:dictionaryAtPath:acousticModelAtPath:)]) {
              
                
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-method-access" // Not a helpful warning right here.
                
                [self startRealtimeListeningWithLanguageModelAtPath:[self.queuedStart objectForKey:@"LanguageModelPath"] dictionaryAtPath:[self.queuedStart objectForKey:@"DictionaryPath"] acousticModelAtPath:[self.queuedStart objectForKey:@"AcousticModelPath"]];
                
#pragma clang diagnostic pop                
            }
        }
      
        self.queuedStart = nil;
    }    
}

- (void) listeningLoopHasEnded {

    [self performSelectorOnMainThread:@selector(stopVoiceRecognitionThread) withObject:nil waitUntilDone:NO];

}

- (void) removeCmnPlist { // You can use this to remove the SmartCMN plist if you want to reset it.
    [self.continuousModel removeCmnPlist];
}
@end
