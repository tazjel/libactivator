#import "libactivator.h"

#import <SpringBoard/SpringBoard.h>
#import <CaptainHook/CaptainHook.h>

#include <objc/runtime.h>
#include <sys/stat.h>
#include <notify.h>

NSString * const LAActivatorSettingsFilePath = @"/User/Library/Caches/LibActivator/libactivator.plist";

NSString * const LAEventModeAny         = @"any";
NSString * const LAEventModeSpringBoard = @"springboard";
NSString * const LAEventModeApplication = @"application";
NSString * const LAEventModeLockScreen  = @"lockscreen";

CHDeclareClass(SBIconController);

CHConstructor {
	CHLoadLateClass(SBIconController);
}

@implementation LAEvent

+ (id)eventWithName:(NSString *)name
{
	return [[[self alloc] initWithName:name] autorelease];
}

+ (id)eventWithName:(NSString *)name mode:(NSString *)mode
{
	return [[[self alloc] initWithName:name mode:mode] autorelease];
}

- (id)initWithName:(NSString *)name
{
	if ((self = [super init])) {
		_name = [name copy];
		_mode = [LAEventModeAny copy];
	}
	return self;
}

- (id)initWithName:(NSString *)name mode:(NSString *)mode
{
	if ((self = [super init])) {
		_name = [name copy];
		_mode = [mode copy];
	}
	return self;
}

- (void)dealloc
{
	[_name release];
	[_mode release];
	[super dealloc];
}

- (NSString *)name
{
	return _name;
}

- (NSString *)mode
{
	return _mode;
}

- (BOOL)isHandled
{
	return _handled;
}

- (void)setHandled:(BOOL)isHandled;
{
	_handled = isHandled;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%s name=%@ mode=%@ handled=%s %p>", class_getName([self class]), _name, _mode, _handled?"YES":"NO", self];
}

@end

#define AnyListenerKeyForEventName(eventName) [@"LAEventListener-" stringByAppendingString:(eventName)]
#define ListenerKeyForEventNameAndMode(eventName, eventMode) ({ \
	NSString *_eventName = eventName; \
	NSString *_eventMode = eventMode; \
	[_eventMode isEqualToString:LAEventModeAny]?AnyListenerKeyForEventName(_eventName):[NSString stringWithFormat:@"LAEventListener(%@)-%@", (_eventMode), (_eventName)]; \
})

static LAActivator *sharedActivator;

@interface LAActivator ()
- (void)_loadPreferences;
- (void)_savePreferences;
- (void)_reloadPreferences;
- (BOOL)_canUnassignEventName:(NSString *)eventName mode:(NSString *)mode;
@end

static void PreferencesChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
	[[LAActivator sharedInstance] _reloadPreferences];
}

@implementation LAActivator

#define LoadPreferences() do { if (!_preferences) [self _loadPreferences]; } while(0)

+ (LAActivator *)sharedInstance
{
	return sharedActivator;
}

+ (void)load
{
	sharedActivator = [[LAActivator alloc] init];
}

- (id)init
{
	if ((self = [super init])) {
		// Does not retain values!
		_listeners = (NSMutableDictionary *)CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, NULL);
		// Register for notification
		CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), self, PreferencesChangedCallback, CFSTR("libactivator.preferenceschanged"), NULL, CFNotificationSuspensionBehaviorCoalesce);
	}
	return self;
}

- (void)dealloc
{
	CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), self, CFSTR("libactivator.preferencechanged"), NULL);
	[_preferences release];
	[_listeners release];
	[super dealloc];
}

- (void)_reloadPreferences
{
	[_preferences release];
	_preferences = nil;
}

- (void)_loadPreferences
{
	if ((_preferences = [[NSMutableDictionary alloc] initWithContentsOfFile:LAActivatorSettingsFilePath]))
		return;
	if ((_preferences = [[NSMutableDictionary alloc] initWithContentsOfFile:@"/User/Library/Preferences/libactivator.plist"]))
		return;
	_preferences = [[NSMutableDictionary alloc] init];
}

- (void)_savePreferences
{
	if (_preferences) {
		CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)LAActivatorSettingsFilePath, kCFURLPOSIXPathStyle, NO);
		CFWriteStreamRef stream = CFWriteStreamCreateWithFile(kCFAllocatorDefault, url);
		CFRelease(url);
		CFWriteStreamOpen(stream);
		CFPropertyListWriteToStream((CFPropertyListRef)_preferences, stream, kCFPropertyListBinaryFormat_v1_0, NULL);
		CFWriteStreamClose(stream);
		CFRelease(stream);
		chmod([LAActivatorSettingsFilePath UTF8String], S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP | S_IROTH | S_IWOTH);
		notify_post("libactivator.preferenceschanged");
	}
}

- (BOOL)_canUnassignEventName:(NSString *)eventName mode:(NSString *)mode
{
	LoadPreferences();
	NSString *pref = ListenerKeyForEventNameAndMode(eventName, mode);
	NSString *listenerName = [_preferences objectForKey:pref];
	NSDictionary *infoList = [self infoForListenerWithName:listenerName];
	if ([[infoList objectForKey:@"sticky"] boolValue])
		return NO;
	if ([[infoList objectForKey:@"require-event"] boolValue])
		if ([[self eventsAssignedToListenerWithName:listenerName] count] == 0)
			return NO;
	return YES;
}

- (id<LAListener>)listenerForEvent:(LAEvent *)event
{
	return [_listeners objectForKey:[self assignedListenerNameForEvent:event]];
}

