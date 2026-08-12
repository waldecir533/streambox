import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

import '../models/channel.dart';
import 'stream_proxy_service.dart';

class CastService {
  CastService._();

  static final StreamProxyService _proxy = StreamProxyService();

  static Stream<List<GoogleCastDevice>> get devices =>
      GoogleCastDiscoveryManager.instance.devicesStream;

  static void startDiscovery() =>
      GoogleCastDiscoveryManager.instance.startDiscovery();

  static Future<void> cast(Channel channel, GoogleCastDevice? device) async {
    if (device != null) {
      await GoogleCastSessionManager.instance.startSessionWithDevice(device);
    }
    final lowerUrl = channel.url.toLowerCase();
    final isHls = lowerUrl.contains('.m3u8');
    final remoteUrl = channel.headers.isEmpty
        ? Uri.parse(channel.url)
        : await _proxy.urlFor(channel);
    final media = GoogleCastMediaInformation(
      contentId: remoteUrl.toString(),
      contentUrl: remoteUrl,
      contentType: isHls ? 'application/x-mpegURL' : 'video/mp4',
      streamType: CastMediaStreamType.live,
      customData: channel.headers.isEmpty ? null : {'headers': channel.headers},
      metadata: GoogleCastMovieMediaMetadata(
        title: channel.name,
        subtitle: 'Transmitindo pelo StreamBox',
        images: channel.logoUrl == null || channel.logoUrl!.isEmpty
            ? const []
            : [
                GoogleCastImage(
                  url: Uri.parse(channel.logoUrl!),
                  height: 512,
                  width: 512,
                ),
              ],
      ),
    );
    await GoogleCastRemoteMediaClient.instance.loadMedia(media, autoPlay: true);
  }

  static Future<void> disconnect() async {
    await GoogleCastSessionManager.instance.endSessionAndStopCasting();
    await _proxy.dispose();
  }

  static Future<void> play() => GoogleCastRemoteMediaClient.instance.play();

  static Future<void> pause() => GoogleCastRemoteMediaClient.instance.pause();

  static Future<void> stop() => GoogleCastRemoteMediaClient.instance.stop();

  static Future<void> openAndroidScreenMirroring() async {
    if (!Platform.isAndroid) return;
    const intent = AndroidIntent(action: 'android.settings.CAST_SETTINGS');
    await intent.launch();
  }
}
