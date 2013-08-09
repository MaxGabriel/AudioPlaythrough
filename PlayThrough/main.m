//
//  main.m
//  Recorder
//
//  Created by Maximilian Tagher on 8/7/13.
//  Copyright (c) 2013 Tagher. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

#define kNumberRecordBuffers 3

#define kNumberPlaybackBuffers 3

#define kPlaybackFileLocation CFSTR("/Users/Max/Music/iTunes/iTunes Media/Music/Taylor Swift/Red/02 Red.m4a")

#pragma mark - User Data Struct
// listing 4.3
typedef struct MyRecorder {
    AudioFileID recordFile;
    SInt64      recordPacket;
    Boolean     running;
} MyRecorder;

typedef struct MyPlayer {
    AudioFileID playbackFile;
    SInt64 packetPosition;
    UInt32 numPacketsToRead;
    AudioStreamPacketDescription *packetDescs;
    Boolean isDone;
} MyPlayer;

#pragma mark - Utility functions

// Listing 4.2
static void CheckError(OSStatus error, const char *operation) {
    if (error == noErr) return;
    
    char errorString[20];
    // See if it appears to be a 4-char-code
    *(UInt32 *)(errorString + 1) = CFSwapInt32HostToBig(error);
    if (isprint(errorString[1]) && isprint(errorString[2])
        && isprint(errorString[3]) && isprint(errorString[4])) {
        errorString[0] = errorString[5] = '\'';
        errorString[6] = '\0';
    } else {
        // No, format it as an integer
        sprintf(errorString, "%d",(int)error);
    }
    
    fprintf(stderr, "Error: %s (%s)\n",operation,errorString);
    
    exit(1);
}

OSStatus MyGetDefaultInputDeviceSampleRate(Float64 *outSampleRate)
{
    OSStatus error;
    AudioDeviceID deviceID = 0;
    
    AudioObjectPropertyAddress propertyAddress;
    UInt32 propertySize;
    propertyAddress.mSelector = kAudioHardwarePropertyDefaultInputDevice;
    propertyAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propertyAddress.mElement = 0;
    propertySize = sizeof(AudioDeviceID);
    error = AudioHardwareServiceGetPropertyData(kAudioObjectSystemObject,
                                                &propertyAddress, 0, NULL,
                                                &propertySize,
                                                &deviceID);
    
    if (error) return error;
    
    propertyAddress.mSelector = kAudioDevicePropertyNominalSampleRate;
    propertyAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propertyAddress.mElement = 0;
    
    propertySize = sizeof(Float64);
    error = AudioHardwareServiceGetPropertyData(deviceID,
                                                &propertyAddress, 0, NULL,
                                                &propertySize,
                                                outSampleRate);
    return error;
}

// Recorder
static void MyCopyEncoderCookieToFile(AudioQueueRef queue, AudioFileID theFile)
{
    OSStatus error;
    UInt32 propertySize;
    error = AudioQueueGetPropertySize(queue, kAudioConverterCompressionMagicCookie, &propertySize);
    
    if (error == noErr && propertySize > 0) {
        Byte *magicCookie = (Byte *)malloc(propertySize);
        CheckError(AudioQueueGetProperty(queue, kAudioQueueProperty_MagicCookie, magicCookie, &propertySize), "Couldn't get audio queue's magic cookie");
        
        CheckError(AudioFileSetProperty(theFile, kAudioFilePropertyMagicCookieData, propertySize, magicCookie), "Couldn't set audio file's magic cookie");
        
        free(magicCookie);
    }
}

// Player
static void MyCopyEncoderCookieToQueue(AudioFileID theFile, AudioQueueRef queue)
{
    UInt32 propertySize;
    // Just check for presence of cookie
    OSStatus result = AudioFileGetProperty(theFile, kAudioFilePropertyMagicCookieData, &propertySize, NULL);
    
    if (result == noErr && propertySize != 0) {
        Byte *magicCookie = (UInt8*)malloc(sizeof(UInt8) * propertySize);
        CheckError(AudioFileGetProperty(theFile, kAudioFilePropertyMagicCookieData, &propertySize, magicCookie), "Get cookie from file failed");
        
        CheckError(AudioQueueSetProperty(queue, kAudioQueueProperty_MagicCookie, magicCookie, propertySize), "Set cookie on file failed");
        
        free(magicCookie);
    }
}

