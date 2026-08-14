// Item de canal reutilizável (usado em Início, seções, pesquisa e playlists).
import 'package:flutter/material.dart';
import '../models/channel.dart';

/// Linha de canal com logotipo, nome, subtítulo (EPG/categoria), favorito
/// e navegação para o player.
class ChannelListTile extends StatelessWidget {
  const ChannelListTile({
    super.key,
    required this.channel,
    required this.isFavorite,
    required this.onOpen,
    required this.onToggleFavorite,
  });

  final Channel channel;
  final bool isFavorite;
  final VoidCallback onOpen;
  final VoidCallback onToggleFavorite;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: SizedBox.square(
      dimension: 48,
      child: channel.logoUrl == null || channel.logoUrl!.isEmpty
          ? const Icon(Icons.live_tv)
          : Image.network(
              channel.logoUrl!,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Icon(Icons.live_tv),
            ),
    ),
    title: Text(channel.name),
    subtitle: Text(
      channel.epgTitle ?? channel.group ?? 'Ao vivo',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: IconButton(
      tooltip: isFavorite ? 'Remover favorito' : 'Favorito',
      onPressed: onToggleFavorite,
      icon: Icon(isFavorite ? Icons.star : Icons.star_border,
          color: isFavorite ? Colors.amber : null),
    ),
    onTap: onOpen,
  );
}
