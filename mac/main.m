// FloatSubs: a floating, always-on-top subtitle window for macOS, in the spirit
// of NetEase Cloud Music's desktop lyrics, that behaves like Language Reactor's
// subtitles: hovering pauses the video and clicking a word shows its entry from
// the macOS dictionaries. Looked-up words are kept in a vocabulary list and shown
// in red wherever they appear again, until double-clicked.
//
// The FloatSubs Chrome extension launches this app via native messaging and
// streams the current subtitle as length-prefixed JSON on stdin:
//   {"type":"sub","orig":"...","trans":["..."]}   or   {"type":"clear"}
// The app sends back {"type":"hello"} on start, {"type":"hover","on":bool} as
// the mouse enters/leaves, and {"type":"quit"} when the user closes it from the
// menu so the extension stops relaunching it.
//
// Written in Objective-C rather than Swift so it builds with nothing but the
// Command Line Tools, whichever Swift/SDK combination they happen to ship.
//
// Preview without Chrome:  FloatSubs.app/Contents/MacOS/FloatSubs --demo

#import <AVFoundation/AVFoundation.h>
#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>
#import <NaturalLanguage/NaturalLanguage.h>
#include <errno.h>
#include <signal.h>
#include <unistd.h>

#pragma mark - Settings

typedef NS_ENUM(NSInteger, FSTheme) { FSThemeWhite, FSThemeYellow, FSThemeMint, FSThemeCount };

static NSString *FSThemeTitle(FSTheme theme) {
    return @[ @"经典白", @"亮黄", @"薄荷绿" ][theme];
}

static NSColor *FSThemeOriginalColor(FSTheme theme) {
    switch (theme) {
        case FSThemeYellow: return [NSColor colorWithSRGBRed:1.00 green:0.85 blue:0.30 alpha:1];
        case FSThemeMint: return [NSColor colorWithSRGBRed:0.55 green:0.94 blue:0.80 alpha:1];
        default: return NSColor.whiteColor;
    }
}

static NSUserDefaults *Defaults(void) { return NSUserDefaults.standardUserDefaults; }

@interface FSSettings : NSObject
@property (nonatomic) CGFloat fontSize;
@property (nonatomic) BOOL showOriginal;
@property (nonatomic) BOOL showTranslation;
@property (nonatomic) BOOL keepLast;      // keep the previous line on screen during gaps between subtitles
@property (nonatomic) BOOL locked;        // clicks pass through the window and it can't be dragged
@property (nonatomic) BOOL pauseOnHover;  // pause the video while the mouse is over the subtitles
@property (nonatomic) BOOL speakOnClick;  // read a clicked word aloud in a US English voice
@property (nonatomic) NSInteger lineLength;  // 0 short, 1 medium, 2 long; see kLineLengths
@property (nonatomic) FSTheme theme;
@property (nonatomic, readonly) BOOL hasAnchor;
@property (nonatomic) NSPoint anchor;  // bottom-centre of the window in global screen coordinates
- (void)clearAnchor;
@end

@implementation FSSettings

+ (void)initialize {
    [Defaults() registerDefaults:@{
        @"fontSize": @30, @"showOriginal": @YES, @"showTranslation": @YES, @"keepLast": @YES, @"locked": @NO,
        @"pauseOnHover": @YES, @"speakOnClick": @YES, @"lineLength": @1, @"theme": @0,
    }];
}

- (CGFloat)fontSize { return [Defaults() doubleForKey:@"fontSize"]; }
- (void)setFontSize:(CGFloat)value { [Defaults() setDouble:value forKey:@"fontSize"]; }
- (BOOL)showOriginal { return [Defaults() boolForKey:@"showOriginal"]; }
- (void)setShowOriginal:(BOOL)value { [Defaults() setBool:value forKey:@"showOriginal"]; }
- (BOOL)showTranslation { return [Defaults() boolForKey:@"showTranslation"]; }
- (void)setShowTranslation:(BOOL)value { [Defaults() setBool:value forKey:@"showTranslation"]; }
- (BOOL)keepLast { return [Defaults() boolForKey:@"keepLast"]; }
- (void)setKeepLast:(BOOL)value { [Defaults() setBool:value forKey:@"keepLast"]; }
- (BOOL)locked { return [Defaults() boolForKey:@"locked"]; }
- (void)setLocked:(BOOL)value { [Defaults() setBool:value forKey:@"locked"]; }
- (BOOL)pauseOnHover { return [Defaults() boolForKey:@"pauseOnHover"]; }
- (void)setPauseOnHover:(BOOL)value { [Defaults() setBool:value forKey:@"pauseOnHover"]; }
- (BOOL)speakOnClick { return [Defaults() boolForKey:@"speakOnClick"]; }
- (void)setSpeakOnClick:(BOOL)value { [Defaults() setBool:value forKey:@"speakOnClick"]; }
- (NSInteger)lineLength { return MIN(MAX([Defaults() integerForKey:@"lineLength"], 0), 2); }
- (void)setLineLength:(NSInteger)value { [Defaults() setInteger:value forKey:@"lineLength"]; }

- (FSTheme)theme {
    NSInteger value = [Defaults() integerForKey:@"theme"];
    return value >= 0 && value < FSThemeCount ? value : FSThemeWhite;
}
- (void)setTheme:(FSTheme)value { [Defaults() setInteger:value forKey:@"theme"]; }

- (BOOL)hasAnchor { return [Defaults() objectForKey:@"anchorX"] && [Defaults() objectForKey:@"anchorY"]; }
- (NSPoint)anchor { return NSMakePoint([Defaults() doubleForKey:@"anchorX"], [Defaults() doubleForKey:@"anchorY"]); }
- (void)setAnchor:(NSPoint)point {
    [Defaults() setDouble:point.x forKey:@"anchorX"];
    [Defaults() setDouble:point.y forKey:@"anchorY"];
}
- (void)clearAnchor {
    [Defaults() removeObjectForKey:@"anchorX"];
    [Defaults() removeObjectForKey:@"anchorY"];
}

@end

#pragma mark - Native messaging (Chrome <-> app over stdin/stdout)

// Chrome's framing: a 32-bit length in native byte order, then UTF-8 JSON.
@interface FSMessaging : NSObject
- (void)startWithHandler:(void (^)(NSDictionary *message))onMessage onClose:(void (^)(void))onClose;
- (void)send:(NSDictionary *)message;
@end

@implementation FSMessaging

static BOOL ReadExactly(int fd, void *buffer, size_t count) {
    size_t done = 0;
    while (done < count) {
        ssize_t n = read(fd, (char *)buffer + done, count - done);
        if (n > 0) done += (size_t)n;
        else if (n < 0 && errno == EINTR) continue;
        else return NO;  // EOF: Chrome closed the port
    }
    return YES;
}

- (void)startWithHandler:(void (^)(NSDictionary *))onMessage onClose:(void (^)(void))onClose {
    [NSThread detachNewThreadWithBlock:^{
        uint32_t length;
        while (ReadExactly(STDIN_FILENO, &length, sizeof length) && length < (64u << 20)) {
            NSMutableData *body = [NSMutableData dataWithLength:length];
            if (!ReadExactly(STDIN_FILENO, body.mutableBytes, length)) break;
            id message = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
            if ([message isKindOfClass:NSDictionary.class]) {
                dispatch_async(dispatch_get_main_queue(), ^{ onMessage(message); });
            }
        }
        dispatch_async(dispatch_get_main_queue(), onClose);
    }];
}

- (void)send:(NSDictionary *)message {
    NSData *body = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (!body) return;
    uint32_t length = (uint32_t)body.length;
    @synchronized(self) {
        write(STDOUT_FILENO, &length, sizeof length);
        write(STDOUT_FILENO, body.bytes, body.length);
    }
}

@end

#pragma mark - Dictionary

