import 'package:flutter/material.dart';
import 'package:flutter_chrome_cast/entities.dart';

import '../models/channel.dart';
import '../services/cast_service.dart';

class CastDialog extends StatefulWidget {
  const CastDialog({super.key, required this.channel});

  final Channel channel;

  @override
  State<CastDialog> createState() => _CastDialogState();
}

class _CastDialogState extends State<CastDialog> {
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    CastService.startDiscovery();
  }

  Future<void> _connect(GoogleCastDevice device) async {
    setState(() => _connecting = true);
    try {
      await CastService.cast(widget.channel, device);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(content: Text('Transmitindo para ${device.friendlyName}')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _connecting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível transmitir. Confira o Wi-Fi e tente novamente.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Transmitir para TV'),
      content: SizedBox(
        width: 420,
        child: StreamBuilder<List<GoogleCastDevice>>(
          stream: CastService.devices,
          builder: (context, snapshot) {
            final devices = snapshot.data ?? const <GoogleCastDevice>[];
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_connecting) const LinearProgressIndicator(),
                if (devices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text('Procurando Chromecast e TVs compatíveis na mesma rede Wi-Fi...'),
                  ),
                for (final device in devices)
                  ListTile(
                    leading: const Icon(Icons.cast),
                    title: Text(device.friendlyName),
                    subtitle: Text(device.modelName ?? 'Dispositivo Google Cast'),
                    enabled: !_connecting,
                    onTap: () => _connect(device),
                  ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.screen_share),
                  title: const Text('Espelhar a tela do celular'),
                  subtitle: const Text('Abre o painel de transmissão do Android'),
                  onTap: () async {
                    await CastService.openAndroidScreenMirroring();
                    if (context.mounted) Navigator.pop(context);
                  },
                ),
              ],
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar'))],
    );
  }
}