static int MyComputeRecordBufferSize(const AudioStreamBasicDescription *format, AudioQueueRef queue, float seconds)
{
    int packets, frames, bytes;
    
    frames = (int)ceil(seconds * format->mSampleRate);
    
    if (format->mBytesPerFrame > 0) { // Not variable
        bytes = frames * format->mBytesPerFrame;
    } else { // variable bytes per frame
        UInt32 maxPacketSize;
        if (format->mBytesPerPacket > 0) {
            // Constant packet size
            maxPacketSize = format->mBytesPerPacket;
        } else {
            // Get the largest single packet size possible
            UInt32 propertySize = sizeof(maxPacketSize);
            CheckError(AudioQueueGetProperty(queue, kAudioConverterPropertyMaximumOutputPacketSize, &maxPacketSize, &propertySize), "Couldn't get queue's maximum output packet size");
        }
        
        if (format->mFramesPerPacket > 0) {
            packets = frames / format->mFramesPerPacket;
        } else {
            // Worst case scenario: 1 frame in a packet
            packets = frames;
        }
        
        // Sanity check
        
        if (packets == 0) {
            packets = 1;
        }
        bytes = packets * maxPacketSize;
        
    }
    
    return bytes;
}

// Player
// Not sure how this will work -- hopefully just use CBR?
void CalculateBytesForTime(AudioFileID inAudioFile,
                           AudioStreamBasicDescription inDesc,
                           Float64 inSeconds,
                           UInt32 *outBufferSize,
                           UInt32 *outNumPackets)
{
    UInt32 maxPacketSize;
    UInt32 propSize = sizeof(maxPacketSize);
    CheckError(AudioFileGetProperty(inAudioFile,
                                    kAudioFilePropertyPacketSizeUpperBound,
                                    &propSize, &maxPacketSize), "Couldn't get file's max packet size");
    
    static const int maxBufferSize = 0x10000;
    static const int minBufferSize = 0x4000;
    
    if (inDesc.mFramesPerPacket) {
        Float64 numPacketsForTime = inDesc.mSampleRate / inDesc.mFramesPerPacket * inSeconds;
        *outBufferSize = numPacketsForTime * maxPacketSize;
    } else {
        *outBufferSize = maxBufferSize > maxPacketSize ? maxBufferSize : maxPacketSize;
    }
    
    if (*outBufferSize > maxBufferSize &&
        *outBufferSize > maxPacketSize) {
        *outBufferSize = maxBufferSize;
    } else {
        if (*outBufferSize < minBufferSize) {
            *outBufferSize = minBufferSize;
        }
    }
    *outNumPackets = *outBufferSize / maxPacketSize;
}


#pragma mark - Record callback function

static void MyAQInputCallback(void *inUserData,
                              AudioQueueRef inQueue,
                              AudioQueueBufferRef inBuffer,
                              const AudioTimeStamp *inStartTime,
                              UInt32 inNumPackets,
                              const AudioStreamPacketDescription *inPacketDesc)
{
    MyRecorder *recorder = (MyRecorder *)inUserData;
    
    if (inNumPackets > 0) {
        // Write packets to a file
        CheckError(AudioFileWritePackets(recorder->recordFile, FALSE, inBuffer->mAudioDataByteSize, inPacketDesc, recorder->recordPacket, &inNumPackets, inBuffer->mAudioData), "AudioFileWritePackets failed");
        
        // Increment the packet index
        recorder->recordPacket += inNumPackets;
    }
    
    if (recorder->running) {
        CheckError(AudioQueueEnqueueBuffer(inQueue, inBuffer, 0, NULL), "AudioQueueEnqueueBuffer failed");
    }
}