// Looks a word up in the dictionaries enabled in Dictionary.app (e.g. Oxford
// English–Chinese), falling back to simpler spellings ("We're" -> "we're" -> "we").
static NSString *FSLookUp(NSString *word) {
    NSMutableOrderedSet<NSString *> *candidates = [NSMutableOrderedSet orderedSetWithObjects:word, word.lowercaseString, nil];
    NSRange apostrophe = [word rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"'’"]];
    if (apostrophe.location != NSNotFound && apostrophe.location > 0) {
        [candidates addObject:[word substringToIndex:apostrophe.location].lowercaseString];
    }
    for (NSString *candidate in candidates) {
        NSString *entry = CFBridgingRelease(
            DCSCopyTextDefinition(NULL, (__bridge CFStringRef)candidate, CFRangeMake(0, (CFIndex)candidate.length)));
        if (entry.length) return entry;
    }
    return nil;
}

static NSString *FSReplace(NSString *text, NSString *pattern, NSString *replacement) {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    return [regex stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:replacement];
}

static NSParagraphStyle *FSParagraph(CGFloat indent, CGFloat spacingBefore) {
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.firstLineHeadIndent = indent;
    style.headIndent = indent;
    style.paragraphSpacingBefore = spacingBefore;
    style.lineSpacing = 1;
    return style;
}

// "BrE ˈbeɪsɪk, AmE ˈbeɪsɪk" -> "美 /ˈbeɪsɪk/  英 /ˈbeɪsɪk/", American first and brighter.
// Pronunciations without BrE/AmE labels (other dictionaries) are shown as they are.
static NSAttributedString *FSFormatPronunciation(NSString *pronunciation) {
    NSDictionary *us = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.9],
    };
    NSDictionary *other = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.5],
    };
    NSCharacterSet *trim = [NSCharacterSet characterSetWithCharactersInString:@" ,;"];
    NSRange american = [pronunciation rangeOfString:@"AmE "];
    NSRange british = [pronunciation rangeOfString:@"BrE "];
    NSMutableAttributedString *result = [NSMutableAttributedString new];
    if (american.location == NSNotFound) {
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:[@"   " stringByAppendingString:pronunciation]
                                                                       attributes:other]];
        return result;
    }
    NSString *usText = [[pronunciation substringFromIndex:NSMaxRange(american)] stringByTrimmingCharactersInSet:trim];
    [result appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"   美 /%@/", usText]
                                                                   attributes:us]];
    if (british.location != NSNotFound && british.location < american.location) {
        NSRange span = NSMakeRange(NSMaxRange(british), american.location - NSMaxRange(british));
        NSString *ukText = [[pronunciation substringWithRange:span] stringByTrimmingCharactersInSet:trim];
        if (ukText.length && ![ukText isEqualToString:usText]) {
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"   英 /%@/", ukText]
                                                                           attributes:other]];
        }
    }
    return result;
}

// Dictionary entries come back as one long line, e.g.
//   basic | BrE ˈbeɪsɪk, AmE ˈbeɪsɪk | A. adjective ① attributive (fundamental) 基本的 jīběn de ‹principle›▸ honesty is …
// Lay it out as headword + pronunciation, then one paragraph per part of speech
// (A./B.), sense (①②…) and example (▸), dropping the pinyin after Chinese glosses.
static NSAttributedString *FSFormatDefinition(NSString *word, NSString *entry) {
    NSString *headword = word;
    NSString *pronunciation = nil;
    NSString *body = entry;
    NSArray<NSString *> *parts = [entry componentsSeparatedByString:@" | "];
    NSCharacterSet *ipa = [NSCharacterSet characterSetWithCharactersInString:@"ˈˌə"];
    if (parts.count >= 3 && [parts[1] rangeOfCharacterFromSet:ipa].location != NSNotFound) {
        headword = parts[0];
        pronunciation = parts[1];
        body = [[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)] componentsJoinedByString:@" | "];
    }

    NSString *tones = @"āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜ";
    NSString *letters = [NSString stringWithFormat:@"[a-zü'%@]", tones];
    NSString *syllables = [NSString stringWithFormat:@"%@*[%@]%@*", letters, tones, letters];
    NSString *pinyin = [NSString stringWithFormat:@"(?<=\\p{Han}) %@(?: (?:%@|de|le|zi|men|ge|me|ne|ba|ma|zhe|guo)\\b)*",
                                                  syllables, syllables];
    body = FSReplace(body, pinyin, @"");
    body = FSReplace(body, @"\\s*(?=\\b[A-H]\\. [a-z])", @"\n");  // A. adjective, B. noun, …
    body = FSReplace(body, @"\\s*(?=[①-⑳])", @"\n");             // senses
    body = FSReplace(body, @"\\s*([▸•])\\s*", @"\n$1 ");           // examples, sub-senses
    body = FSReplace(body, @" {2,}", @" ");

    NSDictionary *partStyle = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.54 green:0.71 blue:0.97 alpha:1],
        NSParagraphStyleAttributeName: FSParagraph(0, 9),
    };
    NSDictionary *senseStyle = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13.5],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.94],
        NSParagraphStyleAttributeName: FSParagraph(0, 5),
    };
    NSDictionary *exampleStyle = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12.5],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.62],
        NSParagraphStyleAttributeName: FSParagraph(14, 2),
    };

    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:headword attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:18 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: NSColor.whiteColor,
    }];
    if (pronunciation) [result appendAttributedString:FSFormatPronunciation(pronunciation)];
    NSMutableParagraphStyle *header = [NSMutableParagraphStyle new];
    header.tailIndent = -30;  // keep clear of the speaker button in the corner
    [result addAttribute:NSParagraphStyleAttributeName value:header range:NSMakeRange(0, result.length)];
    for (NSString *rawLine in [body componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!line.length) continue;
        NSDictionary *style = senseStyle;
        if ([line hasPrefix:@"▸"] || [line hasPrefix:@"•"]) style = exampleStyle;
        else if ([line rangeOfString:@"^[A-H]\\. " options:NSRegularExpressionSearch].location != NSNotFound) style = partStyle;
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:line]
                                                                       attributes:style]];
    }
    return result;
}

static NSAttributedString *FSNotFound(NSString *word) {
    return [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"词典里没有找到「%@」", word] attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:13],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.7],
    }];
}

#pragma mark - Vocabulary

// Short lines are easily misdetected ("Soils!" reads as French), so fall back to English.
static NLLanguage FSLanguageOf(NSString *text) {
    NLLanguageRecognizer *recognizer = [NLLanguageRecognizer new];
    [recognizer processString:text];
    NSDictionary<NLLanguage, NSNumber *> *guess = [recognizer languageHypothesesWithMaximum:1];
    NLLanguage language = guess.allKeys.firstObject;
    return language && guess[language].doubleValue >= 0.8 ? language : NLLanguageEnglish;
}

// Only regular forms count ("soils"/"soil", "studied"/"study"): irregular lemmas such
// as "went" -> "go" or "we" -> "I" would make unrelated-looking words turn red.
static BOOL FSIsRegularForm(NSString *word, NSString *lemma) {
    if (!lemma.length) return NO;
    NSString *common = [word.lowercaseString commonPrefixWithString:lemma.lowercaseString options:0];
    return common.length >= MIN((NSUInteger)3, lemma.length);
}

// The words of a line, split the same way clicks pick words ("we're" is one word),
// each with its lemma when that is a regular form of it, so a marked word is
// recognised in its other forms too.
static void FSEnumerateWords(NSString *text, void (^block)(NSRange range, NSString *word, NSString *lemma)) {
    NLTagger *tagger = [[NLTagger alloc] initWithTagSchemes:@[ NLTagSchemeLemma ]];
    tagger.string = text;
    [tagger setLanguage:FSLanguageOf(text) range:NSMakeRange(0, text.length)];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByWords
                          usingBlock:^(NSString *word, NSRange range, NSRange enclosingRange, BOOL *stop) {
        NSRange tokenRange = NSMakeRange(NSNotFound, 0);
        NSString *lemma = [tagger tagAtIndex:range.location unit:NLTokenUnitWord scheme:NLTagSchemeLemma tokenRange:&tokenRange];
        if (!NSEqualRanges(tokenRange, range) || !FSIsRegularForm(word, lemma)) lemma = nil;
        block(range, word, lemma);
    }];
}

