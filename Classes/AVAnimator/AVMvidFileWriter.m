//
//  AVMvidFileWriter.h
//
//  Created by Moses DeJong on 2/20/12.
//
//  License terms defined in License.txt.

#import "AVMvidFileWriter.h"

#define LOGGING

#ifndef __OPTIMIZE__
// Automatically define EXTRA_CHECKS when not optimizing (in debug mode)
# define EXTRA_CHECKS
#endif // DEBUG

#ifdef EXTRA_CHECKS
#define ALWAYS_GENERATE_ADLER
#endif // EXTRA_CHECKS

@implementation AVMvidFileWriter

@synthesize mvidPath = m_mvidPath;
@synthesize frameDuration = m_frameDuration;
@synthesize totalNumFrames = m_totalNumFrames;
@synthesize frameNum = frameNum;
@synthesize bpp = m_bpp;
@synthesize genAdler = m_genAdler;
@synthesize movieSize = m_movieSize;

- (void) close
{
  if (maxvidOutFile) {
    fclose(maxvidOutFile);
    maxvidOutFile = NULL;
  }
}

- (void) dealloc
{
  if (maxvidOutFile) {
    [self close];
  }
  
  if (mvHeader) {
    free(mvHeader);
    mvHeader = NULL;
  }
    
  if (mvFramesArray) {
    free(mvFramesArray);
    mvFramesArray = NULL;
  }
    
  self.mvidPath = nil;
  [super dealloc];
}

- (BOOL) openMvid
{
#ifdef ALWAYS_GENERATE_ADLER
  const int genAdler = 1;
#else  // ALWAYS_GENERATE_ADLER
  const int genAdler = 0;
#endif // ALWAYS_GENERATE_ADLER
  
  if (genAdler) {
    self.genAdler = TRUE;
  }
  
  char *mvidStr = (char*)[self.mvidPath UTF8String];
  
  maxvidOutFile = fopen(mvidStr, "wb");
  
  if (maxvidOutFile == NULL) {
    return FALSE;
  }
  
  mvHeader = malloc(sizeof(MVFileHeader));
  if (mvHeader == NULL) {
    return FALSE;
  }
  memset(mvHeader, 0, sizeof(MVFileHeader));

  // Write zeroed file header
  
  int numWritten = 0;
  
  numWritten = fwrite(mvHeader, sizeof(MVFileHeader), 1, maxvidOutFile);
  if (numWritten != 1) {
    return FALSE;
  }
  
  // Write zeroed frames header
  
  int numOutputFrames = self.totalNumFrames;
  
  framesArrayNumBytes = sizeof(MVFrame) * numOutputFrames;
  mvFramesArray = malloc(framesArrayNumBytes);
  if (mvFramesArray == NULL) {
    return FALSE;
  }
  memset(mvFramesArray, 0, framesArrayNumBytes);
  
  numWritten = fwrite(mvFramesArray, framesArrayNumBytes, 1, maxvidOutFile);
  if (numWritten != 1) {
    return FALSE;
  }
  
  return TRUE;
}

- (void) writeTrailingNopFrames:(float)currentFrameDuration
{  
  int numFramesDelay = round(currentFrameDuration / self.frameDuration);
  
  if (numFramesDelay > 1) {
    for (int count = numFramesDelay; count > 1; count--) {
      
#ifdef LOGGING
      NSLog(@"WRITTING nop frame %d", frameNum);
#endif // LOGGING
      
      NSAssert(frameNum < self.totalNumFrames, @"totalNumFrames");
      
      MVFrame *mvFrame = &mvFramesArray[frameNum];
      MVFrame *prevMvFrame = &mvFramesArray[frameNum-1];
      
      maxvid_frame_setoffset(mvFrame, maxvid_frame_offset(prevMvFrame));
      maxvid_frame_setlength(mvFrame, maxvid_frame_length(prevMvFrame));
      maxvid_frame_setnopframe(mvFrame);
      
      if (maxvid_frame_iskeyframe(prevMvFrame)) {
        maxvid_frame_setkeyframe(mvFrame);
      }
      
      frameNum++;
    }
  }
}

// Store the current file offset

- (void) saveOffset
{
  offset = ftell(maxvidOutFile);
}

// Advance the file offset to the start of the next page in memory.
// This method assumes that the offset was saved with an earlier call
// to saveOffset

- (void) skipToNextPageBound
{
  offset = maxvid_file_padding_before_keyframe(maxvidOutFile, offset);
 
  NSAssert(frameNum < self.totalNumFrames, @"totalNumFrames");
  
  MVFrame *mvFrame = &mvFramesArray[frameNum];
  
  maxvid_frame_setoffset(mvFrame, (uint32_t)offset);
  
  maxvid_frame_setkeyframe(mvFrame);
}

- (BOOL) writeKeyframe:(char*)ptr bufferSize:(int)bufferSize
{
  [self skipToNextPageBound];
  
  int numWritten = fwrite(ptr, bufferSize, 1, maxvidOutFile);
  
  if (numWritten != 1) {
    return FALSE;
  } else {
    // Finish emitting frame data
    
    uint32_t offsetBefore = (uint32_t)offset;
    offset = ftell(maxvidOutFile);
    uint32_t length = ((uint32_t)offset) - offsetBefore;
    
    NSAssert((length % 2) == 0, @"offset length must be even");
    assert((length % 4) == 0); // must be in terms of whole words
    
    NSAssert(frameNum < self.totalNumFrames, @"totalNumFrames");
    
    MVFrame *mvFrame = &mvFramesArray[frameNum];
    
    maxvid_frame_setlength(mvFrame, length);
    
    // Generate adler32 for pixel data and save into frame data
    
    if (self.genAdler) {
      mvFrame->adler = maxvid_adler32(0, (unsigned char*)ptr, bufferSize);
      assert(mvFrame->adler != 0);
      
#ifdef LOGGING
      NSLog(@"WROTE adler %d", mvFrame->adler);
#endif // LOGGING
    }
    
    // zero pad to next page bound
    
    offset = maxvid_file_padding_after_keyframe(maxvidOutFile, offset);
    assert(offset > 0); // silence compiler/analyzer warning
    
    frameNum += 1;
    
    return TRUE;
  }
}

- (BOOL) rewriteHeader
{
  mvHeader->magic = 0; // magic still not valid
  mvHeader->width = self.movieSize.width;
  mvHeader->height = self.movieSize.height;
  mvHeader->bpp = self.bpp;
  
  mvHeader->frameDuration = self.frameDuration;
  assert(mvHeader->frameDuration > 0.0);
  
  mvHeader->numFrames = self.totalNumFrames;
  
  (void)fseek(maxvidOutFile, 0L, SEEK_SET);
  
  int numWritten = fwrite(mvHeader, sizeof(MVFileHeader), 1, maxvidOutFile);
  if (numWritten != 1) {
    return FALSE;
  }
  
  numWritten = fwrite(mvFramesArray, framesArrayNumBytes, 1, maxvidOutFile);
  if (numWritten != 1) {
    return FALSE;
  }  
  
  // Once all valid data and headers have been written, it is now safe to write the
  // file header magic number. This ensures that any threads reading the first word
  // of the file looking for a valid magic number will only ever get consistent
  // data in a read when a valid magic number is read.
  
  (void)fseek(maxvidOutFile, 0L, SEEK_SET);
  
  uint32_t magic = MV_FILE_MAGIC;
  numWritten = fwrite(&magic, sizeof(uint32_t), 1, maxvidOutFile);
  if (numWritten != 1) {
    return FALSE;
  }
  
  return TRUE;
}

@end
