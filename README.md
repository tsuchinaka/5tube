# YouTubeInnerTube

Tweak for the stock iOS 5.1 YouTube app. GData is dead, so this answers those feeds with Atom built from InnerTube. The stock screens stay.

Package: `com.bytebox.youtubeinnertube`

## Build

    export THEOS=/home/main/theos
    make -j4 package

Target `iphone:clang:5.1:5.1`, armv7. Install the `.deb` on a jailbroken device that still has `YouTube.app`.

## What it covers

- Search, related, channels and the signed-in lists
- 720p30 through a local remux on `127.0.0.1`
- YouTube TV device-code sign-in (`youtube.com/activate`)
- Likes, subscriptions, comments, history and Watch Later through the buttons the app already has