static NSString *FSLemmaAt(NSString *text, NSRange wordRange) {
    __block NSString *lemma = nil;
    FSEnumerateWords(text, ^(NSRange range, NSString *word, NSString *wordLemma) {
        if (!lemma && NSIntersectionRange(range, wordRange).length > 0) lemma = wordLemma;
    });
    return lemma;
}

// Words the user looked up, saved as a JSON list (by default in
// ~/Library/Application Support/FloatSubs/vocabulary.json):
//   [{"word": "soils", "lemma": "soil", "added": "2026-10-01T14:03:00Z", "sentence": "These soils are rich."}]
@interface FSVocabulary : NSObject
@property (nonatomic, readonly) NSUInteger version;  // bumped on every change
- (instancetype)initWithFile:(NSURL *)file;
- (BOOL)containsWord:(NSString *)word lemma:(NSString *)lemma;
- (void)addWord:(NSString *)word lemma:(NSString *)lemma sentence:(NSString *)sentence;
- (void)removeWord:(NSString *)word lemma:(NSString *)lemma;
@end

@implementation FSVocabulary {
    NSURL *_file;
    NSMutableArray<NSDictionary *> *_entries;
    NSMutableSet<NSString *> *_keys;  // lowercased words and lemmas of all entries
}

- (instancetype)init {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    return [self initWithFile:[support URLByAppendingPathComponent:@"FloatSubs/vocabulary.json"]];
}

- (instancetype)initWithFile:(NSURL *)file {
    self = [super init];
    if (self) {
        _file = file;
        _entries = [NSMutableArray array];
        NSData *data = [NSData dataWithContentsOfURL:file];
        id list = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([list isKindOfClass:NSArray.class]) {
            for (id entry in list) {
                if ([entry isKindOfClass:NSDictionary.class] && [entry[@"word"] isKindOfClass:NSString.class]) {
                    [_entries addObject:entry];
                }
            }
        }
        [self rebuildKeys];
    }
    return self;
}

- (void)rebuildKeys {
    _keys = [NSMutableSet set];
    for (NSDictionary *entry in _entries) {
        [_keys addObject:[entry[@"word"] lowercaseString]];
        if ([entry[@"lemma"] isKindOfClass:NSString.class]) [_keys addObject:[entry[@"lemma"] lowercaseString]];
    }
}

- (BOOL)containsWord:(NSString *)word lemma:(NSString *)lemma {
    return [_keys containsObject:word.lowercaseString] || (lemma && [_keys containsObject:lemma.lowercaseString]);
}

- (void)addWord:(NSString *)word lemma:(NSString *)lemma sentence:(NSString *)sentence {
    if ([self containsWord:word lemma:lemma]) return;
    [_entries addObject:@{
        @"word": word.lowercaseString,
        @"lemma": (lemma ?: word).lowercaseString,
        @"added": [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]],
        @"sentence": sentence ?: @"",
    }];
    [self changed];
}

- (void)removeWord:(NSString *)word lemma:(NSString *)lemma {
    NSMutableSet<NSString *> *targets = [NSMutableSet setWithObject:word.lowercaseString];
    if (lemma) [targets addObject:lemma.lowercaseString];
    NSIndexSet *matches = [_entries indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry, NSUInteger index, BOOL *stop) {
        return [targets containsObject:[entry[@"word"] lowercaseString]] ||
               ([entry[@"lemma"] isKindOfClass:NSString.class] && [targets containsObject:[entry[@"lemma"] lowercaseString]]);
    }];
    if (!matches.count) return;
    [_entries removeObjectsAtIndexes:matches];
    [self changed];
}

- (void)changed {
    _version++;
    [self rebuildKeys];
    [NSFileManager.defaultManager createDirectoryAtURL:_file.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:_entries
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    [data writeToURL:_file atomically:YES];
}

@end

#pragma mark - Windows

@interface FSPanel : NSPanel
@end

@implementation FSPanel

- (instancetype)init {
    self = [super initWithContentRect:NSMakeRect(0, 0, 300, 60)
                            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (self) {
        self.floatingPanel = YES;
        self.level = NSStatusWindowLevel;
        // Show on every Space, including over full-screen apps.
        self.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary |
                                  NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
        self.backgroundColor = NSColor.clearColor;
        self.opaque = NO;
        self.hasShadow = NO;
        self.hidesOnDeactivate = NO;
        self.releasedWhenClosed = NO;
        self.animationBehavior = NSWindowAnimationBehaviorNone;
    }
    return self;
}

// Never take keyboard focus away from the browser.
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }

@end

// One subtitle line: outlined text laid out by the text system, so drawing and
// finding the word under the pointer use exactly the same layout.
@interface FSLine : NSObject
@property (nonatomic) BOOL clickable;
@property (nonatomic, readonly) NSString *text;
- (instancetype)initWithText:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight color:(NSColor *)color;
- (CGFloat)wrapWidthForTarget:(CGFloat)target maxWidth:(CGFloat)maxWidth;
- (CGFloat)heightForWidth:(CGFloat)width;
- (void)drawAtPoint:(NSPoint)origin;
- (void)setColor:(NSColor *)color forRanges:(NSArray<NSValue *> *)ranges;
- (NSRange)wordRangeAtPoint:(NSPoint)point;  // point relative to the line's origin
- (NSRect)rectForRange:(NSRange)range;       // relative to the line's origin
@end

static NSLayoutManager *FSMakeLayout(NSTextStorage *storage, id<NSLayoutManagerDelegate> delegate) {
    NSTextContainer *container = [[NSTextContainer alloc] initWithSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
    container.lineFragmentPadding = 0;
    NSLayoutManager *layout = [NSLayoutManager new];
    layout.delegate = delegate;
    [layout addTextContainer:container];
    [storage addLayoutManager:layout];
    return layout;
}

@interface FSLine () <NSLayoutManagerDelegate>
@end

@implementation FSLine {
    NSTextStorage *_fill;
    NSTextStorage *_outline;
    NSLayoutManager *_fillLayout;
    NSLayoutManager *_outlineLayout;
    CGFloat _width;
    NSUInteger _forcedBreak;  // the only index a line may break before, or NSNotFound for anywhere
    CGFloat _wrapTarget, _wrapMax, _wrapWidth;  // last wrapWidthForTarget:maxWidth: call and result
}

- (instancetype)initWithText:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight color:(NSColor *)color {
    self = [super init];
    if (self) {
        NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
        style.alignment = NSTextAlignmentCenter;
        style.lineBreakMode = NSLineBreakByWordWrapping;
        NSFont *font = [NSFont systemFontOfSize:size weight:weight];
        NSShadow *shadow = [NSShadow new];
        shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.8];
        shadow.shadowBlurRadius = MAX(2, size * 0.12);
        shadow.shadowOffset = NSMakeSize(0, -1);
        // Outline: a stroke-only pass with a soft shadow, drawn under the fill.
        _fill = [[NSTextStorage alloc] initWithString:text attributes:@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: color,
            NSParagraphStyleAttributeName: style,
        }];
        _outline = [[NSTextStorage alloc] initWithString:text attributes:@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: NSColor.clearColor,
            NSParagraphStyleAttributeName: style,
            NSStrokeColorAttributeName: [NSColor colorWithWhite:0 alpha:0.9],
            NSStrokeWidthAttributeName: @10.0,
            NSShadowAttributeName: shadow,
        }];
        _fillLayout = FSMakeLayout(_fill, self);
        _outlineLayout = FSMakeLayout(_outline, self);
        _width = -1;
        _forcedBreak = NSNotFound;
    }
    return self;
}

- (BOOL)layoutManager:(NSLayoutManager *)layoutManager shouldBreakLineByWordBeforeCharacterAtIndex:(NSUInteger)index {
    return _forcedBreak == NSNotFound || index == _forcedBreak;
}