- (void)sendEventToListener:(LAEvent *)event
{
	id<LAListener> listener = [self listenerForEvent:event];
	if ([listener respondsToSelector:@selector(activator:receiveEvent:)])
		[listener activator:self receiveEvent:event];
	if ([event isHandled])
		for (id<LAListener> other in [_listeners allValues])
			if (other != listener)
				if ([other respondsToSelector:@selector(activator:otherListenerDidHandleEvent:)])
					[other activator:self otherListenerDidHandleEvent:event];
}

- (void)sendAbortToListener:(LAEvent *)event
{
	id<LAListener> listener = [self listenerForEvent:event];
	if ([listener respondsToSelector:@selector(activator:abortEvent:)])
		[listener activator:self abortEvent:event];
}

- (void)registerListener:(id<LAListener>)listener forName:(NSString *)name
{
	[_listeners setObject:listener forKey:name];
	LoadPreferences();
	NSString *key = [@"LAHasSeenListener-" stringByAppendingString:name];
	if (![[_preferences objectForKey:key] boolValue]) {
		[_preferences setObject:[NSNumber numberWithBool:YES] forKey:key];
		[self _savePreferences];
	}
}

- (void)unregisterListenerWithName:(NSString *)name
{
	[_listeners removeObjectForKey:name];
}

- (BOOL)hasSeenListenerWithName:(NSString *)name
{
	LoadPreferences();
	return [[_preferences objectForKey:[@"LAHasSeenListener-" stringByAppendingString:name]] boolValue];
}

- (BOOL)assignEvent:(LAEvent *)event toListenerWithName:(NSString *)listenerName
{
	LoadPreferences();
	NSString *mode = [event mode];
	NSString *eventName = [event name];
	NSString *prefName = ListenerKeyForEventNameAndMode(eventName, mode);
	if ([mode isEqualToString:LAEventModeAny]) {
		// Abort if unable to unassign event
		NSArray *availableModes = [self availableEventModes];
		for (NSString *em in availableModes)
			if (![self _canUnassignEventName:eventName mode:em])
				return NO;
		// Remove all assignments
		for (NSString *em in availableModes)
			[_preferences removeObjectForKey:ListenerKeyForEventNameAndMode(eventName, em)];
	} else {
		// Abort if unable to unassign event
		if (![self _canUnassignEventName:eventName mode:LAEventModeAny])
			return NO;
		if (![self _canUnassignEventName:eventName mode:mode])
			return NO;
		// Remove "any" assignment
		[_preferences removeObjectForKey:ListenerKeyForEventNameAndMode(eventName, LAEventModeAny)];
	}
	// Add new Mapping
	[_preferences setObject:listenerName forKey:prefName];
	// Save Preferences
	[self _savePreferences];
	return YES;
}

- (void)unassignEvent:(LAEvent *)event
{
	LoadPreferences();
	NSString *prefName = ListenerKeyForEventNameAndMode([event name], [event mode]);
	if ([_preferences objectForKey:prefName]) {
		[_preferences removeObjectForKey:prefName];
		[self _savePreferences];
	}
}

- (NSString *)assignedListenerNameForEvent:(LAEvent *)event
{
	LoadPreferences();
	NSString *eventName = [event name];
	NSString *prefName = ListenerKeyForEventNameAndMode(eventName, [event mode]);
	NSString *result = [_preferences objectForKey:prefName];
	if (result)
		return result;
	prefName = AnyListenerKeyForEventName(eventName);
	return [_preferences objectForKey:prefName];
}

- (NSArray *)eventsAssignedToListenerWithName:(NSString *)listenerName
{
	NSArray *events = [self availableEventNames];
	NSMutableArray *result = [NSMutableArray array];
	LoadPreferences();
	for (NSString *eventMode in [self availableEventModes]) {
		for (NSString *eventName in events) {
			NSString *prefName = ListenerKeyForEventNameAndMode(eventName, eventMode);
			NSString *assignedListener = [_preferences objectForKey:prefName];
			if ([assignedListener isEqualToString:listenerName])
				[result addObject:[LAEvent eventWithName:eventName mode:eventMode]];
		}
	}
	return result;
}

- (NSArray *)availableEventNames
{
	NSMutableArray *result = [NSMutableArray array];
	for (NSString *fileName in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/Library/Activator/Events" error:NULL])
		if (![fileName hasPrefix:@"."])
			[result addObject:fileName];
	return result;
}

- (NSDictionary *)infoForEventWithName:(NSString *)name
{
	return [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"/Library/Activator/Events/%@/Info.plist", name]];
}

- (NSArray *)availableListenerNames
{
	NSMutableArray *result = [NSMutableArray array];
	for (NSString *fileName in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/Library/Activator/Listeners" error:NULL])
		if (![fileName hasPrefix:@"."])
			[result addObject:fileName];
	return result;
}

- (NSDictionary *)infoForListenerWithName:(NSString *)name
{
	return [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"/Library/Activator/Listeners/%@/Info.plist", name]];
}

- (NSArray *)availableEventModes
{
	return [NSArray arrayWithObjects:LAEventModeAny, LAEventModeSpringBoard, LAEventModeApplication, LAEventModeLockScreen, nil];
}

- (NSString *)currentEventMode
{
	if ([(SpringBoard *)[UIApplication sharedApplication] isLocked])
		return LAEventModeLockScreen;
	if ([[CHSharedInstance(SBIconController) contentView] window])
		return LAEventModeSpringBoard;
	return LAEventModeApplication;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%s listeners=%@ %p>", class_getName([self class]), _listeners, self];
}

@end
