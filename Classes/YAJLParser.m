//
//	YAJLParser.m
//	YAJL
//
//	Created by Gabriel Handford on 6/14/09.
//	Copyright 2009. All rights reserved.
//
//	Permission is hereby granted, free of charge, to any person
//	obtaining a copy of this software and associated documentation
//	files (the "Software"), to deal in the Software without
//	restriction, including without limitation the rights to use,
//	copy, modify, merge, publish, distribute, sublicense, and/or sell
//	copies of the Software, and to permit persons to whom the
//	Software is furnished to do so, subject to the following
//	conditions:
//
//	The above copyright notice and this permission notice shall be
//	included in all copies or substantial portions of the Software.
//
//	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//	EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
//	OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//	NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//	HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
//	WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//	FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//	OTHER DEALINGS IN THE SOFTWARE.
//


#import "YAJLParser.h"
#import "yajl_parse.h"

NSString *const YAJLErrorDomain = @"YAJLErrorDomain";
NSString *const YAJLParserException = @"YAJLParserException";
NSString *const YAJLParsingUnsupportedException = @"YAJLParsingUnsupportedException";

NSString *const YAJLParserValueKey = @"YAJLParserValueKey";

@interface YAJLParser ()
@property (strong, nonatomic) NSError *parserError;
@end

//! @internal

@interface YAJLParser ()
@property yajl_handle handle;

- (void)_add:(id)value;
- (void)_mapKey:(NSString *)key;

- (void)_startDictionary;
- (void)_endDictionary;

- (void)_startArray;
- (void)_endArray;

- (NSError *)_errorForStatus:(NSInteger)code message:(NSString *)message value:(NSString *)value;
- (void)_cancelWithErrorForStatus:(NSInteger)code message:(NSString *)message value:(NSString *)value;
@end

//! @endinternal


@implementation YAJLParser

- (instancetype)init {
	return [self initWithParserOptions:0];
}

- (instancetype)initWithParserOptions:(YAJLParserOptions)parserOptions {
	if ((self = [super init])) {
		_parserOptions = parserOptions;
	}
	return self;
}

- (void)dealloc {
	if (_handle != NULL) {
		yajl_free(_handle);
		_handle = NULL;
	}
	
}

#pragma mark Error Helpers

- (NSError *)_errorForStatus:(NSInteger)code message:(NSString *)message value:(NSString *)value {
	NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey];
	if (value) userInfo[YAJLParserValueKey] = value;
	return [NSError errorWithDomain:YAJLErrorDomain code:code userInfo:userInfo];
}

- (void)_cancelWithErrorForStatus:(NSInteger)code message:(NSString *)message value:(NSString *)value {
	self.parserError = [self _errorForStatus:code message:message value:value];
}

#pragma mark YAJL Callbacks

int yajl_null(void *ctx) {
	[(__bridge id)ctx _add:[NSNull null]];
	return 1;
}

int yajl_boolean(void *ctx, int boolVal) {
	NSNumber *number = [[NSNumber alloc] initWithBool:(BOOL)boolVal];
	[(__bridge id)ctx _add:number];
	return 1;
}

// Instead of using yajl_integer, and yajl_double we use yajl_number and parse
// as double (or long long); This is to be more compliant since Javascript numbers are represented
// as double precision floating point, though JSON spec doesn't define a max value
// and is up to the parser?

//int yajl_integer(void *ctx, long integerVal) {
//	[(id)ctx _add:[NSNumber numberWithLong:integerVal]];
//	return 1;
//}
//
//int yajl_double(void *ctx, double doubleVal) {
//	[(id)ctx _add:[NSNumber numberWithDouble:doubleVal]];
//	return 1;
//}

int ParseDouble(void *ctx, const char *buf, const char *numberVal, size_t numberLen) {
	double d = strtod((char *)buf, NULL);
	if ((d == HUGE_VAL || d == -HUGE_VAL) && errno == ERANGE) {
		NSString *s = [[NSString alloc] initWithBytes:numberVal length:numberLen encoding:NSUTF8StringEncoding];
		[(__bridge id)ctx _cancelWithErrorForStatus:YAJLParserErrorCodeDoubleOverflow message:[NSString stringWithFormat:@"double overflow on '%@'", s] value:s];
		return 0;
	}
	NSNumber *number = [[NSNumber alloc] initWithDouble:d];
	[(__bridge id)ctx _add:number];
	return 1;
}