- (void)setForcedBreak:(NSUInteger)index {
    if (index == _forcedBreak) return;
    _forcedBreak = index;
    NSRange all = NSMakeRange(0, _fill.length);
    [_fillLayout invalidateLayoutForCharacterRange:all actualCharacterRange:NULL];
    [_outlineLayout invalidateLayoutForCharacterRange:all actualCharacterRange:NULL];
}

- (NSString *)text { return _fill.string; }

- (void)layOutAtWidth:(CGFloat)width {
    if (width == _width) return;
    _width = width;
    _fillLayout.textContainers.firstObject.size = NSMakeSize(width, CGFLOAT_MAX);
    _outlineLayout.textContainers.firstObject.size = NSMakeSize(width, CGFLOAT_MAX);
}

- (CGFloat)naturalWidthWithin:(CGFloat)maxWidth {
    [self layOutAtWidth:maxWidth];
    NSTextContainer *container = _fillLayout.textContainers.firstObject;
    __block CGFloat width = 0;
    [_fillLayout enumerateLineFragmentsForGlyphRange:[_fillLayout glyphRangeForTextContainer:container]
                                          usingBlock:^(NSRect rect, NSRect usedRect, NSTextContainer *c, NSRange glyphs, BOOL *stop) {
        width = MAX(width, usedRect.size.width);
    }];
    return MIN(ceil(width) + 1, maxWidth);  // +1 so laying out at exactly this width can't re-wrap
}

// Where to split the line in two: at a word boundary (for Chinese, a dictionary
// word boundary, so 免疫 stays whole), as evenly as possible, but right after
// punctuation when that is nearly as even. Returns the index the second line
// starts at and, in *cost, the wider half's width.
- (NSUInteger)bestSplitWithCost:(CGFloat *)cost {
    NSString *text = _fill.string;
    NSCharacterSet *space = NSCharacterSet.whitespaceCharacterSet;
    NSCharacterSet *punctuation = [NSCharacterSet characterSetWithCharactersInString:@",.;:!?，。、；：！？…—"];
    __block NSUInteger best = NSNotFound, bestAfterPunctuation = NSNotFound;
    __block CGFloat bestCost = CGFLOAT_MAX, bestAfterPunctuationCost = CGFLOAT_MAX;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByWords | NSStringEnumerationSubstringNotRequired
                          usingBlock:^(NSString *word, NSRange range, NSRange enclosingRange, BOOL *stop) {
        NSUInteger start = range.location, end = start;  // second line starts at start; first ends at end
        while (end > 0 && [space characterIsMember:[text characterAtIndex:end - 1]]) end--;
        if (end == 0) return;
        CGFloat first = [self->_fill attributedSubstringFromRange:NSMakeRange(0, end)].size.width;
        CGFloat second = [self->_fill attributedSubstringFromRange:NSMakeRange(start, text.length - start)].size.width;
        CGFloat wider = MAX(first, second);
        if (wider < bestCost) {
            bestCost = wider;
            best = start;
        }
        if ([punctuation characterIsMember:[text characterAtIndex:end - 1]] && wider < bestAfterPunctuationCost) {
            bestAfterPunctuationCost = wider;
            bestAfterPunctuation = start;
        }
    }];
    if (bestAfterPunctuation != NSNotFound && bestAfterPunctuationCost <= bestCost * 1.12) {
        best = bestAfterPunctuation;
        bestCost = bestAfterPunctuationCost;
    }
    *cost = bestCost;
    return best;
}

// The width to wrap this line at, subtitle style: one line if it fits the target
// width, otherwise two lines of about equal length (see bestSplitWithCost:). Only
// a line too long for two lines even at maxWidth wraps freely onto a third.
- (CGFloat)wrapWidthForTarget:(CGFloat)target maxWidth:(CGFloat)maxWidth {
    if (target == _wrapTarget && maxWidth == _wrapMax) return _wrapWidth;
    [self setForcedBreak:NSNotFound];
    CGFloat natural = [self naturalWidthWithin:100000];
    CGFloat width = MIN(natural, maxWidth);
    if (natural > MIN(target, maxWidth)) {
        CGFloat cost = 0;
        NSUInteger split = [self bestSplitWithCost:&cost];
        if (split != NSNotFound && ceil(cost) + 2 <= maxWidth) {
            width = ceil(cost) + 2;
            [self setForcedBreak:split];
        }
    }
    _wrapTarget = target;
    _wrapMax = maxWidth;
    _wrapWidth = width;
    return width;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    [self layOutAtWidth:width];
    NSTextContainer *container = _fillLayout.textContainers.firstObject;
    [_fillLayout ensureLayoutForTextContainer:container];
    return ceil(NSHeight([_fillLayout usedRectForTextContainer:container]));
}

- (void)drawAtPoint:(NSPoint)origin {
    NSTextContainer *outlineContainer = _outlineLayout.textContainers.firstObject;
    NSTextContainer *fillContainer = _fillLayout.textContainers.firstObject;
    [_outlineLayout drawGlyphsForGlyphRange:[_outlineLayout glyphRangeForTextContainer:outlineContainer] atPoint:origin];
    [_fillLayout drawGlyphsForGlyphRange:[_fillLayout glyphRangeForTextContainer:fillContainer] atPoint:origin];
}

- (void)setColor:(NSColor *)color forRanges:(NSArray<NSValue *> *)ranges {
    for (NSValue *range in ranges) [_fill addAttribute:NSForegroundColorAttributeName value:color range:range.rangeValue];
}

