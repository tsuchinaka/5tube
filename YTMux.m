#import "YTMux.h"
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <stdint.h>

typedef struct {
    uint32_t duration;
    uint32_t size;
    uint32_t flags;
    int32_t cto;
    long src;
} YTSample;

typedef struct {
    uint32_t timescale;
    uint32_t width;
    uint32_t height;
    uint8_t *entry;
    uint32_t entryLen;
    uint32_t defaultDuration;
    YTSample *samples;
    uint32_t count;
    uint32_t cap;
} YTTrack;

static uint32_t YTBe32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static int32_t YTBeS32(const uint8_t *p) {
    return (int32_t)YTBe32(p);
}

static const uint8_t *YTBox(const uint8_t *buf, uint32_t len, const char *type, uint32_t *size) {
    uint32_t i = 0;
    while (i + 8 <= len) {
        uint32_t box = YTBe32(buf + i);
        if (box < 8 || i + box > len) return NULL;
        if (memcmp(buf + i + 4, type, 4) == 0) {
            if (size) *size = box;
            return buf + i;
        }
        i += box;
    }
    return NULL;
}

static int YTAddSample(YTTrack *track, YTSample sample) {
    if (track->count == track->cap) {
        uint32_t cap = track->cap ? track->cap * 2 : 256;
        YTSample *next = realloc(track->samples, cap * sizeof(YTSample));
        if (!next) return 0;
        track->samples = next;
        track->cap = cap;
    }
    track->samples[track->count++] = sample;
    return 1;
}

static void YTFreeTrack(YTTrack *track) {
    free(track->entry);
    free(track->samples);
    memset(track, 0, sizeof(*track));
}

static int YTParseMoov(const uint8_t *moov, uint32_t moovLen, YTTrack *track) {
    uint32_t size = 0;
    const uint8_t *trak = YTBox(moov + 8, moovLen - 8, "trak", &size);
    if (!trak) return 0;
    const uint8_t *tkhd = YTBox(trak + 8, size - 8, "tkhd", NULL);
    if (tkhd) {
        uint32_t tkhdLen = YTBe32(tkhd);
        if (tkhdLen >= 16) {
            track->width = YTBe32(tkhd + tkhdLen - 8) >> 16;
            track->height = YTBe32(tkhd + tkhdLen - 4) >> 16;
        }
    }
    const uint8_t *mdia = YTBox(trak + 8, size - 8, "mdia", &size);
    if (!mdia) return 0;
    const uint8_t *mdhd = YTBox(mdia + 8, size - 8, "mdhd", NULL);
    if (!mdhd || YTBe32(mdhd) < 20 || mdhd[8] != 0) return 0;
    track->timescale = YTBe32(mdhd + 8 + 12);
    const uint8_t *minf = YTBox(mdia + 8, size - 8, "minf", &size);
    if (!minf) return 0;
    const uint8_t *stbl = YTBox(minf + 8, size - 8, "stbl", &size);
    if (!stbl) return 0;
    const uint8_t *stsd = YTBox(stbl + 8, size - 8, "stsd", NULL);
    if (!stsd) return 0;
    uint32_t stsdLen = YTBe32(stsd);
    if (stsdLen < 24) return 0;
    const uint8_t *entry = stsd + 16;
    uint32_t entryLen = YTBe32(entry);
    if (entryLen < 8 || 16 + entryLen > stsdLen) return 0;
    track->entry = malloc(entryLen);
    if (!track->entry) return 0;
    memcpy(track->entry, entry, entryLen);
    track->entryLen = entryLen;
    return track->timescale > 0;
}

