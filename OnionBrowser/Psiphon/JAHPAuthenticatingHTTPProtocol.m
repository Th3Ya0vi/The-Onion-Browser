
/*
 File: JAHPAuthenticatingHTTPProtocol.m
 Abstract: An NSURLProtocol subclass that overrides the built-in HTTP/HTTPS protocol.
 Version: 1.1

 Disclaimer: IMPORTANT:  This Apple software is supplied to you by Apple
 Inc. ("Apple") in consideration of your agreement to the following
 terms, and your use, installation, modification or redistribution of
 this Apple software constitutes acceptance of these terms.  If you do
 not agree with these terms, please do not use, install, modify or
 redistribute this Apple software.

 In consideration of your agreement to abide by the following terms, and
 subject to these terms, Apple grants you a personal, non-exclusive
 license, under Apple's copyrights in this original Apple software (the
 "Apple Software"), to use, reproduce, modify and redistribute the Apple
 Software, with or without modifications, in source and/or binary forms;
 provided that if you redistribute the Apple Software in its entirety and
 without modifications, you must retain this notice and the following
 text and disclaimers in all such redistributions of the Apple Software.
 Neither the name, trademarks, service marks or logos of Apple Inc. may
 be used to endorse or promote products derived from the Apple Software
 without specific prior written permission from Apple.  Except as
 expressly stated in this notice, no other rights or licenses, express or
 implied, are granted by Apple herein, including but not limited to any
 patent rights that may be infringed by your derivative works or by other
 works in which the Apple Software may be incorporated.

 The Apple Software is provided by Apple on an "AS IS" basis.  APPLE
 MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
 THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS
 FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND
 OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.

 IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL
 OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
 MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED
 AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE),
 STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE.

 Copyright (C) 2014 Apple Inc. All Rights Reserved.

 */

#import "CookieJar.h"
#import "HSTSCache.h"
#import "HTTPSEverywhere.h"
#import "OCSPAuthURLSessionDelegate.h"

#import "JAHPAuthenticatingHTTPProtocol.h"
#import "JAHPCanonicalRequest.h"
#import "JAHPCacheStoragePolicy.h"
#import "JAHPQNSURLSessionDemux.h"

#import "AppDelegate.h"
#import "HostSettings.h"
#import "URLBlocker.h"
#import "OnionBrowser-Swift.h"

@import CSPHeader;

// I use the following typedef to keep myself sane in the face of the wacky
// Objective-C block syntax.

typedef void (^JAHPChallengeCompletionHandler)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential * credential);

@interface JAHPWeakDelegateHolder : NSObject

@property (nonatomic, weak) id<JAHPAuthenticatingHTTPProtocolDelegate> delegate;

@end

@interface TemporarilyAllowedURL : NSObject

@property (atomic, strong) NSURL *url;
@property (atomic, strong) WebViewTab *wvt;
@property (atomic, assign) BOOL ocspRequest;

- (instancetype)initWithUrl:(NSURL*)url
			  andWebViewTab:(WebViewTab*)wvt
		   andIsOCSPRequest:(BOOL)isOCSPRequest;

@end

@implementation TemporarilyAllowedURL

- (instancetype)initWithUrl:(NSURL*)url
			  andWebViewTab:(WebViewTab*)wvt
		   andIsOCSPRequest:(BOOL)isOCSPRequest {
	self = [super init];

	if (self) {
		self.url = url;
		self.wvt = wvt;
		self.ocspRequest = isOCSPRequest;
	}

	return self;
}

@end

@interface JAHPAuthenticatingHTTPProtocol () <NSURLSessionDataDelegate> {
	NSUInteger _contentType;
	Boolean _isFirstChunk;
	NSString * _cspNonce;
	WebViewTab *_wvt;
	NSString *_userAgent;
	NSURLRequest *_actualRequest;
	BOOL _isOrigin;
	BOOL _isTemporarilyAllowed;
	BOOL _isOCSPRequest;
}

@property (atomic, strong, readwrite) NSThread *                        clientThread;       ///< The thread on which we should call the client.

/*! The run loop modes in which to call the client.
 *  \details The concurrency control here is complex.  It's set up on the client
 *  thread in -startLoading and then never modified.  It is, however, read by code
 *  running on other threads (specifically the main thread), so we deallocate it in
 *  -dealloc rather than in -stopLoading.  We can be sure that it's not read before
 *  it's set up because the main thread code that reads it can only be called after
 *  -startLoading has started the connection running.
 */

@property (atomic, copy,   readwrite) NSArray *                         modes;
@property (atomic, assign, readwrite) NSTimeInterval                    startTime;          ///< The start time of the request; written by client thread only; read by any thread.
@property (atomic, strong, readwrite) NSURLSessionTask *                task;               ///< The NSURLSession task for that request; client thread only.
@property (atomic, strong, readwrite) NSURLAuthenticationChallenge *    pendingChallenge;
@property (atomic, copy,   readwrite) JAHPChallengeCompletionHandler        pendingChallengeCompletionHandler;  ///< The completion handler that matches pendingChallenge; main thread only.
@property (atomic, copy,   readwrite) JAHPDidCancelAuthenticationChallengeHandler pendingDidCancelAuthenticationChallengeHandler;  ///< The handler that runs when we cancel the pendingChallenge; main thread only.

@end

@implementation JAHPAuthenticatingHTTPProtocol

#pragma mark * Subclass specific additions

/*! The backing store for the class delegate.  This is protected by @synchronized on the class.
 */

static JAHPWeakDelegateHolder* weakDelegateHolder;

static NSMutableArray<TemporarilyAllowedURL*> *tmpAllowed;
static NSCache *injectCache;
static NSString *_javascriptToInject;

#define INJECT_CACHE_SIZE 20

+ (NSString *)javascriptToInject
{
	if (!_javascriptToInject) {
		NSString *path = [[NSBundle mainBundle] pathForResource:@"injected" ofType:@"js"];
		_javascriptToInject = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
	}

	return _javascriptToInject;
}

+ (void)clearInjectCache
{
	[injectCache removeAllObjects];
}

+ (NSString *)javascriptToInjectForURL:(NSURL *)url
{
	if (injectCache == nil)
	{
		injectCache = [[NSCache alloc] init];
		injectCache.countLimit = INJECT_CACHE_SIZE;
	}

	NSString *js = [injectCache objectForKey:url.host];
	if (js != nil)
	{
		return js;
	}

	HostSettings *hs = [HostSettings settingsOrDefaultsForHost:url.host];

	NSString *block = [hs boolSettingOrDefault:HOST_SETTINGS_KEY_ALLOW_WEBRTC] ? @"false" : @"true";

	js = [[self javascriptToInject]
		  stringByReplacingOccurrencesOfString:@"\"##BLOCK_WEBRTC##\""
		  withString:block];

	[injectCache setObject:js forKey:url.host];

	return js;
}

+ (void)temporarilyAllowURL:(NSURL *)url
			  forWebViewTab:(WebViewTab*)webViewTab {

	return [self temporarilyAllowURL:url forWebViewTab:webViewTab isOCSPRequest:NO];
}

+ (void)temporarilyAllowURL:(NSURL *)url
			  forWebViewTab:(WebViewTab*)webViewTab
			  isOCSPRequest:(BOOL)isOCSPRequest
{
	@synchronized (tmpAllowed) {
		if (tmpAllowed == NULL) {
			tmpAllowed = [[NSMutableArray alloc] initWithCapacity:1];
		}

		TemporarilyAllowedURL *allowedURL = [[TemporarilyAllowedURL alloc] initWithUrl:url
																		 andWebViewTab:webViewTab
																	  andIsOCSPRequest:isOCSPRequest];
		[tmpAllowed addObject:allowedURL];
	}
}