- (NSRange)wordRangeAtPoint:(NSPoint)point {
    NSRange none = NSMakeRange(NSNotFound, 0);
    if (!_fill.length) return none;
    NSTextContainer *container = _fillLayout.textContainers.firstObject;
    NSUInteger glyph = [_fillLayout glyphIndexForPoint:point inTextContainer:container];
    NSRect box = [_fillLayout boundingRectForGlyphRange:NSMakeRange(glyph, 1) inTextContainer:container];
    if (!NSPointInRect(point, NSInsetRect(box, -1, -2))) return none;
    NSRange word = [_fill doubleClickAtIndex:[_fillLayout characterIndexForGlyphAtIndex:glyph]];
    NSString *text = [_fill.string substringWithRange:word];
    return [text rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location == NSNotFound ? none : word;
}

- (NSRect)rectForRange:(NSRange)range {
    NSRange glyphs = [_fillLayout glyphRangeForCharacterRange:range actualCharacterRange:NULL];
    return [_fillLayout boundingRectForGlyphRange:glyphs inTextContainer:_fillLayout.textContainers.firstObject];
}

@end

@interface FSSubtitleView : NSView
@property (nonatomic, strong) FSSettings *settings;
@property (nonatomic, strong) FSVocabulary *vocabulary;  // its words are drawn in red
@property (nonatomic, copy) NSString *original;
@property (nonatomic, copy) NSString *translation;
@property (nonatomic, readonly) BOOL hasText;
@property (nonatomic, readonly) BOOL hovering;
@property (nonatomic, copy) void (^onHoverChanged)(BOOL inside);
@property (nonatomic, copy) void (^onWordClicked)(NSString *word, NSRange range, NSRect screenRect);
@property (nonatomic, copy) void (^onWordDoubleClicked)(NSString *word, NSRange range);
@property (nonatomic, copy) void (^onDragStarted)(void);
@property (nonatomic, copy) void (^onMoved)(void);
@property (nonatomic, copy) NSMenu * (^contextMenu)(void);
- (instancetype)initWithSettings:(FSSettings *)settings;
- (NSSize)fittingSizeForMaxWidth:(CGFloat)maxWidth;
- (void)clearSelection;
- (void)resetHover;
@end

@interface FSSubtitleView ()
@property (nonatomic, readwrite) BOOL hovering;
@end

static const CGFloat kPadX = 18;
static const CGFloat kPadY = 10;

@implementation FSSubtitleView {
    NSArray<FSLine *> *_lines;
    NSString *_linesKey;
    FSLine *_placeholder;
    NSRange _hoverWord;
    NSRange _selectedWord;
    BOOL _pressed;
    BOOL _dragging;
    NSPoint _dragMouse;
    NSPoint _dragOrigin;
}

- (instancetype)initWithSettings:(FSSettings *)settings {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        _settings = settings;
        _original = @"";
        _translation = @"";
        _hoverWord = _selectedWord = NSMakeRange(NSNotFound, 0);
        [self addTrackingArea:[[NSTrackingArea alloc]
                                  initWithRect:NSZeroRect
                                       options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways |
                                               NSTrackingInVisibleRect
                                         owner:self
                                      userInfo:nil]];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)setHovering:(BOOL)hovering {
    if (_hovering == hovering) return;
    _hovering = hovering;
    if (!hovering) _hoverWord = NSMakeRange(NSNotFound, 0);
    self.needsDisplay = YES;
    if (self.onHoverChanged) self.onHoverChanged(hovering);
}

- (void)resetHover {
    _hovering = NO;
    _hoverWord = NSMakeRange(NSNotFound, 0);
    self.needsDisplay = YES;
}

- (void)clearSelection {
    _selectedWord = NSMakeRange(NSNotFound, 0);
    self.needsDisplay = YES;
}

- (void)setOriginal:(NSString *)original {
    if ([original isEqualToString:_original]) return;
    _original = [original copy];
    _hoverWord = _selectedWord = NSMakeRange(NSNotFound, 0);  // ranges into the old text
}

- (BOOL)hasText {
    return (self.settings.showOriginal && self.original.length) || (self.settings.showTranslation && self.translation.length);
}

#pragma mark Layout

- (CGFloat)lineGap { return round(self.settings.fontSize * 0.2); }

// The lines for the current text, settings and vocabulary, rebuilt only when those change.
- (NSArray<FSLine *> *)lines {
    FSSettings *s = self.settings;
    NSString *key = [NSString stringWithFormat:@"%@\n%@\n%g %ld %d %d %lu", self.original, self.translation, s.fontSize,
                                               (long)s.theme, s.showOriginal, s.showTranslation,
                                               (unsigned long)self.vocabulary.version];
    if (![key isEqualToString:_linesKey]) {
        _linesKey = key;
        NSMutableArray<FSLine *> *lines = [NSMutableArray array];
        if (s.showOriginal && self.original.length) {
            FSLine *line = [[FSLine alloc] initWithText:self.original
                                                   size:s.fontSize
                                                 weight:NSFontWeightSemibold
                                                  color:FSThemeOriginalColor(s.theme)];
            line.clickable = YES;
            NSMutableArray<NSValue *> *marked = [NSMutableArray array];
            FSEnumerateWords(self.original, ^(NSRange range, NSString *word, NSString *lemma) {
                if ([self.vocabulary containsWord:word lemma:lemma]) [marked addObject:[NSValue valueWithRange:range]];
            });
            [line setColor:[NSColor colorWithSRGBRed:1.0 green:0.33 blue:0.33 alpha:1] forRanges:marked];
            [lines addObject:line];
        }
        if (s.showTranslation && self.translation.length) {
            [lines addObject:[[FSLine alloc] initWithText:self.translation
                                                     size:round(s.fontSize * 0.72)
                                                   weight:NSFontWeightMedium
                                                    color:[NSColor colorWithWhite:0.92 alpha:1]]];
        }
        _lines = lines;
    }
    return _lines;
}

- (FSLine *)placeholder {
    if (!_placeholder) {
        _placeholder = [[FSLine alloc] initWithText:@"悬浮字幕 · 等待字幕…"
                                               size:15
                                             weight:NSFontWeightRegular
                                              color:[NSColor colorWithWhite:1 alpha:0.8]];
    }
    return _placeholder;
}

// The original line (always first when shown) is the one whose words can be clicked.
- (FSLine *)clickableLine {
    FSLine *first = self.lines.firstObject;
    return first.clickable ? first : nil;
}

// Target line width per lineLength setting, in font sizes: about 32 / 42 / 56 letters.
static const CGFloat kLineLengths[] = {14, 18.5, 24.5};

// Wraps each line at its own width and centres it within innerWidth, top to bottom.
- (void)layOutLines:(NSArray<FSLine *> *)lines
            inWidth:(CGFloat)innerWidth
              using:(void (^)(FSLine *line, NSPoint origin, CGFloat width, CGFloat height))block {
    CGFloat target = self.settings.fontSize * kLineLengths[self.settings.lineLength];
    CGFloat y = kPadY;
    for (FSLine *line in lines) {
        CGFloat width = [line wrapWidthForTarget:target maxWidth:innerWidth];
        CGFloat height = [line heightForWidth:width];  // also leaves the line laid out at this width
        block(line, NSMakePoint(kPadX + (innerWidth - width) / 2, y), width, height);
        y += height + self.lineGap;
        // The translation may be as wide as the original above it before it wraps.
        if (line == lines.firstObject) target = MAX(target, width);
    }
}

- (NSSize)fittingSizeForMaxWidth:(CGFloat)maxWidth {
    NSArray<FSLine *> *lines = self.lines.count ? self.lines : @[ self.placeholder ];
    __block CGFloat width = 0, bottom = kPadY;
    [self layOutLines:lines
              inWidth:maxWidth - 2 * kPadX
                using:^(FSLine *line, NSPoint origin, CGFloat lineWidth, CGFloat height) {
        width = MAX(width, lineWidth);
        bottom = origin.y + height;
    }];
    return NSMakeSize(MAX(width + 2 * kPadX, 120), bottom + kPadY);
}

// Where the clickable line sits in the current bounds (and lays it out there).
- (NSPoint)clickableLineOrigin {
    __block NSPoint result = NSZeroPoint;
    [self layOutLines:self.lines
              inWidth:self.bounds.size.width - 2 * kPadX
                using:^(FSLine *line, NSPoint origin, CGFloat width, CGFloat height) {
        if (line.clickable) result = origin;
    }];
    return result;
}

- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.clearColor setFill];
    NSRectFillUsingOperation(self.bounds, NSCompositingOperationCopy);
    BOOL interactive = self.hovering && !self.settings.locked;
    if (interactive) {
        [[NSColor colorWithWhite:0 alpha:0.35] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:12 yRadius:12] fill];
    }
    NSArray<FSLine *> *lines = self.lines;
    // Nothing to show (gap between subtitles): stay invisible unless hovered,
    // so the window is still easy to find and drag.
    if (!lines.count && interactive) lines = @[ self.placeholder ];
    [self layOutLines:lines
              inWidth:self.bounds.size.width - 2 * kPadX
                using:^(FSLine *line, NSPoint origin, CGFloat width, CGFloat height) {
        if (line.clickable) {
            [self fillWord:self->_selectedWord ofLine:line at:origin color:[NSColor colorWithSRGBRed:1 green:0.84 blue:0.3 alpha:0.4]];
            if (interactive && !NSEqualRanges(self->_hoverWord, self->_selectedWord)) {
                [self fillWord:self->_hoverWord ofLine:line at:origin color:[NSColor colorWithWhite:1 alpha:0.18]];
            }
        }
        [line drawAtPoint:origin];
    }];
}

- (void)fillWord:(NSRange)word ofLine:(FSLine *)line at:(NSPoint)origin color:(NSColor *)color {
    if (word.location == NSNotFound) return;
    NSRect rect = NSOffsetRect([line rectForRange:word], origin.x, origin.y);
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, -3, 0) xRadius:5 yRadius:5] fill];
}

- (NSRange)wordAtPoint:(NSPoint)point {
    FSLine *line = self.clickableLine;
    if (!line) return NSMakeRange(NSNotFound, 0);
    NSPoint origin = self.clickableLineOrigin;
    return [line wordRangeAtPoint:NSMakePoint(point.x - origin.x, point.y - origin.y)];
}

#pragma mark Mouse

- (void)mouseEntered:(NSEvent *)event { self.hovering = YES; }
- (void)mouseExited:(NSEvent *)event { self.hovering = NO; }