static int YTParseMoof(const uint8_t *moof, uint32_t moofLen, long moofPos, YTTrack *track) {
    uint32_t trafSize = 0;
    const uint8_t *traf = YTBox(moof + 8, moofLen - 8, "traf", &trafSize);
    if (!traf) return 0;
    const uint8_t *tfhd = YTBox(traf + 8, trafSize - 8, "tfhd", NULL);
    const uint8_t *trun = YTBox(traf + 8, trafSize - 8, "trun", NULL);
    if (!tfhd || !trun) return 0;
    uint32_t tfhdLen = YTBe32(tfhd);
    uint32_t flags = YTBe32(tfhd + 8) & 0xffffff;
    const uint8_t *p = tfhd + 12;
    const uint8_t *end = tfhd + tfhdLen;
    if (p + 4 > end) return 0;
    p += 4;
    if (flags & 0x1) p += 8;
    if (flags & 0x2) p += 4;
    uint32_t defaultDuration = track->defaultDuration;
    if (flags & 0x8) {
        if (p + 4 > end) return 0;
        defaultDuration = YTBe32(p);
        p += 4;
    }
    if (defaultDuration) track->defaultDuration = defaultDuration;
    uint32_t trunLen = YTBe32(trun);
    uint32_t trunFlags = YTBe32(trun + 8) & 0xffffff;
    if (trunLen < 16) return 0;
    uint32_t count = YTBe32(trun + 12);
    p = trun + 16;
    end = trun + trunLen;
    int32_t dataOffset = 0;
    if (trunFlags & 0x1) {
        if (p + 4 > end) return 0;
        dataOffset = YTBeS32(p);
        p += 4;
    }
    if (trunFlags & 0x4) p += 4;
    if (flags & 0x1) return 0;
    long base = (flags & 0x20000) ? moofPos : 0;
    long cursor = base + dataOffset;
    uint32_t i;
    for (i = 0; i < count; i++) {
        YTSample sample;
        sample.duration = (trunFlags & 0x100) ? 0 : defaultDuration;
        sample.size = 0;
        sample.flags = 0;
        sample.cto = 0;
        if (trunFlags & 0x100) {
            if (p + 4 > end) return 0;
            sample.duration = YTBe32(p);
            p += 4;
        }
        if (trunFlags & 0x200) {
            if (p + 4 > end) return 0;
            sample.size = YTBe32(p);
            p += 4;
        }
        if (trunFlags & 0x400) {
            if (p + 4 > end) return 0;
            sample.flags = YTBe32(p);
            p += 4;
        }
        if (trunFlags & 0x800) {
            if (p + 4 > end) return 0;
            sample.cto = YTBeS32(p);
            p += 4;
        }
        if (!sample.duration || !sample.size) return 0;
        sample.src = cursor;
        cursor += sample.size;
        if (!YTAddSample(track, sample)) return 0;
    }
    return 1;
}

static int YTParseFile(NSString *path, YTTrack *track) {
    FILE *file = fopen([path fileSystemRepresentation], "rb");
    if (!file) return 0;
    int ok = 1;
    while (ok) {
        uint8_t header[8];
        long pos = ftell(file);
        if (fread(header, 1, 8, file) != 8) break;
        uint32_t size = YTBe32(header);
        if (size < 8) { ok = 0; break; }
        if (memcmp(header + 4, "moov", 4) == 0) {
            uint8_t *box = malloc(size);
            if (!box) { ok = 0; break; }
            memcpy(box, header, 8);
            if (fread(box + 8, 1, size - 8, file) != size - 8) { free(box); ok = 0; break; }
            ok = YTParseMoov(box, size, track);
            free(box);
        } else if (memcmp(header + 4, "moof", 4) == 0) {
            if (size > 1024 * 1024) { ok = 0; break; }
            uint8_t *box = malloc(size);
            if (!box) { ok = 0; break; }
            memcpy(box, header, 8);
            if (fread(box + 8, 1, size - 8, file) != size - 8) { free(box); ok = 0; break; }
            ok = YTParseMoof(box, size, pos, track);
            free(box);
        } else {
            if (fseek(file, size - 8, SEEK_CUR) != 0) { ok = 0; break; }
        }
    }
    fclose(file);
    return ok && track->count > 0 && track->entryLen > 0;
}

typedef struct {
    uint8_t *bytes;
    size_t length;
    size_t cap;
} YTBuf;

static int YTGrow(YTBuf *buf, size_t more) {
    if (buf->length + more <= buf->cap) return 1;
    size_t cap = buf->cap ? buf->cap * 2 : 1024;
    while (cap < buf->length + more) cap *= 2;
    uint8_t *next = realloc(buf->bytes, cap);
    if (!next) return 0;
    buf->bytes = next;
    buf->cap = cap;
    return 1;
}