+ (TemporarilyAllowedURL*)popTemporarilyAllowedURL:(NSURL *)url
{
	TemporarilyAllowedURL *ret = NULL;

	@synchronized (tmpAllowed) {
		int found = -1;

		for (int i = 0; i < [tmpAllowed count]; i++) {
			if ([[tmpAllowed[i].url absoluteString] isEqualToString:[url absoluteString]]) {
				found = i;
				ret = tmpAllowed[i];
			}
		}

		if (found > -1) {
			[tmpAllowed removeObjectAtIndex:found];
		}
	}

	return ret;
}

+ (void)start
{
	[NSURLProtocol registerClass:self];
	
	[NSNotificationCenter.defaultCenter
	 addObserver:self selector:@selector(clearInjectCache)
	 name:HOST_SETTINGS_CHANGED object:nil];
}

+ (void)stop {
	[NSURLProtocol unregisterClass:self];

	[NSNotificationCenter.defaultCenter removeObserver:self];
}

+ (id<JAHPAuthenticatingHTTPProtocolDelegate>)delegate
{
	id<JAHPAuthenticatingHTTPProtocolDelegate> result;

	@synchronized (self) {
		if (!weakDelegateHolder) {
			weakDelegateHolder = [JAHPWeakDelegateHolder new];
		}
		result = weakDelegateHolder.delegate;
	}
	return result;
}

+ (void)setDelegate:(id<JAHPAuthenticatingHTTPProtocolDelegate>)newValue
{
	@synchronized (self) {
		if (!weakDelegateHolder) {
			weakDelegateHolder = [JAHPWeakDelegateHolder new];
		}
		weakDelegateHolder.delegate = newValue;
	}
}

/*! Returns the session demux object used by all the protocol instances.
 *  \details This object allows us to have a single NSURLSession, with a session delegate,
 *  and have its delegate callbacks routed to the correct protocol instance on the correct
 *  thread in the correct modes.  Can be called on any thread.
 */

static JAHPQNSURLSessionDemux *sharedDemuxInstance = nil;

+ (JAHPQNSURLSessionDemux *)sharedDemux
{
	@synchronized(self) {
		if (sharedDemuxInstance == nil) {
			NSURLSessionConfiguration *config = [JAHPAuthenticatingHTTPProtocol
												 proxiedSessionConfiguration];

			sharedDemuxInstance = [[JAHPQNSURLSessionDemux alloc] initWithConfiguration:config];
		}
	}
	return sharedDemuxInstance;
}

+ (void)resetSharedDemux
{
	@synchronized(self) {
		sharedDemuxInstance = nil;
	}
}

#pragma mark - Proxied session configuration

+ (NSURLSessionConfiguration*)proxiedSessionConfiguration {

	NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];

	// You have to explicitly configure the session to use your own protocol subclass here
	// otherwise you don't see redirects <rdar://problem/17384498>.
	if (config.protocolClasses) {
		config.protocolClasses = [config.protocolClasses arrayByAddingObject:self];
	} else {
		config.protocolClasses = @[ self ];
	}

	// Set TLSMinimumSupportedProtocol from user settings.
	// NOTE: TLSMaximumSupportedProtocol is always set to the max supported by the system
	// by default so there is no need to set it.
	config.TLSMinimumSupportedProtocol = Settings.minimumSupportedProtocol;

	// Set proxy
	NSString* proxyHost = @"localhost";
	NSInteger socksProxyPort = AppDelegate.sharedAppDelegate.socksProxyPort;
	NSInteger httpProxyPort = AppDelegate.sharedAppDelegate.httpProxyPort;
	NSMutableDictionary *proxyDict = [@{} mutableCopy];

	if (socksProxyPort > 0) {
		proxyDict[@"SOCKSEnable"] = @YES;
		proxyDict[(NSString *)kCFStreamPropertySOCKSProxyHost] = proxyHost;
		proxyDict[(NSString *)kCFStreamPropertySOCKSProxyPort] = [NSNumber numberWithInteger: socksProxyPort];
	}

	if (httpProxyPort > 0) {
SILENCE_DEPRECATION_ON
		proxyDict[@"HTTPEnable"] = @YES;
		proxyDict[(NSString *)kCFStreamPropertyHTTPProxyHost] = proxyHost;
		proxyDict[(NSString *)kCFStreamPropertyHTTPProxyPort] = [NSNumber numberWithInteger: httpProxyPort];

		proxyDict[@"HTTPSEnable"] = @YES;
		proxyDict[(NSString *)kCFStreamPropertyHTTPSProxyHost] = proxyHost;
		proxyDict[(NSString *)kCFStreamPropertyHTTPSProxyPort] = [NSNumber numberWithInteger: httpProxyPort];
SILENCE_WARNINGS_OFF
	}

	config.connectionProxyDictionary = proxyDict;

	return config;
}

/*! Called by by both class code and instance code to log various bits of information.
 *  Can be called on any thread.
 *  \param protocol The protocol instance; nil if it's the class doing the logging.
 *  \param format A standard NSString-style format string; will not be nil.
 */

+ (void)authenticatingHTTPProtocol:(JAHPAuthenticatingHTTPProtocol *)protocol logWithFormat:(NSString *)format, ... NS_FORMAT_FUNCTION(2, 3)
// All internal logging calls this routine, which routes the log message to the
// delegate.
{
	// protocol may be nil
	id<JAHPAuthenticatingHTTPProtocolDelegate> strongDelegate;

	strongDelegate = [self delegate];
	if ([strongDelegate respondsToSelector:@selector(authenticatingHTTPProtocol:logWithFormat:arguments:)]) {
		va_list arguments;

		va_start(arguments, format);
		[strongDelegate authenticatingHTTPProtocol:protocol logWithFormat:format arguments:arguments];
		va_end(arguments);
	}
	if ([strongDelegate respondsToSelector:@selector(authenticatingHTTPProtocol:logMessage:)]) {
		va_list arguments;

		va_start(arguments, format);
		NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
		va_end(arguments);
		[strongDelegate authenticatingHTTPProtocol:protocol logMessage:message];
	}
}

#pragma mark * NSURLProtocol overrides

/*! Used to mark our recursive requests so that we don't try to handle them (and thereby
 *  suffer an infinite recursive death).
 */

static NSString * kJAHPRecursiveRequestFlagProperty = @"com.jivesoftware.JAHPAuthenticatingHTTPProtocol";

+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
	BOOL        shouldAccept;
	NSURL *     url;
	NSString *  scheme;

	// Check the basics.  This routine is extremely defensive because experience has shown that
	// it can be called with some very odd requests <rdar://problem/15197355>.

	shouldAccept = (request != nil);
	if (shouldAccept) {
		url = [request URL];
		shouldAccept = (url != nil);
	}
	if ( ! shouldAccept ) {
		[self authenticatingHTTPProtocol:nil logWithFormat:@"decline request (malformed)"];
	}

	// Decline our recursive requests.

	if (shouldAccept) {
		shouldAccept = ([self propertyForKey:kJAHPRecursiveRequestFlagProperty inRequest:request] == nil);
		if ( ! shouldAccept ) {
			[self authenticatingHTTPProtocol:nil logWithFormat:@"decline request %@ (recursive)", url];
		}
	}

	// Get the scheme.

	if (shouldAccept) {
		scheme = [[url scheme] lowercaseString];
		shouldAccept = (scheme != nil);

		if ( ! shouldAccept ) {
			[self authenticatingHTTPProtocol:nil logWithFormat:@"decline request %@ (no scheme)", url];
		}
	}

	// Do not try and handle requests to localhost

	if (shouldAccept) {
		shouldAccept = (![[url host] isEqualToString:@"127.0.0.1"]);
	}

	// Look for "http" or "https".
	//
	// Flip either or both of the following to YESes to control which schemes go through this custom
	// NSURLProtocol subclass.

	if (shouldAccept) {
		shouldAccept = YES && [scheme isEqual:@"http"];
		if ( ! shouldAccept ) {
			shouldAccept = YES && [scheme isEqual:@"https"];
		}

		if ( ! shouldAccept ) {
			[self authenticatingHTTPProtocol:nil logWithFormat:@"decline request %@ (scheme mismatch)", url];
		} else {
			[self authenticatingHTTPProtocol:nil logWithFormat:@"accept request %@", url];
		}
	}

	return shouldAccept;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
	NSURLRequest *      result;

	assert(request != nil);
	// can be called on any thread

	// Canonicalising a request is quite complex, so all the heavy lifting has
	// been shuffled off to a separate module.

	result = JAHPCanonicalRequestForRequest(request);

	[self authenticatingHTTPProtocol:nil logWithFormat:@"canonicalized %@ to %@", [request URL], [result URL]];

	return result;
}