- (void)mouseMoved:(NSEvent *)event {
    if (self.settings.locked) return;
    self.hovering = YES;  // the window may have appeared under a resting pointer
    NSRange word = [self wordAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (!NSEqualRanges(word, _hoverWord)) {
        _hoverWord = word;
        self.needsDisplay = YES;
    }
}

// A press that moves more than a few points drags the window; otherwise it's a click on a word.
- (void)mouseDown:(NSEvent *)event {
    _pressed = YES;
    _dragging = NO;
    _dragMouse = NSEvent.mouseLocation;
    _dragOrigin = self.window.frame.origin;
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_pressed) return;
    NSPoint mouse = NSEvent.mouseLocation;
    if (!_dragging) {
        if (hypot(mouse.x - _dragMouse.x, mouse.y - _dragMouse.y) < 3) return;
        _dragging = YES;
        if (self.onDragStarted) self.onDragStarted();
    }
    [self.window setFrameOrigin:NSMakePoint(_dragOrigin.x + mouse.x - _dragMouse.x, _dragOrigin.y + mouse.y - _dragMouse.y)];
}

- (void)mouseUp:(NSEvent *)event {
    if (_dragging) {
        if (self.onMoved) self.onMoved();
    } else if (_pressed) {
        [self clickAtPoint:[self convertPoint:event.locationInWindow fromView:nil] count:event.clickCount];
    }
    _pressed = NO;
    _dragging = NO;
}

// A click looks a word up; a double-click (whose first click already did that) unmarks it.
- (void)clickAtPoint:(NSPoint)point count:(NSInteger)count {
    NSRange word = [self wordAtPoint:point];
    if (word.location == NSNotFound) return;
    FSLine *line = self.clickableLine;
    NSString *text = [line.text substringWithRange:word];
    if (count == 2) {
        if (self.onWordDoubleClicked) self.onWordDoubleClicked(text, word);
        return;
    }
    if (count != 1 || !self.onWordClicked) return;
    _selectedWord = word;
    self.needsDisplay = YES;
    NSPoint origin = self.clickableLineOrigin;
    NSRect rect = NSOffsetRect([line rectForRange:word], origin.x, origin.y);
    NSRect screenRect = [self.window convertRectToScreen:[self convertRect:rect toView:nil]];
    self.onWordClicked(text, word, screenRect);
}

- (void)rightMouseDown:(NSEvent *)event {
    NSMenu *menu = self.contextMenu ? self.contextMenu() : nil;
    if (menu) [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

@end

#pragma mark - Dictionary popup

@interface FSCardView : NSView
@property (nonatomic, copy) void (^onHoverChanged)(BOOL inside);
@end

@implementation FSCardView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self addTrackingArea:[[NSTrackingArea alloc]
                                  initWithRect:NSZeroRect
                                       options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                         owner:self
                                      userInfo:nil]];
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *card = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:10 yRadius:10];
    [[NSColor colorWithWhite:0.1 alpha:0.96] setFill];
    [card fill];
    [[NSColor colorWithWhite:1 alpha:0.15] setStroke];
    [card stroke];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)mouseEntered:(NSEvent *)event { if (self.onHoverChanged) self.onHoverChanged(YES); }
- (void)mouseExited:(NSEvent *)event { if (self.onHoverChanged) self.onHoverChanged(NO); }

@end

// Our panels never become key, so buttons must take the very first click.
@interface FSFirstMouseButton : NSButton
@end

@implementation FSFirstMouseButton
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
@end

@interface FSDefinitionPanel : FSPanel
@property (nonatomic, copy) void (^onHoverChanged)(BOOL inside);
@property (nonatomic, copy) void (^onSpeak)(void);
- (void)showText:(NSAttributedString *)text nearRect:(NSRect)anchor outside:(NSRect)avoid;
@end

static const CGFloat kCardWidth = 400;
static const CGFloat kCardMaxHeight = 340;
static const NSSize kCardInset = {14, 12};

@implementation FSDefinitionPanel {
    NSTextView *_textView;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        FSCardView *card = [[FSCardView alloc] initWithFrame:NSMakeRect(0, 0, kCardWidth, kCardMaxHeight)];
        __weak FSDefinitionPanel *weakSelf = self;
        card.onHoverChanged = ^(BOOL inside) {
            FSDefinitionPanel *panel = weakSelf;
            if (panel.onHoverChanged) panel.onHoverChanged(inside);
        };
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:card.bounds];
        scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        scroll.drawsBackground = NO;
        scroll.hasVerticalScroller = YES;
        scroll.autohidesScrollers = YES;
        scroll.scrollerStyle = NSScrollerStyleOverlay;
        scroll.scrollerKnobStyle = NSScrollerKnobStyleLight;
        NSSize content = scroll.contentSize;
        _textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, content.width, content.height)];
        _textView.minSize = NSZeroSize;
        _textView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
        _textView.verticallyResizable = YES;
        _textView.horizontallyResizable = NO;
        _textView.autoresizingMask = NSViewWidthSizable;
        _textView.textContainer.containerSize = NSMakeSize(content.width, CGFLOAT_MAX);
        _textView.textContainer.widthTracksTextView = YES;
        _textView.textContainer.lineFragmentPadding = 0;
        _textView.textContainerInset = kCardInset;
        _textView.editable = NO;
        _textView.selectable = NO;
        _textView.drawsBackground = NO;
        scroll.documentView = _textView;
        [card addSubview:scroll];

        NSImage *speakerImage = [NSImage imageWithSystemSymbolName:@"speaker.wave.2.fill" accessibilityDescription:@"朗读"];
        NSButton *speaker = [FSFirstMouseButton buttonWithImage:speakerImage target:self action:@selector(speak)];
        speaker.bordered = NO;
        speaker.contentTintColor = [NSColor colorWithWhite:1 alpha:0.75];
        speaker.toolTip = @"美式发音";
        speaker.frame = NSMakeRect(kCardWidth - 38, kCardMaxHeight - 36, 26, 26);
        speaker.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;  // stays in the top-right corner
        [card addSubview:speaker];
        self.contentView = card;
    }
    return self;
}

- (void)speak {
    if (self.onSpeak) self.onSpeak();
}

// Fills the card and sizes it to the text (up to kCardMaxHeight, then it scrolls).
- (CGFloat)setText:(NSAttributedString *)text {
    [self setContentSize:NSMakeSize(kCardWidth, kCardMaxHeight)];
    [_textView.textStorage setAttributedString:text];
    [_textView.layoutManager ensureLayoutForTextContainer:_textView.textContainer];
    CGFloat textHeight = NSHeight([_textView.layoutManager usedRectForTextContainer:_textView.textContainer]);
    CGFloat height = MIN(ceil(textHeight) + 2 * kCardInset.height + 2, kCardMaxHeight);
    [self setContentSize:NSMakeSize(kCardWidth, height)];
    [_textView scrollPoint:NSZeroPoint];
    return height;
}

// Shows the card above the subtitles (or below if there's no room), centred on the word.
- (void)showText:(NSAttributedString *)text nearRect:(NSRect)anchor outside:(NSRect)avoid {
    CGFloat height = [self setText:text];
    NSPoint center = NSMakePoint(NSMidX(anchor), NSMidY(anchor));
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    for (NSScreen *candidate in NSScreen.screens) {
        if (NSPointInRect(center, candidate.frame)) screen = candidate;
    }
    NSRect area = screen.visibleFrame;
    CGFloat x = MIN(MAX(center.x - kCardWidth / 2, NSMinX(area) + 4), NSMaxX(area) - kCardWidth - 4);
    // Overlap the subtitles slightly so the pointer never crosses a gap between the two.
    CGFloat y = NSMaxY(avoid) - 4;
    if (y + height > NSMaxY(area)) y = NSMinY(avoid) - height + 4;
    [self setFrameOrigin:NSMakePoint(x, y)];
    [self orderFrontRegardless];
}

@end

#pragma mark - App

typedef NS_ENUM(NSInteger, FSMode) { FSModeChrome, FSModeDemo, FSModeStandalone };

@interface FSController : NSObject <NSApplicationDelegate, NSMenuDelegate>
- (instancetype)initWithMode:(FSMode)mode;
@end

