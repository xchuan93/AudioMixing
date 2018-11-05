//
//  AudioMixing.h
//  ffmpeg
//
//  Created by Apple on 2018/10/31.
//  Copyright © 2018年 XC. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface AudioMixing : NSObject
+(void)ffmpegAudioMixing:(NSString*)inFilePathOne inFilePathTwo:(NSString *)inFilePathTwo outFilePath:(NSString*)outFilePath;
@end