static void MyAQOutputCallback(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inCompleteAQBuffer)
{
    MyPlayer *aqp = (MyPlayer *)inUserData;
    if (aqp->isDone) return;
    
    UInt32 numBytes;
    UInt32 nPackets = aqp->numPacketsToRead;
    CheckError(AudioFileReadPackets(aqp->playbackFile, false,
                                    &numBytes,
                                    aqp->packetDescs,
                                    aqp->packetPosition,
                                    &nPackets,
                                    inCompleteAQBuffer->mAudioData), "AudioFileReadPackets failed");
    
    
    if (nPackets > 0) {
        inCompleteAQBuffer->mAudioDataByteSize = numBytes;
        AudioQueueEnqueueBuffer(inAQ, inCompleteAQBuffer, (aqp->packetDescs ? nPackets : 0), aqp->packetDescs);
        aqp->packetPosition += nPackets;
    } else {
        CheckError(AudioQueueStop(inAQ, false), "AudioQueueStop failed");
        aqp->isDone = true;
    }
}
/*
int main(int argc, const char * argv[])
{
    
    @autoreleasepool {
        MyRecorder recorder = {0};
        AudioStreamBasicDescription recordFormat;
        memset(&recordFormat, 0, sizeof(recordFormat));
        
        recordFormat.mFormatID = kAudioFormatAppleLossless;
        recordFormat.mChannelsPerFrame = 2; //stereo
        
        MyGetDefaultInputDeviceSampleRate(&recordFormat.mSampleRate);
        
        
        UInt32 propSize = sizeof(recordFormat);
        CheckError(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo,
                                          0,
                                          NULL,
                                          &propSize,
                                          &recordFormat), "AudioFormatGetProperty failed");
        
        
        AudioQueueRef queue = {0};
        
        CheckError(AudioQueueNewInput(&recordFormat, MyAQInputCallback, &recorder, NULL, NULL, 0, &queue), "AudioQueueNewInput failed");
        
        // Fills in ABSD a little more
        UInt32 size = sizeof(recordFormat);
        CheckError(AudioQueueGetProperty(queue,
                                         kAudioConverterCurrentOutputStreamDescription,
                                         &recordFormat,
                                         &size), "Couldn't get queue's format");
        
        CFURLRef myFileURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
                                                           CFSTR("output.caf"), kCFURLPOSIXPathStyle, false);
        CheckError(AudioFileCreateWithURL(myFileURL, kAudioFileCAFType,
                                          &recordFormat,
                                          kAudioFileFlags_EraseFile,
                                          &recorder.recordFile), "AudioFileCreateWithURL failed");
        CFRelease(myFileURL);
        
        MyCopyEncoderCookieToFile(queue, recorder.recordFile);
        
        int bufferByteSize = MyComputeRecordBufferSize(&recordFormat,queue,0.5);
        
        // Create and Enqueue buffers
        int bufferIndex;
        for (bufferIndex = 0;
             bufferIndex < kNumberRecordBuffers;
             ++bufferIndex) {
            AudioQueueBufferRef buffer;
            CheckError(AudioQueueAllocateBuffer(queue,
                                                bufferByteSize,
                                                &buffer), "AudioQueueBufferRef failed");
            CheckError(AudioQueueEnqueueBuffer(queue, buffer, 0, NULL), "AudioQueueEnqueueBuffer failed");
        }
        
        recorder.running = TRUE;
        CheckError(AudioQueueStart(queue, NULL), "AudioQueueStart failed");
        
        printf("Recordering, press <return> to stop:\n");
        getchar();
        
        printf("* recording done *\n");
        recorder.running = FALSE;
        
        CheckError(AudioQueueStop(queue, TRUE), "AudioQueueStop failed");
        
        MyCopyEncoderCookieToFile(queue, recorder.recordFile);
        
        AudioQueueDispose(queue, TRUE);
        AudioFileClose(recorder.recordFile);
    }
    return 0;
}
*/
int main(int argc, const char * argv[])
{
    
    @autoreleasepool {
        // Open an audio file
        MyPlayer player = {0};
        
        CFURLRef myFileURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
                                                           kPlaybackFileLocation, kCFURLPOSIXPathStyle, false);
        CheckError(AudioFileOpenURL(myFileURL, kAudioFileReadPermission, 0, &player.playbackFile), "AudioFileOpenURL failed");
        CFRelease(myFileURL);
        
        // Set up format
        AudioStreamBasicDescription dataFormat;
        UInt32 propSize = sizeof(dataFormat);
        CheckError(AudioFileGetProperty(player.playbackFile, kAudioFilePropertyDataFormat, &propSize, &dataFormat), "Couldn't get file's data format");
        
        // Set up Queue
        AudioQueueRef queue;
        CheckError(AudioQueueNewOutput(&dataFormat,
                                       MyAQOutputCallback,
                                       &player, NULL, NULL, 0,
                                       &queue), "AudioOutputNewQueue failed");
        
        UInt32 bufferByteSize;
        CalculateBytesForTime(player.playbackFile, dataFormat, 0.1, &bufferByteSize,&player.numPacketsToRead);
        
        bool isFormatVBR = (dataFormat.mBytesPerPacket == 0
                            || dataFormat.mFramesPerPacket == 0);
        if (isFormatVBR) {
            player.packetDescs = (AudioStreamPacketDescription*) malloc(sizeof(AudioStreamPacketDescription) * player.numPacketsToRead);
        } else {
            player.packetDescs = NULL;
        }
        
        MyCopyEncoderCookieToQueue(player.playbackFile, queue);
        
        
        // Player will start immediately, so we need to fill it with some data so that it doesn't play silence into the file
        // Call the callback function manually to solve
        
        AudioQueueBufferRef buffers[kNumberPlaybackBuffers];
        player.isDone = false;
        player.packetPosition = 0;
        for (int i=0; i<kNumberPlaybackBuffers; i++) {
            CheckError(AudioQueueAllocateBuffer(queue,
                                                bufferByteSize,
                                                &buffers[i]), "AudioQueueAllocateBuffer failed");
            MyAQOutputCallback(&player, queue, buffers[i]);
            
            if (player.isDone) {
                break;
            }
        }
        
        // Start Queue
        CheckError(AudioQueueStart(queue, NULL), "AudioQueueStart failed");
        
        printf("Playing...\n");
        
        do {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
        } while (!player.isDone);
        
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 2, false); // Handle any audio that may remain in buffers
        
        // Clean up queue when finished
        player.isDone = true;
        CheckError(AudioQueueStop(queue, TRUE), "AudioQueueStop failed");
        AudioFileClose(player.playbackFile);
        
    }
    return 0;
}