@implementation FSController {
    FSMode _mode;
    FSSettings *_settings;
    FSVocabulary *_vocabulary;
    FSMessaging *_messaging;
    FSPanel *_panel;
    FSSubtitleView *_view;
    FSDefinitionPanel *_popup;
    NSString *_popupWord;  // word whose definition is showing, nil when closed
    AVSpeechSynthesizer *_speech;
    NSStatusItem *_statusItem;
    BOOL _active;  // a video page is currently feeding us subtitles
    BOOL _userHidden;
    BOOL _mouseInSubtitles;
    BOOL _mouseInPopup;
    BOOL _pausedByHover;  // we asked the extension to pause the video
    NSUInteger _demoIndex;
}

- (instancetype)initWithMode:(FSMode)mode {
    self = [super init];
    if (self) {
        _mode = mode;
        _settings = [FSSettings new];
        _messaging = [FSMessaging new];
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if (_mode == FSModeStandalone) {
        [self explainAndQuit];
        return;
    }
    __weak FSController *weakSelf = self;

    _vocabulary = [FSVocabulary new];
    _panel = [FSPanel new];
    _view = [[FSSubtitleView alloc] initWithSettings:_settings];
    _view.vocabulary = _vocabulary;
    _panel.contentView = _view;
    _panel.ignoresMouseEvents = _settings.locked;
    _view.onMoved = ^{ [weakSelf saveAnchor]; };
    _view.onDragStarted = ^{ [weakSelf closePopup]; };
    _view.onHoverChanged = ^(BOOL inside) { [weakSelf mouseInSubtitles:inside]; };
    _view.onWordClicked = ^(NSString *word, NSRange range, NSRect rect) {
        [weakSelf markWord:word at:range];
        [weakSelf showDefinitionOf:word near:rect];
    };
    _view.onWordDoubleClicked = ^(NSString *word, NSRange range) { [weakSelf unmarkWord:word at:range]; };
    _view.contextMenu = ^NSMenu * {
        NSMenu *menu = [NSMenu new];
        [weakSelf fillMenu:menu];
        return menu;
    };

    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSImage *image = [NSImage imageWithSystemSymbolName:@"captions.bubble" accessibilityDescription:@"悬浮字幕"];
    if (image) {
        image.template = YES;
        _statusItem.button.image = image;
    } else {
        _statusItem.button.title = @"字";
    }
    NSMenu *menu = [NSMenu new];
    menu.delegate = self;
    _statusItem.menu = menu;

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(render)
                                               name:NSApplicationDidChangeScreenParametersNotification
                                             object:nil];

    if (_mode == FSModeDemo) {
        [NSTimer scheduledTimerWithTimeInterval:4 target:self selector:@selector(demoTick) userInfo:nil repeats:YES];
        [self demoTick];
    } else {
        [_messaging startWithHandler:^(NSDictionary *message) { [weakSelf handle:message]; }
                             onClose:^{ [NSApp terminate:nil]; }];
        [_messaging send:@{@"type": @"hello"}];
    }
}

- (void)handle:(NSDictionary *)message {
    NSString *type = message[@"type"];
    if ([type isEqual:@"sub"]) {
        _active = YES;
        NSString *original = [message[@"orig"] isKindOfClass:NSString.class] ? message[@"orig"] : @"";
        NSMutableArray<NSString *> *translations = [NSMutableArray array];
        id list = message[@"trans"];
        if ([list isKindOfClass:NSArray.class]) {
            for (id item in list) {
                if ([item isKindOfClass:NSString.class]) [translations addObject:item];
            }
        }
        NSString *translation = [translations componentsJoinedByString:@"\n"];
        if (!(original.length == 0 && translation.length == 0 && _settings.keepLast)) {
            if (![original isEqualToString:_view.original]) [self closePopup];
            _view.original = original;
            _view.translation = translation;
        }
    } else if ([type isEqual:@"clear"]) {
        _active = NO;
        _view.original = @"";
        _view.translation = @"";
    } else {
        return;
    }
    [self render];
}

- (void)render {
    if (!_active || _userHidden) {
        if (_panel.visible) {
            [_view resetHover];
            [self hoverEnded];
        }
        [_panel orderOut:nil];
        return;
    }
    _view.needsDisplay = YES;
    // In a gap between subtitles keep the current frame instead of shrinking.
    if (_view.hasText || !_panel.visible) [self fitPanel];
    [_panel orderFrontRegardless];
}

- (void)fitPanel {
    NSPoint anchor = [self currentAnchor];
    NSScreen *screen = nil;
    for (NSScreen *candidate in NSScreen.screens) {
        if (NSPointInRect(anchor, candidate.frame)) {
            screen = candidate;
            break;
        }
    }
    if (!screen) screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect area = screen.frame;
    NSSize size = [_view fittingSizeForMaxWidth:MIN(area.size.width * 0.85, 1400)];
    CGFloat x = MIN(MAX(anchor.x - size.width / 2, NSMinX(area)), NSMaxX(area) - size.width);
    CGFloat y = MIN(MAX(anchor.y, NSMinY(area)), NSMaxY(area) - size.height);
    [_panel setFrame:NSMakeRect(x, y, size.width, size.height) display:NO];
}

- (NSPoint)currentAnchor {
    if (_settings.hasAnchor) {
        NSPoint anchor = _settings.anchor;
        for (NSScreen *screen in NSScreen.screens) {
            if (NSPointInRect(anchor, screen.frame)) return anchor;
        }
    }
    NSRect visible = (NSScreen.mainScreen ?: NSScreen.screens.firstObject).visibleFrame;
    return NSMakePoint(NSMidX(visible), NSMinY(visible) + 60);
}

- (void)saveAnchor {
    NSRect frame = _panel.frame;
    NSPoint anchor = NSMakePoint(NSMidX(frame), NSMinY(frame));
    NSScreen *screen = _panel.screen ?: NSScreen.mainScreen;
    if (screen) {
        NSRect area = screen.frame;
        anchor.x = MIN(MAX(anchor.x, NSMinX(area)), NSMaxX(area) - 1);
        anchor.y = MIN(MAX(anchor.y, NSMinY(area)), NSMaxY(area) - 1);
    }
    _settings.anchor = anchor;
    [self render];
}

#pragma mark Hover pause and dictionary popup

- (void)mouseInSubtitles:(BOOL)inside {
    _mouseInSubtitles = inside;
    [self hoverChanged];
}

- (void)mouseInPopup:(BOOL)inside {
    _mouseInPopup = inside;
    [self hoverChanged];
}

// Pause as soon as the pointer is over the subtitles or the popup; resume after it
// has left both for a moment, so moving from one to the other doesn't resume.
- (void)hoverChanged {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hoverEnded) object:nil];
    if (_mouseInSubtitles || _mouseInPopup) {
        if (!_pausedByHover && _settings.pauseOnHover && _mode == FSModeChrome) {
            _pausedByHover = YES;
            [_messaging send:@{@"type": @"hover", @"on": @YES}];
        }
    } else {
        [self performSelector:@selector(hoverEnded) withObject:nil afterDelay:0.3];
    }
}

- (void)hoverEnded {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hoverEnded) object:nil];
    _mouseInSubtitles = NO;
    _mouseInPopup = NO;
    [self closePopup];
    if (_pausedByHover) {
        _pausedByHover = NO;
        [_messaging send:@{@"type": @"hover", @"on": @NO}];
    }
}

- (void)showDefinitionOf:(NSString *)word near:(NSRect)wordRect {
    if (_popupWord && [word isEqualToString:_popupWord]) {  // clicking the same word again closes it
        [self closePopup];
        return;
    }
    if (!_popup) {
        _popup = [FSDefinitionPanel new];
        __weak FSController *weakSelf = self;
        _popup.onHoverChanged = ^(BOOL inside) { [weakSelf mouseInPopup:inside]; };
        _popup.onSpeak = ^{ [weakSelf speak:nil]; };
    }
    NSString *entry = FSLookUp(word);
    _popupWord = word;
    [_popup showText:entry ? FSFormatDefinition(word, entry) : FSNotFound(word) nearRect:wordRect outside:_panel.frame];
    if (_settings.speakOnClick) [self speak:word];
}