- (id)initWithRequest:(NSURLRequest *)request cachedResponse:(NSCachedURLResponse *)cachedResponse client:(id <NSURLProtocolClient>)client
{
	assert(request != nil);
	// cachedResponse may be nil
	assert(client != nil);
	// can be called on any thread

	_wvt = nil;

	/* extract tab hash from per-uiwebview user agent */
	NSString *ua = [request valueForHTTPHeaderField:@"User-Agent"];
	NSArray *uap = [ua componentsSeparatedByString:@"/"];
	NSString *wvthash = uap[uap.count - 1];

	/* store it for later without the hash */
	_userAgent = [[uap subarrayWithRange:NSMakeRange(0, uap.count - 1)] componentsJoinedByString:@"/"];

	if ([NSURLProtocol propertyForKey:WVT_KEY inRequest:request])
		wvthash = [NSString stringWithFormat:@"%lu", [(NSNumber *)[NSURLProtocol propertyForKey:WVT_KEY inRequest:request] longValue]];

	if (wvthash != nil && ![wvthash isEqualToString:@""]) {
		for (WebViewTab *wvt in [[[AppDelegate sharedAppDelegate] webViewController] webViewTabs]) {
			if ([[NSString stringWithFormat:@"%lu", (unsigned long)[wvt hash]] isEqualToString:wvthash]) {
				_wvt = wvt;
				break;
			}
		}
	}

	if (_wvt == nil) {
		TemporarilyAllowedURL *allowedUrl = [[self class] popTemporarilyAllowedURL:[request URL]];
		if (allowedUrl != nil) {
			_isTemporarilyAllowed = YES;
			_wvt = allowedUrl.wvt;
			_isOCSPRequest = allowedUrl.ocspRequest;
		}
	}

	if (_wvt == nil) {

		[[self class] authenticatingHTTPProtocol:self logWithFormat:@"request for %@ with no matching WebViewTab! (main URL %@, UA hash %@)", [request URL], [request mainDocumentURL], wvthash];
		[client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:@{ ORIGIN_KEY: @YES }]];

		if (![[[[request URL] scheme] lowercaseString] isEqualToString:@"http"] && ![[[[request URL] scheme] lowercaseString] isEqualToString:@"https"]) {
			if ([[UIApplication sharedApplication] canOpenURL:[request URL]]) {
				UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Open In External App" message:[NSString stringWithFormat:@"Allow URL to be opened by external app? This may compromise your privacy.\n\n%@", [request URL]] preferredStyle:UIAlertControllerStyleAlert];

				UIAlertAction *okAction = [UIAlertAction actionWithTitle:NSLocalizedStringWithDefaultValue(@"OK_ACTION", nil, [NSBundle mainBundle], @"OK", @"OK action") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
					[[self class] authenticatingHTTPProtocol:self logWithFormat:@"opening in 3rd party app: %@", [request URL]];
					[UIApplication.sharedApplication openURL:[request URL] options:@{} completionHandler:nil];
				}];

				UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedStringWithDefaultValue(@"CANCEL_ACTION", nil, [NSBundle mainBundle], @"Cancel", @"Cancel action") style:UIAlertActionStyleCancel handler:nil];
				[alertController addAction:cancelAction];
				[alertController addAction:okAction];

				[[[AppDelegate sharedAppDelegate] webViewController] presentViewController:alertController animated:YES completion:nil];
			}
		}

		return nil;
	}

	// Check, if URL needs to be blocked.
	NSString *blocker = [URLBlocker blockingTargetForURL:[request URL] fromMainDocumentURL:[request mainDocumentURL]];
	if (blocker) {
		[[_wvt applicableURLBlockerTargets] setObject:@YES forKey:blocker];
		return nil;
	}


	[[self class] authenticatingHTTPProtocol:self logWithFormat:@"[Tab %@] initializing %@ to %@ (via %@)", _wvt.tabIndex, [request HTTPMethod], [[request URL] absoluteString], [request mainDocumentURL]];

	NSMutableURLRequest *mutableRequest = [request mutableCopy];

	NSString *host = mutableRequest.mainDocumentURL.host;
	if (host.length == 0) {
		host = mutableRequest.URL.host;
	}

	NSString *userAgent = [[HostSettings settingsOrDefaultsForHost:host] settingOrDefault:HOST_SETTINGS_KEY_USER_AGENT];
	if (userAgent.length == 0) {
		userAgent = _userAgent;
	}

	[mutableRequest setValue:userAgent forHTTPHeaderField:@"User-Agent"];
	[mutableRequest setHTTPShouldUsePipelining:YES];

	if ([NSURLProtocol propertyForKey:ORIGIN_KEY inRequest:mutableRequest]) {
		_isOrigin = YES;
	} else if ([[mutableRequest URL] isEqual:[mutableRequest mainDocumentURL]]) {
		_isOrigin = YES;
	} else {
		_isOrigin = NO;
	}

	/* check HSTS cache first to see if scheme needs upgrading */
	[mutableRequest setURL:[[[AppDelegate sharedAppDelegate] hstsCache] rewrittenURI:[request URL]]];

	/* then check HTTPS Everywhere (must pass all URLs since some rules are not just scheme changes */
	NSArray *HTErules = [HTTPSEverywhere potentiallyApplicableRulesForHost:[[request URL] host]];
	if (HTErules != nil && [HTErules count] > 0) {
		[mutableRequest setURL:[HTTPSEverywhere rewrittenURI:[request URL] withRules:HTErules]];

		for (HTTPSEverywhereRule *HTErule in HTErules) {
			[[_wvt applicableHTTPSEverywhereRules] setObject:@YES forKey:[HTErule name]];
		}
	}

	/* in case our URL changed/upgraded, send back to the webview so it knows what our protocol is for "//" assets */
	if (_isOrigin && ![[[mutableRequest URL] absoluteString] isEqualToString:[[request URL] absoluteString]]) {
		[[self class] authenticatingHTTPProtocol:self logWithFormat:@"[Tab %@] canceling origin request to redirect %@ rewritten to %@", _wvt.tabIndex, [[self.request URL] absoluteString], [[mutableRequest URL] absoluteString]];
		[_wvt setUrl:[mutableRequest URL]];
		[_wvt loadURL:[mutableRequest URL]];
		return nil;
	}

	// Blocking mixed-content requests if set.
	if (!_isOrigin
		&& _wvt.secureMode > WebViewTabSecureModeInsecure
		&& ![mutableRequest.URL.scheme.lowercaseString isEqualToString:@"https"]
		&& ![[HostSettings settingsOrDefaultsForHost:host] boolSettingOrDefault:HOST_SETTINGS_KEY_ALLOW_MIXED_MODE])
	{
		[_wvt setSecureMode:WebViewTabSecureModeMixed];
		return nil;
	}

	/* we're handling cookies ourself */
	mutableRequest.HTTPShouldHandleCookies = NO;
	NSArray *cookies = [AppDelegate.sharedAppDelegate.cookieJar cookiesForURL:mutableRequest.URL forTab:_wvt.hash];

	if (cookies != nil && cookies.count > 0) {
		[self.class authenticatingHTTPProtocol:self logWithFormat:@"[Tab %@] sending %lu cookie(s) to %@", _wvt.tabIndex, (unsigned long)cookies.count, mutableRequest.URL];
		NSDictionary *headers = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies];
		mutableRequest.allHTTPHeaderFields = headers;
	}

	/* add "do not track" header if it's enabled in the settings */
	if (Settings.sendDnt)
	{
		[mutableRequest setValue:@"1" forHTTPHeaderField:@"DNT"];
	}

	self = [super initWithRequest:mutableRequest cachedResponse:cachedResponse client:client];
	return self;
}