static int YTPut(YTBuf *buf, const void *bytes, size_t length) {
    if (!YTGrow(buf, length)) return 0;
    memcpy(buf->bytes + buf->length, bytes, length);
    buf->length += length;
    return 1;
}

static int YTPut32(YTBuf *buf, uint32_t value) {
    uint8_t b[4] = { value >> 24, value >> 16, value >> 8, value };
    return YTPut(buf, b, 4);
}

static int YTPut16(YTBuf *buf, uint16_t value) {
    uint8_t b[2] = { value >> 8, value };
    return YTPut(buf, b, 2);
}

static size_t YTOpenBox(YTBuf *buf, const char *type) {
    size_t at = buf->length;
    YTPut32(buf, 0);
    YTPut(buf, type, 4);
    return at;
}

static void YTCloseBox(YTBuf *buf, size_t at) {
    uint32_t size = (uint32_t)(buf->length - at);
    buf->bytes[at] = size >> 24;
    buf->bytes[at + 1] = size >> 16;
    buf->bytes[at + 2] = size >> 8;
    buf->bytes[at + 3] = size;
}

static uint32_t YTTrackDuration(YTTrack *track) {
    uint64_t total = 0;
    uint32_t i;
    for (i = 0; i < track->count; i++) total += track->samples[i].duration;
    return total > 0xffffffffu ? 0xffffffffu : (uint32_t)total;
}

static uint64_t YTTrackBytes(YTTrack *track) {
    uint64_t total = 0;
    uint32_t i;
    for (i = 0; i < track->count; i++) total += track->samples[i].size;
    return total;
}

static int YTPutRuns(YTBuf *buf, YTTrack *track, int kind) {
    uint32_t runs = 0;
    uint32_t i;
    uint32_t previous = 0;
    for (i = 0; i < track->count; i++) {
        uint32_t value = kind ? (uint32_t)track->samples[i].cto : track->samples[i].duration;
        if (i == 0 || value != previous) runs++;
        previous = value;
    }
    if (!YTPut32(buf, 0) || !YTPut32(buf, runs)) return 0;
    previous = 0;
    uint32_t count = 0;
    for (i = 0; i <= track->count; i++) {
        uint32_t value = i < track->count ? (kind ? (uint32_t)track->samples[i].cto : track->samples[i].duration) : 0xffffffffu;
        if (i > 0 && value != previous) {
            if (!YTPut32(buf, count) || !YTPut32(buf, previous)) return 0;
            count = 0;
        }
        previous = value;
        count++;
    }
    return 1;
}