int yajl_number(void *ctx, const char *numberVal, size_t numberLen) {
	char buf[numberLen+1];
	memcpy(buf, numberVal, numberLen);
	buf[numberLen] = 0;
	
	if (memchr(numberVal, '.', numberLen) || memchr(numberVal, 'e', numberLen) || memchr(numberVal, 'E', numberLen)) {
		return ParseDouble(ctx, buf, numberVal, numberLen);
	} else {
		long long i = strtoll((const char *) buf, NULL, 10);
		if ((i == LLONG_MIN || i == LLONG_MAX) && errno == ERANGE) {
			if (([(__bridge id)ctx parserOptions] & YAJLParserOptionsStrictPrecision) == YAJLParserOptionsStrictPrecision) {
				NSString *s = [[NSString alloc] initWithBytes:numberVal length:numberLen encoding:NSUTF8StringEncoding];
				[(__bridge id)ctx _cancelWithErrorForStatus:YAJLParserErrorCodeIntegerOverflow message:[NSString stringWithFormat:@"integer overflow on '%@'", s] value:s];
				return 0;
			} else {
				// If we integer overflow lets try double precision for HUGE_VAL > double > LLONG_MAX
				return ParseDouble(ctx, buf, numberVal, numberLen);
			}
		}
		NSNumber *number = [[NSNumber alloc] initWithLongLong:i];
		[(__bridge id)ctx _add:number];
	}
	
	return 1;
}

int yajl_string(void *ctx, const unsigned char *stringVal, size_t stringLen) {
	NSString *s = [[NSString alloc] initWithBytes:stringVal length:stringLen encoding:NSUTF8StringEncoding];
	[(__bridge id)ctx _add:s];
	return 1;
}

int yajl_map_key(void *ctx, const unsigned char *stringVal, size_t stringLen) {
	NSString *s = [[NSString alloc] initWithBytes:stringVal length:stringLen encoding:NSUTF8StringEncoding];
	[(__bridge id)ctx _mapKey:s];
	return 1;
}

int yajl_start_map(void *ctx) {
	[(__bridge id)ctx _startDictionary];
	return 1;
}

int yajl_end_map(void *ctx) {
	[(__bridge id)ctx _endDictionary];
	return 1;
}

int yajl_start_array(void *ctx) {
	[(__bridge id)ctx _startArray];
	return 1;
}

int yajl_end_array(void *ctx) {
	[(__bridge id)ctx _endArray];
	return 1;
}

static yajl_callbacks callbacks = {
	yajl_null,
	yajl_boolean,
	NULL, // yajl_integer (using yajl_number)
	NULL, // yajl_double (using yajl_number)
	yajl_number,
	yajl_string,
	yajl_start_map,
	yajl_map_key,
	yajl_end_map,
	yajl_start_array,
	yajl_end_array
};

#pragma mark -

//! @internal

- (void)_add:(id)value {
	[_delegate parser:self didAdd:value];
}

- (void)_mapKey:(NSString *)key {
	[_delegate parser:self didMapKey:key];
}

- (void)_startDictionary {
	[_delegate parserDidStartDictionary:self];
}

- (void)_endDictionary {
	[_delegate parserDidEndDictionary:self];
}

- (void)_startArray {
	[_delegate parserDidStartArray:self];
}

- (void)_endArray {
	[_delegate parserDidEndArray:self];
}

//! @endinternal

- (unsigned int)bytesConsumed {
	return _handle ? (unsigned int)yajl_get_bytes_consumed(_handle) : 0;
}

- (YAJLParserStatus)parse:(NSData *)data {
	if (!_handle) {
		_handle = yajl_alloc(&callbacks, NULL, (__bridge void *)(self));
		yajl_config(_handle, yajl_allow_comments, (_parserOptions & YAJLParserOptionsAllowComments) ? 1 : 0);
		yajl_config(_handle, yajl_dont_validate_strings, (_parserOptions & YAJLParserOptionsCheckUTF8) ? 1 : 0);
		
		if (!_handle) {
			self.parserError = [self _errorForStatus:YAJLParserErrorCodeAllocError message:@"Unable to allocate YAJL handle" value:nil];
			return YAJLParserStatusError;
		}
	}
	
	yajl_status status = yajl_parse(_handle, data.bytes, (unsigned int) data.length);
	if (status == yajl_status_client_canceled) {
		// We cancelled because we encountered an error here in the client;
		// and parserError should be already set
		NSAssert(self.parserError, @"Client cancelled, but we have no parserError set");
		return YAJLParserStatusError;
	} else if (status == yajl_status_error) {
		unsigned char *errorMessage = yajl_get_error(_handle, 1, data.bytes, (unsigned int) data.length);
        NSString *errorString = [NSString stringWithUTF8String: errorMessage];
		self.parserError = [self _errorForStatus:status message:errorString value:nil];
		yajl_free_error(_handle, errorMessage);
		return YAJLParserStatusError;
	} else if (status == yajl_status_ok) {
		return YAJLParserStatusOK;
	} else {
		self.parserError = [self _errorForStatus:status message:[NSString stringWithFormat:@"Unexpected status %d", status] value:nil];
		return YAJLParserStatusError;
	}
}

@end