- (void)dealloc
{
	// can be called on any thread
	[[self class] authenticatingHTTPProtocol:self logWithFormat:@"dealloc"];
	assert(self->_task == nil);                     // we should have cleared it by now
	assert(self->_pendingChallenge == nil);         // we should have cancelled it by now
	assert(self->_pendingChallengeCompletionHandler == nil);    // we should have cancelled it by now
}

- (void)startLoading
{
	NSMutableURLRequest *   recursiveRequest;
	NSMutableArray *        calculatedModes;
	NSString *              currentMode;

	// At this point we kick off the process of loading the URL via NSURLSession.
	// The thread that calls this method becomes the client thread.

	assert(self.clientThread == nil);           // you can't call -startLoading twice
	assert(self.task == nil);

	// Calculate our effective run loop modes.  In some circumstances (yes I'm looking at
	// you UIWebView!) we can be called from a non-standard thread which then runs a
	// non-standard run loop mode waiting for the request to finish.  We detect this
	// non-standard mode and add it to the list of run loop modes we use when scheduling
	// our callbacks.  Exciting huh?
	//
	// For debugging purposes the non-standard mode is "WebCoreSynchronousLoaderRunLoopMode"
	// but it's better not to hard-code that here.

	assert(self.modes == nil);
	calculatedModes = [NSMutableArray array];
	[calculatedModes addObject:NSDefaultRunLoopMode];
	currentMode = [[NSRunLoop currentRunLoop] currentMode];
	if ( (currentMode != nil) && ! [currentMode isEqual:NSDefaultRunLoopMode] ) {
		[calculatedModes addObject:currentMode];
	}
	self.modes = calculatedModes;
	assert([self.modes count] > 0);

	// Create new request that's a clone of the request we were initialised with,
	// except that it has our 'recursive request flag' property set on it.

	recursiveRequest = [[self request] mutableCopy];
	assert(recursiveRequest != nil);
	_actualRequest = recursiveRequest;

	///set *recursive* flag
	[[self class] setProperty:@YES forKey:kJAHPRecursiveRequestFlagProperty inRequest:recursiveRequest];

	self.startTime = [NSDate timeIntervalSinceReferenceDate];
	if (currentMode == nil) {
		[[self class] authenticatingHTTPProtocol:self logWithFormat:@"start %@", [recursiveRequest URL]];
	} else {
		[[self class] authenticatingHTTPProtocol:self logWithFormat:@"start %@ (mode %@)", [recursiveRequest URL], currentMode];
	}

	// Latch the thread we were called on, primarily for debugging purposes.
	self.clientThread = [NSThread currentThread];

	// Once everything is ready to go, create a data task with the new request.
	self.task = [[[self class] sharedDemux] dataTaskWithRequest:recursiveRequest delegate:self modes:self.modes];
	assert(self.task != nil);

	[self.task resume];
}

- (void)stopLoading
{
	// The implementation just cancels the current load (if it's still running).

	[[self class] authenticatingHTTPProtocol:self logWithFormat:@"stop (elapsed %.1f)", [NSDate timeIntervalSinceReferenceDate] - self.startTime];

	assert(self.clientThread != nil);           // someone must have called -startLoading

	// Check that we're being stopped on the same thread that we were started
	// on.  Without this invariant things are going to go badly (for example,
	// run loop sources that got attached during -startLoading may not get
	// detached here).
	//
	// I originally had code here to bounce over to the client thread but that
	// actually gets complex when you consider run loop modes, so I've nixed it.
	// Rather, I rely on our client calling us on the right thread, which is what
	// the following assert is about.

	assert([NSThread currentThread] == self.clientThread);

	[self cancelPendingChallenge];
	if (self.task != nil) {
		[self.task cancel];
		self.task = nil;
		// The following ends up calling -URLSession:task:didCompleteWithError: with NSURLErrorDomain / NSURLErrorCancelled,
		// which specificallys traps and ignores the error.
	}
	// Don't nil out self.modes; see property declaration comments for a a discussion of this.
}

#pragma mark * Authentication challenge handling

/*! Performs the block on the specified thread in one of specified modes.
 *  \param thread The thread to target; nil implies the main thread.
 *  \param modes The modes to target; nil or an empty array gets you the default run loop mode.
 *  \param block The block to run.
 */

- (void)performOnThread:(NSThread *)thread modes:(NSArray *)modes block:(dispatch_block_t)block
{
	// thread may be nil
	// modes may be nil
	assert(block != nil);

	if (thread == nil) {
		thread = [NSThread mainThread];
	}
	if ([modes count] == 0) {
		modes = @[ NSDefaultRunLoopMode ];
	}
	[self performSelector:@selector(onThreadPerformBlock:) onThread:thread withObject:[block copy] waitUntilDone:NO modes:modes];
}

/*! A helper method used by -performOnThread:modes:block:. Runs in the specified context
 *  and simply calls the block.
 *  \param block The block to run.
 */

- (void)onThreadPerformBlock:(dispatch_block_t)block
{
	assert(block != nil);
	block();
}

/*! Called by our NSURLSession delegate callback to pass the challenge to our delegate.
 *  \description This simply passes the challenge over to the main thread.
 *  We do this so that all accesses to pendingChallenge are done from the main thread,
 *  which avoids the need for extra synchronisation.
 *
 *  By the time this runes, the NSURLSession delegate callback has already confirmed with
 *  the delegate that it wants the challenge.
 *
 *  Note that we use the default run loop mode here, not the common modes.  We don't want
 *  an authorisation dialog showing up on top of an active menu (-:
 *
 *  Also, we implement our own 'perform block' infrastructure because Cocoa doesn't have
 *  one <rdar://problem/17232344> and CFRunLoopPerformBlock is inadequate for the
 *  return case (where we need to pass in an array of modes; CFRunLoopPerformBlock only takes
 *  one mode).
 *  \param challenge The authentication challenge to process; must not be nil.
 *  \param completionHandler The associated completion handler; must not be nil.
 */

- (void)didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(JAHPChallengeCompletionHandler)completionHandler
{
	assert(challenge != nil);
	assert(completionHandler != nil);
	assert([NSThread currentThread] == self.clientThread);

	[[self class] authenticatingHTTPProtocol:self logWithFormat:@"challenge %@ received", [[challenge protectionSpace] authenticationMethod]];

	[self performOnThread:nil modes:nil block:^{
		[self mainThreadDidReceiveAuthenticationChallenge:challenge completionHandler:completionHandler];
	}];
}

