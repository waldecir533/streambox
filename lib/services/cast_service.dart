import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

import '../models/channel.dart';

class CastService {
  CastService._();

  static Stream<List<GoogleCastDevice>> get devices =>
      GoogleCastDiscoveryManager.instance.devicesStream;

  static void startDiscovery() =>
      GoogleCastDiscoveryManager.instance.startDiscovery();

  static Future<void> cast(Channel channel, GoogleCastDevice device) async {
    await GoogleCastSessionManager.instance.startSessionWithDevice(device);
    final lowerUrl = channel.url.toLowerCase();
    final isHls = lowerUrl.contains('.m3u8');
    final media = GoogleCastMediaInformation(
      contentId: channel.url,
      contentUrl: Uri.parse(channel.url),
      contentType: isHls ? 'application/x-mpegURL' : 'video/mp4',
      streamType: CastMediaStreamType.live,
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

  static Future<void> disconnect() =>
      GoogleCastSessionManager.instance.endSessionAndStopCasting();

  static Future<void> openAndroidScreenMirroring() async {
    if (!Platform.isAndroid) return;
    const intent = AndroidIntent(action: 'android.settings.CAST_SETTINGS');
    await intent.launch();
  }
}