static int YTWriteTrack(YTBuf *buf, YTTrack *track, uint32_t trackID, uint32_t movieScale, uint32_t *chunkAt) {
    uint32_t mediaDuration = YTTrackDuration(track);
    uint32_t movieDuration = (uint32_t)((uint64_t)mediaDuration * movieScale / track->timescale);
    size_t trak = YTOpenBox(buf, "trak");
    size_t tkhd = YTOpenBox(buf, "tkhd");
    if (!YTPut32(buf, 3) || !YTPut32(buf, 0) || !YTPut32(buf, 0) || !YTPut32(buf, trackID) || !YTPut32(buf, 0) || !YTPut32(buf, movieDuration)) return 0;
    if (!YTPut32(buf, 0) || !YTPut32(buf, 0) || !YTPut16(buf, 0) || !YTPut16(buf, 0) || !YTPut16(buf, track->width ? 0 : 0x100) || !YTPut16(buf, 0)) return 0;
    uint32_t matrix[9] = { 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000 };
    uint32_t i;
    for (i = 0; i < 9; i++) if (!YTPut32(buf, matrix[i])) return 0;
    if (!YTPut32(buf, track->width << 16) || !YTPut32(buf, track->height << 16)) return 0;
    YTCloseBox(buf, tkhd);
    size_t mdia = YTOpenBox(buf, "mdia");
    size_t mdhd = YTOpenBox(buf, "mdhd");
    if (!YTPut32(buf, 0) || !YTPut32(buf, 0) || !YTPut32(buf, 0) || !YTPut32(buf, track->timescale) || !YTPut32(buf, mediaDuration) || !YTPut16(buf, 0x55c4) || !YTPut16(buf, 0)) return 0;
    YTCloseBox(buf, mdhd);
    size_t hdlr = YTOpenBox(buf, "hdlr");
    const char *name = track->width ? "VideoHandler" : "SoundHandler";
    if (!YTPut32(buf, 0) || !YTPut32(buf, 0) || !YTPut(buf, track->width ? "vide" : "soun", 4)) return 0;
    if (!YTPut32(buf, 0) || !YTPut32(buf, 0) || !YTPut32(buf, 0) || !YTPut(buf, name, strlen(name) + 1)) return 0;
    YTCloseBox(buf, hdlr);
    size_t minf = YTOpenBox(buf, "minf");
    if (track->width) {
        size_t vmhd = YTOpenBox(buf, "vmhd");
        if (!YTPut32(buf, 1) || !YTPut16(buf, 0) || !YTPut16(buf, 0) || !YTPut16(buf, 0) || !YTPut16(buf, 0)) return 0;
        YTCloseBox(buf, vmhd);
    } else {
        size_t smhd = YTOpenBox(buf, "smhd");
        if (!YTPut32(buf, 0) || !YTPut16(buf, 0) || !YTPut16(buf, 0)) return 0;
        YTCloseBox(buf, smhd);
    }
    size_t dinf = YTOpenBox(buf, "dinf");
    size_t dref = YTOpenBox(buf, "dref");
    if (!YTPut32(buf, 0) || !YTPut32(buf, 1)) return 0;
    size_t url = YTOpenBox(buf, "url ");
    if (!YTPut32(buf, 1)) return 0;
    YTCloseBox(buf, url);
    YTCloseBox(buf, dref);
    YTCloseBox(buf, dinf);
    size_t stbl = YTOpenBox(buf, "stbl");
    size_t stsd = YTOpenBox(buf, "stsd");
    if (!YTPut32(buf, 0) || !YTPut32(buf, 1) || !YTPut(buf, track->entry, track->entryLen)) return 0;
    YTCloseBox(buf, stsd);
    size_t stts = YTOpenBox(buf, "stts");
    if (!YTPutRuns(buf, track, 0)) return 0;
    YTCloseBox(buf, stts);
    if (track->width) {
        uint32_t syncs = 0;
        for (i = 0; i < track->count; i++) if ((track->samples[i].flags & 0x10000) == 0) syncs++;
        if (!syncs) syncs = 1;
        size_t stss = YTOpenBox(buf, "stss");
        if (!YTPut32(buf, 0) || !YTPut32(buf, syncs)) return 0;
        int wrote = 0;
        for (i = 0; i < track->count; i++) {
            if ((track->samples[i].flags & 0x10000) == 0) {
                if (!YTPut32(buf, i + 1)) return 0;
                wrote = 1;
            }
        }
        if (!wrote && !YTPut32(buf, 1)) return 0;
        YTCloseBox(buf, stss);
        int needCtts = 0;
        for (i = 0; i < track->count; i++) if (track->samples[i].cto) needCtts = 1;
        if (needCtts) {
            size_t ctts = YTOpenBox(buf, "ctts");
            if (!YTPutRuns(buf, track, 1)) return 0;
            YTCloseBox(buf, ctts);
        }
    }
    size_t stsc = YTOpenBox(buf, "stsc");
    if (!YTPut32(buf, 0) || !YTPut32(buf, 1) || !YTPut32(buf, 1) || !YTPut32(buf, track->count) || !YTPut32(buf, 1)) return 0;
    YTCloseBox(buf, stsc);
    size_t stsz = YTOpenBox(buf, "stsz");
    if (!YTPut32(buf, 0) || !YTPut32(buf, 0) || !YTPut32(buf, track->count)) return 0;
    for (i = 0; i < track->count; i++) if (!YTPut32(buf, track->samples[i].size)) return 0;
    YTCloseBox(buf, stsz);
    size_t stco = YTOpenBox(buf, "stco");
    if (!YTPut32(buf, 0) || !YTPut32(buf, 1)) return 0;
    *chunkAt = (uint32_t)buf->length;
    if (!YTPut32(buf, 0)) return 0;
    YTCloseBox(buf, stco);
    YTCloseBox(buf, stbl);
    YTCloseBox(buf, minf);
    YTCloseBox(buf, mdia);
    YTCloseBox(buf, trak);
    return 1;
}