/*! The main thread side of authentication challenge processing.
 *  \details If there's already a pending challenge, something has gone wrong and
 *  the routine simply cancels the new challenge.  If our delegate doesn't implement
 *  the -authenticatingHTTPProtocol:canAuthenticateAgainstProtectionSpace: delegate callback,
 *  we also cancel the challenge.  OTOH, if all goes well we simply call our delegate
 *  with the challenge.
 *  \param challenge The authentication challenge to process; must not be nil.
 *  \param completionHandler The associated completion handler; must not be nil.
 */

- (void)mainThreadDidReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(JAHPChallengeCompletionHandler)completionHandler
{
	assert(challenge != nil);
	assert(completionHandler != nil);
	assert([NSThread isMainThread]);

	if (self.pendingChallenge != nil) {

		// Our delegate is not expecting a second authentication challenge before resolving the
		// first.  Likewise, NSURLSession shouldn't send us a second authentication challenge
		// before we resolve the first.  If this happens, assert, log, and cancel the challenge.
		//
		// Note that we have to cancel the challenge on the thread on which we received it,
		// namely, the client thread.

		[[self class] authenticatingHTTPProtocol:self logWithFormat:@"challenge %@ cancelled; other challenge pending", [[challenge protectionSpace] authenticationMethod]];
		assert(NO);
		[self clientThreadCancelAuthenticationChallenge:challenge completionHandler:completionHandler];
	} else {
		id<JAHPAuthenticatingHTTPProtocolDelegate>  strongDelegate;

		strongDelegate = [[self class] delegate];

		// Tell the delegate about it.  It would be weird if the delegate didn't support this
		// selector (it did return YES from -authenticatingHTTPProtocol:canAuthenticateAgainstProtectionSpace:
		// after all), but if it doesn't then we just cancel the challenge ourselves (or the client
		// thread, of course).

		if ( ! [strongDelegate respondsToSelector:@selector(authenticatingHTTPProtocol:canAuthenticateAgainstProtectionSpace:)] ) {
			[[self class] authenticatingHTTPProtocol:self logWithFormat:@"challenge %@ cancelled; no delegate method", [[challenge protectionSpace] authenticationMethod]];
			assert(NO);
			[self clientThreadCancelAuthenticationChallenge:challenge completionHandler:completionHandler];
		} else {

			// Remember that this challenge is in progress.

			self.pendingChallenge = challenge;
			self.pendingChallengeCompletionHandler = completionHandler;

			// Pass the challenge to the delegate.

			[[self class] authenticatingHTTPProtocol:self logWithFormat:@"challenge %@ passed to delegate", [[challenge protectionSpace] authenticationMethod]];
			self.pendingDidCancelAuthenticationChallengeHandler = [strongDelegate authenticatingHTTPProtocol:self didReceiveAuthenticationChallenge:self.pendingChallenge];
		}
	}
}

/*! Cancels an authentication challenge that hasn't made it to the pending challenge state.
 *  \details This routine is called as part of various error cases in the challenge handling
 *  code.  It cancels a challenge that, for some reason, we've failed to pass to our delegate.
 *
 *  The routine is always called on the main thread but bounces over to the client thread to
 *  do the actual cancellation.
 *  \param challenge The authentication challenge to cancel; must not be nil.
 *  \param completionHandler The associated completion handler; must not be nil.
 */

- (void)clientThreadCancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(JAHPChallengeCompletionHandler)completionHandler
{
#pragma unused(challenge)
	assert(challenge != nil);
	assert(completionHandler != nil);
	assert([NSThread isMainThread]);

	[self performOnThread:self.clientThread modes:self.modes block:^{
		completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
	}];
}

/*! Cancels an authentication challenge that /has/ made to the pending challenge state.
 *  \details This routine is called by -stopLoading to cancel any challenge that might be
 *  pending when the load is cancelled.  It's always called on the client thread but
 *  immediately bounces over to the main thread (because .pendingChallenge is a main
 *  thread only value).
 */

- (void)cancelPendingChallenge
{
	assert([NSThread currentThread] == self.clientThread);

	// Just pass the work off to the main thread.  We do this so that all accesses
	// to pendingChallenge are done from the main thread, which avoids the need for
	// extra synchronisation.

	[self performOnThread:nil modes:nil block:^{
		if (self.pendingChallenge == nil) {
			// This is not only not unusual, it's actually very typical.  It happens every time you shut down
			// the connection.  Ideally I'd like to not even call -mainThreadCancelPendingChallenge when
			// there's no challenge outstanding, but the synchronisation issues are tricky.  Rather than solve
			// those, I'm just not going to log in this case.
			//
			// [[self class] authenticatingHTTPProtocol:self logWithFormat:@"challenge not cancelled; no challenge pending"];
		} else {
			id<JAHPAuthenticatingHTTPProtocolDelegate>  strongDelegate;
			NSURLAuthenticationChallenge *  challenge;
			JAHPDidCancelAuthenticationChallengeHandler  didCancelAuthenticationChallengeHandler;

			strongDelegate = [[self class] delegate];

			challenge = self.pendingChallenge;
			didCancelAuthenticationChallengeHandler = self.pendingDidCancelAuthenticationChallengeHandler;
			self.pendingChallenge = nil;
			self.pendingChallengeCompletionHandler = nil;
			self.pendingDidCancelAuthenticationChallengeHandler = nil;

			if ([strongDelegate respondsToSelector:@selector(authenticatingHTTPProtocol:didCancelAuthenticationChallenge:)]) {
				[[self class] authenticatingHTTPProtocol:self logWithFormat:@"challenge %@ cancellation passed to delegate", [[challenge protectionSpace] authenticationMethod]];
				if (didCancelAuthenticationChallengeHandler) {
					didCancelAuthenticationChallengeHandler(self, challenge);
				}
				[strongDelegate authenticatingHTTPProtocol:self didCancelAuthenticationChallenge:challenge];
			} else if (didCancelAuthenticationChallengeHandler) {
				didCancelAuthenticationChallengeHandler(self, challenge);
			} else {
				[[self class] authenticatingHTTPProtocol:self logWithFormat:@"challenge %@ cancellation failed; no delegate method", [[challenge protectionSpace] authenticationMethod]];
				// If we managed to send a challenge to the client but can't cancel it, that's bad.
				// There's nothing we can do at this point except log the problem.
				assert(NO);
			}
		}
	}];
}

- (void)resolvePendingAuthenticationChallengeWithCredential:(NSURLCredential *)credential
{
	// credential may be nil
	assert([NSThread isMainThread]);
	assert(self.clientThread != nil);

	JAHPChallengeCompletionHandler  completionHandler;
	NSURLAuthenticationChallenge *challenge;

	// We clear out our record of the pending challenge and then pass the real work
	// over to the client thread (which ensures that the challenge is resolved on
	// the same thread we received it on).

	completionHandler = self.pendingChallengeCompletionHandler;
	challenge = self.pendingChallenge;
	self.pendingChallenge = nil;
	self.pendingChallengeCompletionHandler = nil;
	self.pendingDidCancelAuthenticationChallengeHandler = nil;

	[self performOnThread:self.clientThread modes:self.modes block:^{
		if (credential == nil) {
			[[self class] authenticatingHTTPProtocol:self logWithFormat:@"challenge %@ resolved without credential", [[challenge protectionSpace] authenticationMethod]];
			completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
		} else {
			[[self class] authenticatingHTTPProtocol:self logWithFormat:@"challenge %@ resolved with <%@ %p>", [[challenge protectionSpace] authenticationMethod], [credential class], credential];
			completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
		}
	}];
}

