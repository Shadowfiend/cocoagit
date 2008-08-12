//
//  GITPackFile.m
//  CocoaGit
//
//  Created by Geoffrey Garside on 05/08/2008.
//  Copyright 2008 ManicPanda.com. All rights reserved.
//

#import "GITPackFile.h"

//            Name of Range                 Start   Length
const NSRange kGITPackFileSignatureRange = {     0,      4 };
const NSRange kGITPackFileVersionRange   = {     4,      4 };
const NSRange kGITPackFileNumberRange    = {     8,      4 };

const NSUInteger kGITPackIndexFanOutSize  = 4;      // bytes
const NSUInteger kGITPackIndexFanOutCount = 256;
const NSUInteger kGITPackIndexFanOutEnd   = kGITPackIndexFanOutSize * kGITPackIndexFanOutCount;
const NSUInteger kGITPackIndexEntrySize   = 24;     // bytes

@interface GITPackFile ()
@property(readwrite,retain) GITRepo * repo;
@property(readwrite,copy)   NSString * idxPath;
@property(readwrite,copy)   NSString * packPath;
@property(readwrite,copy)   NSArray  * idxOffsets;
@property(readwrite,assign) NSUInteger idxVersion;
@property(readwrite,assign) NSUInteger packVersion;
@property(readwrite,assign) NSUInteger numberOfObjects;
@end

@implementation GITPackFile

@synthesize repo;
@synthesize idxPath;
@synthesize packPath;
@synthesize idxOffsets;
@synthesize idxVersion;
@synthesize packVersion;
@synthesize numberOfObjects;

- (id)initWithPath:(NSString*)path
{
    if (self = [super init])
    {
        self.idxPath = path;
        self.packPath = path;
    }
}
- (void)setPackPath:(NSString*)thePath
{
    if (thePath != packPath)
    {
        [packPath release];
        packPath = [[thePath stringByDeletingPathExtension] 
            stringByAppendingPathExtension:@"pack"];
    }
}
- (void)setIdxPath:(NSString*)thePath
{
    if (thePath != idxPath)
    {
        [idxPath release];
        idxPath = [[thePath stringByDeletingPathExtension] 
            stringByAppendingPathExtension:@"idx"];
    }
}
- (void)readPack
{
    NSError * err;
    NSData * pack = [NSData dataWithContentsOfFile:self.packPath
                                           options:NSUncachedRead
                                             error:&err];
    
    unichar buf[4];
    [pack getBytes:buf range:kGITPackFileSignatureRange];
    if ([[NSString stringWithCharacters:buf length:4] isEqualToString:@"PACK"])
    {   // Its a valid PACK file, continue
        [pack getBytes:buf range:kGITPackFileVersionRange];
        self.version = [self integerFromBytes:buf length:4];
        
        if (self.version == 2)
            [self readVersion2:pack];
    }
}
- (void)readPackVersion2:(NSData*)pack
{
    unichar buf[4];
    [pack getBytes:buf range:kGITPackFileNumberRange];
    
    self.numberOfObjects = [self integerFromBytes:buf length:4];
    
    
}
- (void)readIdx
{
    NSError * err;
    NSData * idx = [NSData dataWithContentsOfFile:self.idxPath
                                          options:NSUncachedRead
                                            error:&err];
    unichar buf[4];
    NSUInteger i, lastCount, thisCount;
    NSMutableArray * offsets = [NSMutableArray arrayWithCapacity:256];

    lastCount = thisCount = 0;
    [offsets addObject:[NSNumber numberWithUnsignedInteger:0]];  // Fill in \0 char count

    // The Fanout table
    // The fanout table consists of 256 entries. These
    // entries correspond to the first byte of an object
    // sha1. The value at each entry is the number of
    // object sha1's in the corresponding PACK file
    // in which the first byte is less than or equal
    // to the entry index. This also applies to the
    // list of SHA1 entries in the IDX file as well.
    // The value of each entry should be greater than
    // or equal to the previous value, if it is not 
    // then the index file is corrupt.
    // At the moment I am not sure if the fan out
    // entry index corresponds to the compressed or
    // uncompressed SHA1 hash value.
    for (i = 0; i < kGITPackIndexFanOutCount; i++)
    {
        [idx getBytes:buf range:NSMakeRange(i * kGITPackIndexFanOutSize, kGITPackIndexFanOutSize)];
        thisCount = [self integerFromBytes:buf length:kGITPackIndexFanOutSize];

        // Assuming an NSUInteger is less expensive than calling
        // [[idxOffsets objectAtIndex:i - 1] unsignedIntegerValue]
        if (lastCount > thisCount)
        {
            NSString * reason = [NSString stringWithFormat:@"IDX %@ is corrupt", [self.idxPath lastPathComponent]];
            NSException * ex  = [NSException exceptionWithName:@"GITPackFileCorruptIndexException"
                                                        reason:reason
                                                      userInfo:nil];
            @throw ex;
        }

        [offsets addObject:[NSNumber numberWithUnsignedInteger:thisCount]];
        lastCount = thisCount;
    }

    self.numberOfObjects = thisCount;   // The value of the last offset
    self.idxOffsets = offsets;
}
- (NSUInteger)integerFromBytes:(unichar*)bytes length:(NSUInteger)length
{
    NSUInteger i, value = 0;
    for (i = 0; i <= length; i++)
        value = (value << 4) | bytes[i];
    return value;
}
- (NSUInteger)offsetForSha1:(NSString*)sha1
{
    unichar firstByte = [sha1 characterAtIndex:0];
    NSUInteger thisFanout, prevFanout = 0;
    
    // prevFanout = number of objects with firstByte less than that of sha1
    // thisFanout = number of objects with firstByte less than or equal to that of sha1
    // fanoutDiff = number of objects with firstByte equal to that of sha1
    thisFanout = [[self.idxOffsets objectAtIndex:firstByte] unsignedIntegerValue];
    if (firstByte != 0x0)
        prevFanout = [[self.idxOffsets objectAtIndex:firstByte - 1] unsignedIntegerValue];

    // There are entries to examine
    if (thisFanout > prevFanout)
    {
        NSUInteger i;
        unichar buf[20];

        NSUInteger startLocation = kGITPackIndexFanOutEnd +
            (kGITPackIndexEntrySize * prevFanout);
        NSUInteger endLocation   = kGITPackIndexFanOutEnd +
            (kGITPackIndexEntrySize * thisFanout);
        
        for (i = startLocation; i < endLocation; i += kGITPackIndexEntrySize)
        {
            memset(buf, 0x0, 20);
            [data getBytes:buf range:NSMakeRange(i, 4)];
            NSUInteger offset = [self integerFromBytes:buf length:4];

            memset(buf, 0x0, 20);
            [data getBytes:buf range:NSMakeRange(i + 4, 20)];
            NSString * name = [NSString stringWithCharacters:buf length:20];

            if ([name isEqualToString:sha1])
                return offset;
        }
    }

    // If its found the SHA1 then it will have returned by now.
    // Otherwise the SHA1 is not in this PACK file, so we should
    // raise an error.
    NSString * reason = [NSString stringWithFormat:@"SHA1 %@ is not known in this PACK %@",
                         sha1, [self.idxPath lastPathComponent]];
    NSException * ex  = [NSException exceptionWithName:@"GITPackFileUnknownSHA1"
                                                reason:reason
                                              userInfo:nil];
    @throw ex;
}

@end