static int YTCopySamples(FILE *out, FILE *in, YTTrack *track) {
    uint8_t buffer[32 * 1024];
    uint32_t i;
    for (i = 0; i < track->count; i++) {
        if (fseek(in, track->samples[i].src, SEEK_SET) != 0) return 0;
        uint32_t left = track->samples[i].size;
        while (left) {
            size_t chunk = left > sizeof(buffer) ? sizeof(buffer) : left;
            if (fread(buffer, 1, chunk, in) != chunk) return 0;
            if (fwrite(buffer, 1, chunk, out) != chunk) return 0;
            left -= chunk;
        }
    }
    return 1;
}

static int YTWriteMovie(NSString *videoPath, NSString *audioPath, NSString *outPath, YTTrack *video, YTTrack *audio) {
    YTBuf buf = { 0, 0, 0 };
    static const uint8_t ftyp[] = {
        0, 0, 0, 28, 'f', 't', 'y', 'p', 'i', 's', 'o', 'm', 0, 0, 0, 0,
        'i', 's', 'o', 'm', 'a', 'v', 'c', '1', 'm', 'p', '4', '1'
    };
    if (!YTPut(&buf, ftyp, sizeof(ftyp))) return 0;
    uint32_t movieScale = video->timescale;
    uint32_t videoDuration = YTTrackDuration(video);
    uint32_t audioMovie = (uint32_t)((uint64_t)YTTrackDuration(audio) * movieScale / audio->timescale);
    uint32_t movieDuration = videoDuration > audioMovie ? videoDuration : audioMovie;
    size_t moov = YTOpenBox(&buf, "moov");
    size_t mvhd = YTOpenBox(&buf, "mvhd");
    if (!YTPut32(&buf, 0) || !YTPut32(&buf, 0) || !YTPut32(&buf, 0) || !YTPut32(&buf, movieScale) || !YTPut32(&buf, movieDuration)) return 0;
    if (!YTPut32(&buf, 0x10000) || !YTPut16(&buf, 0x100) || !YTPut16(&buf, 0) || !YTPut32(&buf, 0) || !YTPut32(&buf, 0)) return 0;
    uint32_t matrix[9] = { 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000 };
    uint32_t i;
    for (i = 0; i < 9; i++) if (!YTPut32(&buf, matrix[i])) return 0;
    for (i = 0; i < 6; i++) if (!YTPut32(&buf, 0)) return 0;
    if (!YTPut32(&buf, 3)) return 0;
    YTCloseBox(&buf, mvhd);
    uint32_t videoChunk = 0;
    uint32_t audioChunk = 0;
    if (!YTWriteTrack(&buf, video, 1, movieScale, &videoChunk)) return 0;
    if (!YTWriteTrack(&buf, audio, 2, movieScale, &audioChunk)) return 0;
    YTCloseBox(&buf, moov);
    uint64_t videoBytes = YTTrackBytes(video);
    uint64_t audioBytes = YTTrackBytes(audio);
    if (videoBytes + audioBytes > 0xffffffffu - 8) return 0;
    uint32_t dataStart = (uint32_t)buf.length + 8;
    uint32_t videoOff = dataStart;
    uint32_t audioOff = dataStart + (uint32_t)videoBytes;
    buf.bytes[videoChunk] = videoOff >> 24;
    buf.bytes[videoChunk + 1] = videoOff >> 16;
    buf.bytes[videoChunk + 2] = videoOff >> 8;
    buf.bytes[videoChunk + 3] = videoOff;
    buf.bytes[audioChunk] = audioOff >> 24;
    buf.bytes[audioChunk + 1] = audioOff >> 16;
    buf.bytes[audioChunk + 2] = audioOff >> 8;
    buf.bytes[audioChunk + 3] = audioOff;
    FILE *out = fopen([outPath fileSystemRepresentation], "wb");
    if (!out) { free(buf.bytes); return 0; }
    int ok = fwrite(buf.bytes, 1, buf.length, out) == buf.length;
    free(buf.bytes);
    uint32_t mdat = (uint32_t)(videoBytes + audioBytes + 8);
    uint8_t mdatHead[8] = { mdat >> 24, mdat >> 16, mdat >> 8, mdat, 'm', 'd', 'a', 't' };
    ok = ok && fwrite(mdatHead, 1, 8, out) == 8;
    FILE *videoFile = fopen([videoPath fileSystemRepresentation], "rb");
    FILE *audioFile = fopen([audioPath fileSystemRepresentation], "rb");
    ok = ok && videoFile && audioFile && YTCopySamples(out, videoFile, video) && YTCopySamples(out, audioFile, audio);
    if (videoFile) fclose(videoFile);
    if (audioFile) fclose(audioFile);
    fclose(out);
    return ok;
}