- (void)cancelPendingAuthenticationChallenge {
	assert([NSThread isMainThread]);
	assert(self.clientThread != nil);

	JAHPChallengeCompletionHandler  completionHandler;
	NSURLAuthenticationChallenge *challenge;

	// We clear out our record of the pending challenge and then pass the real work
	// over to the client thread (which ensures that the challenge is resolved on
	// the same thread we received it on).

	completionHandler = self.pendingChallengeCompletionHandler;
	challenge = self.pendingChallenge;
	self.pendingChallenge = nil;
	self.pendingChallengeCompletionHandler = nil;
	self.pendingDidCancelAuthenticationChallengeHandler = nil;

	[self performOnThread:self.clientThread modes:self.modes block:^{
		[[self class] authenticatingHTTPProtocol:self logWithFormat:@"challenge %@ was canceled", [[challenge protectionSpace] authenticationMethod]];

		completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
	}];
}


#pragma mark * NSURLSession delegate callbacks

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)newRequest completionHandler:(void (^)(NSURLRequest *))completionHandler
{
	// rdar://21484589
	// this is called from JAHPQNSURLSessionDemuxTaskInfo,
	// which is called from the NSURLSession delegateQueue,
	// which is a different thread than self.clientThread.
	// It is possible that -stopLoading was called on self.clientThread
	// just before this method if so, ignore this callback
	if (!self.task) { return; }

	NSMutableURLRequest *    redirectRequest;

#pragma unused(session)
#pragma unused(task)
	assert(task == self.task);
	assert(response != nil);
	assert(newRequest != nil);
#pragma unused(completionHandler)
	assert(completionHandler != nil);
	assert([NSThread currentThread] == self.clientThread);

	[[self class] authenticatingHTTPProtocol:self logWithFormat:@"will redirect from %@ to %@", [response URL], [newRequest URL]];

	// The new request was copied from our old request, so it has our magic property.  We actually
	// have to remove that so that, when the client starts the new request, we see it.  If we
	// don't do this then we never see the new request and thus don't get a chance to change
	// its caching behaviour.
	//
	// We also cancel our current connection because the client is going to start a new request for
	// us anyway.

	assert([[self class] propertyForKey:kJAHPRecursiveRequestFlagProperty inRequest:newRequest] != nil);

	/* save any cookies we just received */
	[AppDelegate.sharedAppDelegate.cookieJar
	 setCookies:[NSHTTPCookie cookiesWithResponseHeaderFields:response.allHeaderFields forURL:_actualRequest.URL]
	 forURL:_actualRequest.URL
	 mainDocumentURL:_actualRequest.mainDocumentURL
	 forTab:_wvt.hash];

	redirectRequest = [newRequest mutableCopy];

	/* set up properties of the original request */
	[redirectRequest setMainDocumentURL:[_actualRequest mainDocumentURL]];
	[NSURLProtocol setProperty:[NSNumber numberWithLong:_wvt.hash] forKey:WVT_KEY inRequest:redirectRequest];

	/* if we're being redirected from secure back to insecure, we might be stuck in a loop from an HTTPSEverywhere rule */
	if ([[[_actualRequest URL] scheme] isEqualToString:@"https"] && [[[redirectRequest URL] scheme] isEqualToString:@"http"])
	{
		[HTTPSEverywhere noteInsecureRedirectionForURL:_actualRequest.URL toURL:redirectRequest.URL];
	}

	[[self class] removePropertyForKey:kJAHPRecursiveRequestFlagProperty inRequest:redirectRequest];

	// Tell the client about the redirect.

	[[self client] URLProtocol:self wasRedirectedToRequest:redirectRequest redirectResponse:response];

	// Stop our load.  The CFNetwork infrastructure will create a new NSURLProtocol instance to run
	// the load of the redirect.

	// The following ends up calling -URLSession:task:didCompleteWithError: with NSURLErrorDomain / NSURLErrorCancelled,
	// which specificallys traps and ignores the error.

	[self.task cancel];

	[[self client] URLProtocol:self didFailWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:@{ ORIGIN_KEY: (_isOrigin ? @YES : @NO )}]];
}

-  (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
  completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler
{
	// rdar://21484589
	// this is called from JAHPQNSURLSessionDemuxTaskInfo,
	// which is called from the NSURLSession delegateQueue,
	// which is a different thread than self.clientThread.
	// It is possible that -stopLoading was called on self.clientThread
	// just before this method if so, ignore this callback
	if (!self.task) { return; }

	BOOL        result;
	id<JAHPAuthenticatingHTTPProtocolDelegate> strongDelegate;

#pragma unused(session)
#pragma unused(task)
	assert(task == self.task);
	assert(challenge != nil);
	assert(completionHandler != nil);
	assert([NSThread currentThread] == self.clientThread);

	// Resolve NSURLAuthenticationMethodServerTrust ourselves
	if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
			SecTrustRef trust = challenge.protectionSpace.serverTrust;
			if (trust == nil) {
				assert(NO);
			}

			// Logger
			void (^logger)(NSString * _Nonnull logLine) = nil;

#ifdef TRACE
			logger =
			^(NSString * _Nonnull logLine) {
				[[self class] authenticatingHTTPProtocol:nil
										   logWithFormat:@"[ServerTrust] (%@) %@",
				 challenge.protectionSpace.host,
				 logLine];

			};
#endif

			BOOL successfulAuth = NO;

			if ([[HostSettings settingsOrDefaultsForHost:task.currentRequest.URL.host] boolSettingOrDefault:HOST_SETTINGS_KEY_IGNORE_TLS_ERRORS])
			{
				successfulAuth = YES;

				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
					completionHandler(NSURLSessionAuthChallengeUseCredential,
									  [NSURLCredential credentialForTrust:trust]);
				});
			}
			else {
				// Allow each URL to be loaded through JAHP
				NSURL* (^modifyOCSPURL)(NSURL *url) = ^NSURL*(NSURL *url) {
					[JAHPAuthenticatingHTTPProtocol temporarilyAllowURL:url
														  forWebViewTab:self->_wvt
														  isOCSPRequest:YES];
					return nil;
				};

				OCSPAuthURLSessionDelegate *authURLSessionDelegate =
				AppDelegate.sharedAppDelegate.certificateAuthentication.authURLSessionDelegate;

				successfulAuth =
				[authURLSessionDelegate evaluateTrust:trust
								modifyOCSPURLOverride:modifyOCSPURL
									  sessionOverride:sharedDemuxInstance.session
									completionHandler:completionHandler];
			}

			if (successfulAuth) {
				if ([[task.currentRequest mainDocumentURL] isEqual:[task.currentRequest URL]]) {
					SSLCertificate *certificate = [[SSLCertificate alloc] initWithSecTrustRef:trust];
					if (certificate != nil) {
						[self->_wvt setSSLCertificate:certificate];
						// Also cache the cert for displaying when
						// -URLSession:task:didReceiveChallenge: is not getting called
						// due to NSURLSession internal TLS caching
						// or UIWebView content caching
						[[[AppDelegate sharedAppDelegate] sslCertCache]
						 setObject:certificate
						 forKey:challenge.protectionSpace.host];
					}
				}
			}
		});

		return;
	}

	// Ask our delegate whether it wants this challenge.  We do this from this thread, not the main thread,
	// to avoid the overload of bouncing to the main thread for challenges that aren't going to be customised
	// anyway.

	strongDelegate = [[self class] delegate];

	result = NO;
	if ([strongDelegate respondsToSelector:@selector(authenticatingHTTPProtocol:canAuthenticateAgainstProtectionSpace:)]) {
		result = [strongDelegate authenticatingHTTPProtocol:self canAuthenticateAgainstProtectionSpace:[challenge protectionSpace]];
	}

	// If the client wants the challenge, kick off that process.  If not, resolve it by doing the default thing.

	if (result) {
		[[self class] authenticatingHTTPProtocol:self logWithFormat:@"can authenticate %@", [[challenge protectionSpace] authenticationMethod]];

		[self didReceiveAuthenticationChallenge:challenge completionHandler:completionHandler];
	} else {
		[[self class] authenticatingHTTPProtocol:self logWithFormat:@"cannot authenticate %@", [[challenge protectionSpace] authenticationMethod]];

		completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
	}
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
	// rdar://21484589
	// this is called from JAHPQNSURLSessionDemuxTaskInfo,
	// which is called from the NSURLSession delegateQueue,
	// which is a different thread than self.clientThread.
	// It is possible that -stopLoading was called on self.clientThread
	// just before this method if so, ignore this callback
	if (!self.task) { return; }

	NSURLCacheStoragePolicy cacheStoragePolicy;
	NSInteger               statusCode;