// Reads the word aloud in the best US English voice installed (an Enhanced or
// Premium one if the user downloaded it in System Settings > Spoken Content).
- (void)speak:(NSString *)word {
    word = word ?: _popupWord;
    if (!word.length) return;
    if (!_speech) _speech = [AVSpeechSynthesizer new];
    AVSpeechSynthesisVoice *voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
    for (AVSpeechSynthesisVoice *candidate in AVSpeechSynthesisVoice.speechVoices) {
        if ([candidate.language isEqualToString:@"en-US"] && candidate.quality > voice.quality) voice = candidate;
    }
    AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:word];
    utterance.voice = voice;
    [_speech stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    [_speech speakUtterance:utterance];
}

// Looking a word up adds it to the vocabulary, so it shows in red from now on.
- (void)markWord:(NSString *)word at:(NSRange)range {
    NSString *sentence = _view.original;
    [_vocabulary addWord:word lemma:FSLemmaAt(sentence, range) sentence:sentence];
    _view.needsDisplay = YES;
}

- (void)unmarkWord:(NSString *)word at:(NSRange)range {
    [self closePopup];
    [_vocabulary removeWord:word lemma:FSLemmaAt(_view.original, range)];
    _view.needsDisplay = YES;
}

- (void)closePopup {
    if (!_popupWord) return;
    BOOL wasInPopup = _mouseInPopup;
    _popupWord = nil;
    _mouseInPopup = NO;
    [_popup orderOut:nil];
    [_view clearSelection];
    if (wasInPopup) [self hoverChanged];  // the pointer may now be over nothing of ours
}

#pragma mark Menu (menu bar icon and right-click on the subtitles)

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [self fillMenu:menu];
}

- (void)fillMenu:(NSMenu *)menu {
    [menu removeAllItems];
    [self addItemTo:menu title:@"锁定字幕（鼠标可穿透）" action:@selector(toggleLock) state:_settings.locked];
    [self addItemTo:menu title:@"鼠标悬停时暂停视频" action:@selector(togglePauseOnHover) state:_settings.pauseOnHover];
    [self addItemTo:menu title:@"点词时朗读（美式发音）" action:@selector(toggleSpeakOnClick) state:_settings.speakOnClick];
    [menu addItem:NSMenuItem.separatorItem];
    [self addItemTo:menu title:@"显示原文" action:@selector(toggleOriginal) state:_settings.showOriginal];
    [self addItemTo:menu title:@"显示翻译" action:@selector(toggleTranslation) state:_settings.showTranslation];
    [self addItemTo:menu title:@"句子间隙保留上一句" action:@selector(toggleKeepLast) state:_settings.keepLast];
    [menu addItem:NSMenuItem.separatorItem];
    [self addItemTo:menu title:@"放大字号" action:@selector(biggerFont) state:-1];
    [self addItemTo:menu title:@"缩小字号" action:@selector(smallerFont) state:-1];
    NSMenu *colors = [NSMenu new];
    for (FSTheme theme = 0; theme < FSThemeCount; theme++) {
        [self addItemTo:colors title:FSThemeTitle(theme) action:@selector(pickTheme:) state:_settings.theme == theme].tag = theme;
    }
    [menu addItemWithTitle:@"颜色" action:nil keyEquivalent:@""].submenu = colors;
    NSMenu *lengths = [NSMenu new];
    NSArray<NSString *> *lengthTitles = @[ @"短（约 32 个字母）", @"中（约 42 个字母）", @"长（约 56 个字母）" ];
    for (NSInteger length = 0; length < 3; length++) {
        [self addItemTo:lengths title:lengthTitles[length] action:@selector(pickLineLength:) state:_settings.lineLength == length].tag = length;
    }
    [menu addItemWithTitle:@"每行长度（超出自动分两行）" action:nil keyEquivalent:@""].submenu = lengths;
    [menu addItem:NSMenuItem.separatorItem];
    [self addItemTo:menu title:@"重置位置" action:@selector(resetPosition) state:-1];
    [self addItemTo:menu title:(_userHidden ? @"显示悬浮窗" : @"暂时隐藏悬浮窗") action:@selector(toggleHidden) state:-1];
    [self addItemTo:menu title:@"关闭悬浮字幕" action:@selector(quit) state:-1].toolTip =
        @"之后在 Chrome 工具栏点「悬浮字幕」扩展图标即可重新开启";
}

// state: 1 = checked, 0 = unchecked, -1 = no checkmark.
- (NSMenuItem *)addItemTo:(NSMenu *)menu title:(NSString *)title action:(SEL)action state:(NSInteger)state {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    if (state >= 0) item.state = state ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:item];
    return item;
}

- (void)toggleLock {
    _settings.locked = !_settings.locked;
    _panel.ignoresMouseEvents = _settings.locked;
    [_view resetHover];
    [self hoverEnded];
    [self render];
}

- (void)togglePauseOnHover { _settings.pauseOnHover = !_settings.pauseOnHover; }
- (void)toggleSpeakOnClick { _settings.speakOnClick = !_settings.speakOnClick; }

- (void)pickLineLength:(NSMenuItem *)sender {
    _settings.lineLength = sender.tag;
    [self render];
}
- (void)toggleOriginal { _settings.showOriginal = !_settings.showOriginal; [self render]; }
- (void)toggleTranslation { _settings.showTranslation = !_settings.showTranslation; [self render]; }
- (void)toggleKeepLast { _settings.keepLast = !_settings.keepLast; [self render]; }
- (void)biggerFont { _settings.fontSize = MIN(_settings.fontSize + 2, 72); [self render]; }
- (void)smallerFont { _settings.fontSize = MAX(_settings.fontSize - 2, 14); [self render]; }
- (void)resetPosition { [_settings clearAnchor]; [self render]; }
- (void)toggleHidden { _userHidden = !_userHidden; [self render]; }

- (void)pickTheme:(NSMenuItem *)sender {
    _settings.theme = sender.tag;
    [self render];
}

- (void)quit {
    [self hoverEnded];  // don't leave the video paused
    if (_mode == FSModeChrome) [_messaging send:@{@"type": @"quit"}];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSApp terminate:nil];
    });
}

#pragma mark Demo / standalone

- (void)demoTick {
    if (_popupWord) return;  // don't swap the sentence out from under an open definition
    NSArray<NSArray<NSString *> *> *samples = @[
        @[ @"This is FloatSubs. Drag me anywhere on the screen.", @"这是悬浮字幕，可以拖到屏幕上任何地方。" ],
        @[ @"Click any word to look it up in the dictionary.", @"点击任意单词即可查词典。" ],
        @[ @"When locked, mouse clicks pass straight through.", @"锁定之后，鼠标点击会直接穿透字幕。" ],
    ];
    NSArray<NSString *> *sample = samples[_demoIndex++ % samples.count];
    [self handle:@{@"type": @"sub", @"orig": sample[0], @"trans": @[ sample[1] ]}];
}

- (void)explainAndQuit {
    if (@available(macOS 14, *)) {
        [NSApp activate];
    } else {
        [NSApp activateIgnoringOtherApps:YES];
    }
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"悬浮字幕会由 Chrome 扩展自动启动";
    alert.informativeText = [NSString stringWithFormat:@"在 Chrome 里打开带字幕的 YouTube 视频，悬浮字幕就会出现。\n\n"
                                                       @"想单独预览效果，可以在终端运行：\n%@ --demo",
                                                       NSProcessInfo.processInfo.arguments.firstObject];
    [alert runModal];
    [NSApp terminate:nil];
}

@end

#pragma mark - Main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        FSMode mode = FSModeStandalone;
        for (NSString *argument in NSProcessInfo.processInfo.arguments) {
            if ([argument isEqual:@"--demo"]) mode = FSModeDemo;
            else if ([argument hasPrefix:@"chrome-extension://"] && mode != FSModeDemo) mode = FSModeChrome;
        }
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        FSController *controller = [[FSController alloc] initWithMode:mode];
        app.delegate = controller;
        [app run];
    }
    return 0;
}