@interface YTFileFetch : NSObject
@property (nonatomic, strong) NSFileHandle *out;
@property (nonatomic, assign) BOOL done;
@property (nonatomic, assign) BOOL ok;
@property (nonatomic, assign) unsigned long long bytes;
@property (nonatomic, assign) unsigned long long limit;
@end

@implementation YTFileFetch
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSInteger code = [(NSHTTPURLResponse *)response statusCode];
        if (code >= 400) {
            self.ok = NO;
            self.done = YES;
            [connection cancel];
        }
    }
}
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    if (self.bytes + [data length] > self.limit) {
        self.ok = NO;
        self.done = YES;
        [connection cancel];
        return;
    }
    [self.out writeData:data];
    self.bytes += [data length];
}
- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    self.ok = YES;
    self.done = YES;
}
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    self.ok = NO;
    self.done = YES;
}
@end

static BOOL YTDownload(NSString *url, NSString *path, unsigned long long limit) {
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!out) return NO;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                        timeoutInterval:45];
    [request setValue:@"com.google.android.youtube/20.10.38 (Linux; U; Android 13)" forHTTPHeaderField:@"User-Agent"];
    YTFileFetch *fetch = [[YTFileFetch alloc] init];
    fetch.out = out;
    fetch.limit = limit;
    NSURLConnection *connection = [[NSURLConnection alloc] initWithRequest:request delegate:fetch startImmediately:NO];
    [connection scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [connection start];
    while (!fetch.done) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    }
    [out closeFile];
    return fetch.ok && fetch.bytes > 1024;
}

static NSLock *YTMuxGate;

NSString *YTEnsure720(NSString *videoID, NSString *videoURL, NSString *audioURL) {
    if (!videoID.length || !videoURL.length || !audioURL.length) return nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ YTMuxGate = [[NSLock alloc] init]; });
    [YTMuxGate lock];
    NSString *path = [NSString stringWithFormat:@"/var/tmp/yt720-%@.mp4", videoID];
    NSDictionary *info = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if ([[info objectForKey:NSFileSize] unsignedLongLongValue] > 1024) {
        [YTMuxGate unlock];
        return path;
    }
    NSString *videoPart = [NSString stringWithFormat:@"/var/tmp/yt720-%@.v", videoID];
    NSString *audioPart = [NSString stringWithFormat:@"/var/tmp/yt720-%@.a", videoID];
    NSString *part = [path stringByAppendingString:@".part"];
    YTMuxNote([NSString stringWithFormat:@"mux 720 %@", videoID]);
    BOOL downloaded = YTDownload(videoURL, videoPart, 110ull * 1024 * 1024) && YTDownload(audioURL, audioPart, 16ull * 1024 * 1024);
    YTTrack video = { 0 };
    YTTrack audio = { 0 };
    int ok = downloaded && YTParseFile(videoPart, &video) && video.height >= 360 && YTParseFile(audioPart, &audio);
    ok = ok && YTWriteMovie(videoPart, audioPart, part, &video, &audio);
    YTFreeTrack(&video);
    YTFreeTrack(&audio);
    [[NSFileManager defaultManager] removeItemAtPath:videoPart error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:audioPart error:NULL];
    if (!ok) {
        [[NSFileManager defaultManager] removeItemAtPath:part error:NULL];
        YTMuxNote([NSString stringWithFormat:@"mux fail %@", videoID]);
        [YTMuxGate unlock];
        return nil;
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    [[NSFileManager defaultManager] moveItemAtPath:part toPath:path error:NULL];
    YTMuxNote([NSString stringWithFormat:@"mux ok %@ %llu", videoID, [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL] fileSize]]);
    [YTMuxGate unlock];
    return path;
}