#pragma unused(session)
#pragma unused(dataTask)
	assert(dataTask == self.task);
	assert(response != nil);
	assert(completionHandler != nil);
	assert([NSThread currentThread] == self.clientThread);

	// Pass the call on to our client.  The only tricky thing is that we have to decide on a
	// cache storage policy, which is based on the actual request we issued, not the request
	// we were given.

	if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
		cacheStoragePolicy = JAHPCacheStoragePolicyForRequestAndResponse(self.task.originalRequest, (NSHTTPURLResponse *) response);
		statusCode = [((NSHTTPURLResponse *) response) statusCode];
	} else {
		assert(NO);
		cacheStoragePolicy = NSURLCacheStorageNotAllowed;
		statusCode = 42;
	}

	[[self class] authenticatingHTTPProtocol:self logWithFormat:@"received response %zd / %@ with cache storage policy %zu", (ssize_t) statusCode, [response URL], (size_t) cacheStoragePolicy];

	_contentType = CONTENT_TYPE_OTHER;
	_isFirstChunk = YES;

	if(_wvt && [[dataTask.currentRequest URL] isEqual:[dataTask.currentRequest mainDocumentURL]]) {
		[_wvt setUrl:[dataTask.currentRequest URL]];
//		dispatch_async(dispatch_get_main_queue(), ^{
//			[[[AppDelegate sharedAppDelegate] webViewController] adjustLayoutForNewHTTPResponse:self->_wvt];
//		});
	}

	NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)response;
	NSString *ctype = [[self caseInsensitiveHeader:@"content-type" inResponse:httpResponse] lowercaseString];
	if (ctype != nil) {
		if ([ctype hasPrefix:@"text/html"] || [ctype hasPrefix:@"application/html"] || [ctype hasPrefix:@"application/xhtml+xml"]) {
			_contentType = CONTENT_TYPE_HTML;
		} else {
			// TODO: keep adding new content types as needed
			// Determine if the content type is a file type
			// we can present.
			NSArray *types = @[
							   @"application/x-apple-diskimage",
							   @"application/binary",
							   @"application/octet-stream",
							   @"application/pdf",
							   @"application/x-gzip",
							   @"application/x-xz",
							   @"application/zip",
							   @"audio/",
							   @"audio/mpeg",
							   @"image/",
							   @"image/gif",
							   @"image/jpg",
							   @"image/jpeg",
							   @"image/png",
							   @"video/",
							   @"video/x-flv",
							   @"video/ogg",
							   @"video/webm"
							   ];
			// TODO: (performance) could use a dictionary of dictionaries matching on type and subtype
			for (NSString *type in types) {
				if ([ctype hasPrefix:type]) {
					_contentType = CONTENT_TYPE_FILE;
				}
			}
		}
	}

	if (_contentType == CONTENT_TYPE_FILE && _isOrigin && !_isTemporarilyAllowed) {
		/*
		 * If we've determined that the response's content type corresponds to a
		 * file type that we can attempt to preview we turn the request into a download.
		 * Once the download has completed we present it on the WebViewTab corresponding
		 * to the original request.
		 */

		// Create a fake response for the client with all headers but content type preserved
		NSMutableDictionary *fakeHeaders = [[NSMutableDictionary alloc] initWithDictionary:[httpResponse allHeaderFields]];
		// allHeaderFields canonicalizes header field names to their standard form.
		// E.g. "content-type" will be automatically adjusted to "Content-Type".
		// See: https://developer.apple.com/documentation/foundation/httpurlresponse/1417930-allheaderfields
		[fakeHeaders setObject:@"text/html" forKey:@"Content-Type"];
		[fakeHeaders setObject:@"0" forKey:@"Content-Length"];
		[fakeHeaders setObject:@"Cache-Control: no-cache, no-store, must-revalidate" forKey:@"Cache-Control"];
		NSURLResponse *fakeResponse = [[NSHTTPURLResponse alloc] initWithURL:[httpResponse URL] statusCode:200 HTTPVersion:@"1.1" headerFields:fakeHeaders];

		// Notify the client that the request finished loading so that
		// the requests's url enters its navigation history.
		[self.client URLProtocol:self didReceiveResponse:fakeResponse cacheStoragePolicy:NSURLCacheStorageNotAllowed];

		// Turn the request into a download
		completionHandler(NSURLSessionResponseBecomeDownload);
		return;
	}

	/* rewrite or inject Content-Security-Policy (and X-Webkit-CSP just in case) headers */
	NSString *host = dataTask.currentRequest.mainDocumentURL.host;
	if (host.length == 0) {
		host = dataTask.currentRequest.URL.host;
	}

	NSString *cspMode = [[HostSettings settingsOrDefaultsForHost:host] settingOrDefault:HOST_SETTINGS_KEY_CSP];

	NSMutableDictionary *responseHeaders = [[NSMutableDictionary alloc] initWithDictionary:[httpResponse allHeaderFields]];

	CSPHeader *cspHeader = [[CSPHeader alloc] initFromHeaders: responseHeaders];

	NoneSource *none = [[NoneSource alloc] init];

	// Allow styles and images, nothing else. However, don't open up styles and
	// images restrictions further than the original server response allows.
	if ([cspMode isEqualToString:HOST_SETTINGS_CSP_STRICT]) {
		HostSource *all = [HostSource all];

		Directive *style = [cspHeader get:StyleDirective.self];
		if (!style) {
			style = [[StyleDirective alloc] initWithSources:@[[[UnsafeInlineSource alloc] init], all]];
		}

		Directive *img = [cspHeader get:ImgDirective.self];
		if (!img) {
			img = [[ImgDirective alloc] initWithSources:@[all]];
		}

		DefaultDirective *deflt = [[DefaultDirective alloc] initWithSources:@[none]];
		SandboxDirective *sandbox = [[SandboxDirective alloc]
									 initWithSources:@[[[AllowFormsSource alloc] init],
													   [[AllowTopNavigationSource alloc] init],
													   [[AllowScripts alloc] init]]];

		cspHeader = [[CSPHeader alloc] initWithDirectives:@[deflt, style, img, sandbox]];
	}
	// Don't allow WebRTC, audio and video.
	else if ([cspMode isEqualToString:HOST_SETTINGS_CSP_BLOCK_CONNECT])
	{
		[cspHeader addOrReplaceDirective:[[ConnectDirective alloc] initWithSources:@[none]]];
		[cspHeader addOrReplaceDirective:[[MediaDirective alloc] initWithSources:@[none]]];
		[cspHeader addOrReplaceDirective:[[ObjectDirective alloc] initWithSources:@[none]]];
	}

	// Always allow communication within the app.
	SchemeSource *schemeSource = [[SchemeSource alloc] initWithScheme:@"endlessipc"];

	[cspHeader prependDirective:[[ChildDirective alloc] initWithSources:@[schemeSource]]];
	[cspHeader prependDirective:[[FrameDirective alloc] initWithSources:@[schemeSource]]];
	[cspHeader prependDirective:[[DefaultDirective alloc] initWithSources:@[schemeSource]]];

	// Allow our script to run.
	[cspHeader allowInjectedScriptWithNonce:[self cspNonce]];

	responseHeaders = [[cspHeader applyToHeaders: responseHeaders] mutableCopy];

	/* rebuild our response with any modified headers */
	response = [[NSHTTPURLResponse alloc] initWithURL:[httpResponse URL] statusCode:[httpResponse statusCode] HTTPVersion:@"1.1" headerFields:responseHeaders];

	/* save any cookies we just received
	 Note that we need to do the same thing in the
	 - (void)URLSession:task:willPerformHTTPRedirection
	 */
	[AppDelegate.sharedAppDelegate.cookieJar
	 setCookies:[NSHTTPCookie cookiesWithResponseHeaderFields:responseHeaders forURL:_actualRequest.URL]
	 forURL:_actualRequest.URL
	 mainDocumentURL:_actualRequest.mainDocumentURL
	 forTab:_wvt.hash];

	/* in case of localStorage */
	[AppDelegate.sharedAppDelegate.cookieJar trackDataAccessForDomain:[[response URL] host] fromTab:_wvt.hash];


	if ([[[self.request URL] scheme] isEqualToString:@"https"]) {
		NSString *hsts = [[(NSHTTPURLResponse *)response allHeaderFields] objectForKey:HSTS_HEADER];
		if (hsts != nil && ![hsts isEqualToString:@""]) {
			[[[AppDelegate sharedAppDelegate] hstsCache] parseHSTSHeader:hsts forHost:[[self.request URL] host]];
		}
	}

	// OCSP requests are performed out-of-band
	if (!_isOCSPRequest &&
		[_wvt secureMode] > WebViewTabSecureModeInsecure &&
		![[[[_actualRequest URL] scheme] lowercaseString] isEqualToString:@"https"]) {
		/* an element on the page was not sent over https but the initial request was, downgrade to mixed */
		if ([_wvt secureMode] > WebViewTabSecureModeInsecure) {
			[_wvt setSecureMode:WebViewTabSecureModeMixed];
		}
	}

	[[self client] URLProtocol:self didReceiveResponse:response cacheStoragePolicy:cacheStoragePolicy];

	completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{
	// rdar://21484589
	// this is called from JAHPQNSURLSessionDemuxTaskInfo,
	// which is called from the NSURLSession delegateQueue,
	// which is a different thread than self.clientThread.
	// It is possible that -stopLoading was called on self.clientThread
	// just before this method if so, ignore this callback
	if (!self.task) { return; }

#pragma unused(session)
#pragma unused(dataTask)
	assert(dataTask == self.task);
	assert(data != nil);
	assert([NSThread currentThread] == self.clientThread);

	if (_contentType == CONTENT_TYPE_HTML) {
		NSMutableData *tData = [[NSMutableData alloc] init];
		if (_isFirstChunk) {
			// Prepend a doctype to force into standards mode and throw in any javascript overrides
			[tData appendData:[[NSString stringWithFormat:@"<!DOCTYPE html><script type=\"text/javascript\" nonce=\"%@\">%@</script>",
								[self cspNonce],
								[self.class javascriptToInjectForURL:dataTask.currentRequest.mainDocumentURL]
								] dataUsingEncoding:NSUTF8StringEncoding]
				];
			[tData appendData:data];
			data = tData;
		}
	}

	_isFirstChunk = NO;

	// Just pass the call on to our client.

	[[self class] authenticatingHTTPProtocol:self logWithFormat:@"received %zu bytes of data", (size_t) [data length]];

	[[self client] URLProtocol:self didLoadData:data];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask willCacheResponse:(NSCachedURLResponse *)proposedResponse completionHandler:(void (^)(NSCachedURLResponse *))completionHandler
{
	// rdar://21484589
	// this is called from JAHPQNSURLSessionDemuxTaskInfo,
	// which is called from the NSURLSession delegateQueue,
	// which is a different thread than self.clientThread.
	// It is possible that -stopLoading was called on self.clientThread
	// just before this method if so, ignore this callback
	if (!self.task) { return; }

#pragma unused(session)
#pragma unused(dataTask)
	assert(dataTask == self.task);
	assert(proposedResponse != nil);
	assert(completionHandler != nil);
	assert([NSThread currentThread] == self.clientThread);

	// We implement this delegate callback purely for the purposes of logging.

	[[self class] authenticatingHTTPProtocol:self logWithFormat:@"will cache response"];

	completionHandler(proposedResponse);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
// An NSURLSession delegate callback.  We pass this on to the client.
{
#pragma unused(session)
#pragma unused(task)
	assert( (self.task == nil) || (task == self.task) );        // can be nil in the 'cancel from -stopLoading' case
	assert([NSThread currentThread] == self.clientThread);

	// Just log and then, in most cases, pass the call on to our client.

	if (error == nil) {
		[[self class] authenticatingHTTPProtocol:self logWithFormat:@"success"];

		[[self client] URLProtocolDidFinishLoading:self];
	} else if ( [[error domain] isEqual:NSURLErrorDomain] && ([error code] == NSURLErrorCancelled) ) {
		// Do nothing.  This happens in two cases:
		//
		// o during a redirect, in which case the redirect code has already told the client about
		//   the failure
		//
		// o if the request is cancelled by a call to -stopLoading, in which case the client doesn't
		//   want to know about the failure
	} else {
		[[self class] authenticatingHTTPProtocol:self logWithFormat:@"error %@ / %d", [error domain], (int) [error code]];

		NSMutableDictionary *ui = [[NSMutableDictionary alloc] initWithDictionary:[error userInfo]];
		[ui setObject:(_isOrigin ? @YES : @NO) forKeyedSubscript:ORIGIN_KEY];

		[self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:[error domain] code:[error code] userInfo:ui]];
	}

	// We don't need to clean up the connection here; the system will call, or has already called,
	// -stopLoading to do that.
}


- (NSString *)caseInsensitiveHeader:(NSString *)header inResponse:(NSHTTPURLResponse *)response
{
	NSString *o;
	for (id h in [response allHeaderFields]) {
		if ([[h lowercaseString] isEqualToString:[header lowercaseString]]) {
			o = [[response allHeaderFields] objectForKey:h];

			/* XXX: does webview always honor the first matching header or the last one? */
			break;
		}
	}

	return o;
}

- (NSString *)cspNonce
{
	if (!_cspNonce) {
		/*
		 * from https://w3c.github.io/webappsec-csp/#security-nonces:
		 *
		 * "The generated value SHOULD be at least 128 bits long (before encoding), and SHOULD
		 * "be generated via a cryptographically secure random number generator in order to
		 * "ensure that the value is difficult for an attacker to predict.
		 */

		NSMutableData *data = [NSMutableData dataWithLength:16];
		if (SecRandomCopyBytes(kSecRandomDefault, 16, data.mutableBytes) != 0)
			abort();

		_cspNonce = [data base64EncodedStringWithOptions:0];
	}

	return _cspNonce;
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didBecomeDownloadTask:(NSURLSessionDownloadTask *)downloadTask {
	self.task = downloadTask;
	if (_wvt != nil) {
		[_wvt didStartDownloadingFile];
	}
}

# pragma mark * NSURLSessionDownloadDelegate methods

- (void)URLSession:(NSURLSession *)session downloadTask:(nonnull NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
	if (_wvt != nil) {
		[_wvt setProgress:[NSNumber numberWithDouble:(double)totalBytesWritten/(double)totalBytesExpectedToWrite]];
	}
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
	if (_wvt != nil) {
		[_wvt didFinishDownloadingToURL:location];
	}
}

@end

@implementation JAHPWeakDelegateHolder

@end
