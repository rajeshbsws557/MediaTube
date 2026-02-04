import 'package:flutter/material.dart';

class FloatingDownloadButton extends StatelessWidget {
  final int mediaCount;
  final bool isYouTube;
  final bool isFetching;
  final bool hasError;
  final VoidCallback onPressed;

  const FloatingDownloadButton({
    super.key,
    required this.mediaCount,
    required this.isYouTube,
    required this.isFetching,
    this.hasError = false,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // Determine button state and appearance
    final showError = hasError && mediaCount == 0 && !isFetching;
    final backgroundColor = showError 
        ? Colors.orange 
        : isYouTube 
            ? Colors.red 
            : Theme.of(context).colorScheme.primary;
    
    return FloatingActionButton.extended(
      onPressed: isFetching ? null : onPressed,
      backgroundColor: backgroundColor,
      icon: isFetching
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : showError
              ? const Icon(Icons.refresh, color: Colors.white)
              : const Icon(Icons.download, color: Colors.white),
      label: Text(
        isFetching
            ? 'Loading...'
            : showError
                ? 'Retry'
                : mediaCount > 0
                    ? '$mediaCount Media Found'
                    : isYouTube
                        ? 'Get Video'
                        : 'Download',
        style: const TextStyle(color: Colors.white),
      ),
    );
  }
}
